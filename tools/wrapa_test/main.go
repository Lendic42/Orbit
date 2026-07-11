// tools/wrapa_test — standalone tester for amurcanov's WRAP-A + DTLS + GETCONF
// transport, de-risking the "SRTP-WRAP-A" 4th client mode before touching the
// iOS NE (memory: open_task_amurcanov_wrap_a_mode.md).
//
//	M1 (default)  WRAP-A obfs + DTLS handshake vs a live wdtt-server (:56000).
//	M2 (-getconf) + send GETCONF, print the WireGuard INI the server returns.
//	M3 (-tunnel)  + bring up a userspace WireGuard (wireguard-go + gVisor
//	              netstack, no real TUN) over the WRAP-A+DTLS channel, wait for
//	              the WG handshake, then HTTP-GET through the tunnel.
//
// This is a SEPARATE go module (tools/wrapa_test/go.mod) on purpose: M3 pulls
// gvisor.dev/gvisor via wireguard's netstack, and we do NOT want that in the
// iOS app's committed go.mod. obfs + HKDF are copied verbatim from amurcanov
// proxy-turn-vk-android v1.2.2 (go_client/obfs.go + wrap.go); the DTLS config
// mirrors his go_client/session.go exactly.
//
//	go build -o /tmp/wrapa_test . && /tmp/wrapa_test -addr 140.82.38.174:56000 -password <pw> -tunnel
package main

import (
	"context"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"

	dtls "github.com/pion/dtls/v3"
	"github.com/pion/dtls/v3/pkg/crypto/selfsign"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// ───────────────────────── WRAP key (verbatim: wrap.go) ─────────────────────

const wrapKeyLen = 32

func deriveWrapKey(password string) ([]byte, error) {
	if password == "" {
		return nil, errors.New("empty password")
	}
	key := make([]byte, wrapKeyLen)
	reader := hkdf.New(sha256.New, []byte(password), []byte("WDTT-WRAP-v1"), []byte("rtp-obfs/chacha20poly1305"))
	if _, err := io.ReadFull(reader, key); err != nil {
		return nil, fmt.Errorf("derive wrap key: %w", err)
	}
	return key, nil
}

// ───────────────────────── obfs (verbatim: obfs.go) ─────────────────────────

var aeadCache sync.Map

func getAEAD(key []byte) (cipher.AEAD, error) {
	keyStr := string(key)
	if val, ok := aeadCache.Load(keyStr); ok {
		return val.(cipher.AEAD), nil
	}
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	aeadCache.Store(keyStr, aead)
	return aead, nil
}

type ObfsConfig struct {
	SSRC        uint32
	PayloadType uint8
	PaddingMax  int
}

func NewObfsConfig() *ObfsConfig {
	var buf [4]byte
	rand.Read(buf[:])
	return &ObfsConfig{SSRC: binary.BigEndian.Uint32(buf[:]), PayloadType: 111, PaddingMax: 24}
}

type ObfsState struct {
	mu      sync.Mutex
	initSeq uint16
	initTs  uint32
	count   uint64
}

func NewObfsState() *ObfsState {
	var buf [6]byte
	rand.Read(buf[:])
	return &ObfsState{initSeq: binary.BigEndian.Uint16(buf[0:2]), initTs: binary.BigEndian.Uint32(buf[2:6])}
}

func obfsBuildNonce(ssrc uint32, seq uint16, ts uint32) []byte {
	n := make([]byte, 12)
	binary.BigEndian.PutUint32(n[0:4], ssrc)
	binary.BigEndian.PutUint16(n[4:6], seq)
	binary.BigEndian.PutUint32(n[8:12], ts)
	return n
}

func obfsWrapPacket(key, payload []byte, cfg *ObfsConfig, state *ObfsState) ([]byte, error) {
	if len(payload) == 0 {
		return nil, errors.New("obfs: empty payload")
	}
	state.mu.Lock()
	c := state.count
	state.count++
	state.mu.Unlock()

	seq := state.initSeq + uint16(c)
	ts := state.initTs + uint32(c)*960 + uint32(c>>16)
	nonce := obfsBuildNonce(cfg.SSRC, seq, ts)

	padRand := 0
	if cfg.PaddingMax > 0 {
		var rndBuf [1]byte
		rand.Read(rndBuf[:])
		padRand = int(rndBuf[0]) % cfg.PaddingMax
	}
	padTotal := padRand + 1

	outLen := 12 + len(payload) + chacha20poly1305.Overhead + padTotal
	out := make([]byte, outLen)
	out[0] = 0x80 | 0x20 // V=2, P=1
	out[1] = cfg.PayloadType & 0x7F
	binary.BigEndian.PutUint16(out[2:4], seq)
	binary.BigEndian.PutUint32(out[4:8], ts)
	binary.BigEndian.PutUint32(out[8:12], cfg.SSRC)

	aead, err := getAEAD(key)
	if err != nil {
		return nil, err
	}
	sealed := aead.Seal(out[12:12], nonce, payload, out[:12])
	padStart := 12 + len(sealed)
	if padRand > 0 {
		rand.Read(out[padStart : padStart+padRand])
	}
	out[outLen-1] = byte(padTotal)
	return out, nil
}

func obfsUnwrapPacket(key, wire, dst []byte) (int, error) {
	if len(wire) < 13 || (wire[0]>>6) != 2 {
		return 0, errors.New("obfs: bad packet")
	}
	seq := binary.BigEndian.Uint16(wire[2:4])
	ts := binary.BigEndian.Uint32(wire[4:8])
	ssrc := binary.BigEndian.Uint32(wire[8:12])

	payloadEnd := len(wire)
	if wire[0]&0x20 != 0 {
		padLen := int(wire[len(wire)-1])
		if padLen == 0 || padLen > payloadEnd-12 {
			return 0, fmt.Errorf("obfs: invalid padding %d", padLen)
		}
		payloadEnd -= padLen
	}
	if payloadEnd-12 <= chacha20poly1305.Overhead {
		return 0, errors.New("obfs: no payload")
	}
	nonce := obfsBuildNonce(ssrc, seq, ts)
	aead, err := getAEAD(key)
	if err != nil {
		return 0, err
	}
	plain, err := aead.Open(dst[:0], nonce, wire[12:payloadEnd], wire[:12])
	if err != nil {
		return 0, fmt.Errorf("obfs: auth: %w", err)
	}
	return len(plain), nil
}

func obfsIsRTPPacket(wire []byte) bool {
	return len(wire) >= 13 && (wire[0]>>6) == 2 && (wire[1]&0x7F) == 111
}

// ─────────────── obfs net.PacketConn over a connected UDP socket ────────────

type obfsPacketConn struct {
	udp   *net.UDPConn
	raddr net.Addr
	key   []byte
	cfg   *ObfsConfig
	st    *ObfsState
}

func (c *obfsPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	buf := make([]byte, len(p)+80)
	for {
		n, err := c.udp.Read(buf)
		if err != nil {
			return 0, c.raddr, err
		}
		if !obfsIsRTPPacket(buf[:n]) {
			continue
		}
		m, uerr := obfsUnwrapPacket(c.key, buf[:n], p)
		if uerr != nil {
			continue
		}
		return m, c.raddr, nil
	}
}

func (c *obfsPacketConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	w, err := obfsWrapPacket(c.key, p, c.cfg, c.st)
	if err != nil {
		return 0, err
	}
	if _, err := c.udp.Write(w); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (c *obfsPacketConn) Close() error                       { return c.udp.Close() }
func (c *obfsPacketConn) LocalAddr() net.Addr                { return c.udp.LocalAddr() }
func (c *obfsPacketConn) SetDeadline(t time.Time) error      { return c.udp.SetDeadline(t) }
func (c *obfsPacketConn) SetReadDeadline(t time.Time) error  { return c.udp.SetReadDeadline(t) }
func (c *obfsPacketConn) SetWriteDeadline(t time.Time) error { return c.udp.SetWriteDeadline(t) }

// ───────────────────────────────── main ────────────────────────────────────

func main() {
	addr := flag.String("addr", "", "amurcanov server ip:port (e.g. 140.82.38.174:56000)")
	password := flag.String("password", "", "WRAP/auth password (derives the WRAP key AND authenticates GETCONF)")
	doGetconf := flag.Bool("getconf", false, "M2: after the handshake, send GETCONF and print the WireGuard config")
	doTunnel := flag.Bool("tunnel", false, "M3: GETCONF + bring up userspace WG over the channel and HTTP-GET through it")
	deviceID := flag.String("device", "wrapa-test-0001", "deviceID for GETCONF")
	localPort := flag.String("localport", "51820", "placeholder local WG port for GETCONF (server only echoes it; we ignore it)")
	flag.Parse()

	if *addr == "" || *password == "" {
		log.Fatal("need -addr and -password (the password derives the WRAP key — must match the server's)")
	}

	raddr, err := net.ResolveUDPAddr("udp", *addr)
	if err != nil {
		log.Fatalf("resolve %s: %v", *addr, err)
	}
	udp, err := net.DialUDP("udp", nil, raddr)
	if err != nil {
		log.Fatalf("dial udp: %v", err)
	}
	defer udp.Close()

	key, err := deriveWrapKey(*password)
	if err != nil {
		log.Fatalf("derive wrap key: %v", err)
	}
	log.Printf("WRAP key derived (HKDF-SHA256, 32B) from password (%d chars)", len(*password))

	pc := &obfsPacketConn{udp: udp, raddr: raddr, key: key, cfg: NewObfsConfig(), st: NewObfsState()}
	cert, err := selfsign.GenerateSelfSigned()
	if err != nil {
		log.Fatalf("self-signed cert: %v", err)
	}
	cfg := &dtls.Config{
		Certificates:          []tls.Certificate{cert},
		InsecureSkipVerify:    true,
		ExtendedMasterSecret:  dtls.RequireExtendedMasterSecret,
		CipherSuites:          []dtls.CipherSuiteID{dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256},
		ConnectionIDGenerator: dtls.OnlySendCIDGenerator(),
	}

	log.Printf("connecting to %s — WRAP-A obfs → DTLS handshake…", *addr)
	start := time.Now()
	dconn, err := dtls.Client(pc, raddr, cfg)
	if err != nil {
		log.Fatalf("dtls.Client: %v", err)
	}
	defer dconn.Close()
	hctx, hcancel := context.WithTimeout(context.Background(), 20*time.Second)
	if err := dconn.HandshakeContext(hctx); err != nil {
		hcancel()
		log.Fatalf("❌ DTLS handshake FAILED after %v: %v\n    (timeout/EOF here usually = wrong WRAP key — server couldn't unwrap, so it never replied)",
			time.Since(start).Round(time.Millisecond), err)
	}
	hcancel()
	log.Printf("✅ M1 PASS — DTLS handshake OK in %v. WRAP-A obfuscation + DTLS config are byte-correct and interop with %s.",
		time.Since(start).Round(time.Millisecond), *addr)

	if !*doGetconf && !*doTunnel {
		log.Printf("(run with -getconf for M2, or -tunnel for M3)")
		return
	}

	// M2 — GETCONF control exchange over the established DTLS channel.
	if _, err := dconn.Write([]byte(fmt.Sprintf("GETCONF:%s|%s|%s", *localPort, *deviceID, *password))); err != nil {
		log.Fatalf("GETCONF write: %v", err)
	}
	_ = dconn.SetReadDeadline(time.Now().Add(15 * time.Second))
	b := make([]byte, 4096)
	n, err := dconn.Read(b)
	_ = dconn.SetReadDeadline(time.Time{})
	if err != nil {
		log.Fatalf("GETCONF read: %v", err)
	}
	ini := string(b[:n])
	if ini == "NOCONF" {
		log.Fatalf("⚠️  server returned NOCONF (no config for this device)")
	}
	if strings.HasPrefix(ini, "DENIED:") {
		log.Fatalf("❌ M2 DENIED: %s (password wrong/expired/device-bound)", strings.TrimPrefix(ini, "DENIED:"))
	}
	log.Printf("✅ M2 PASS — GETCONF returned %d bytes (WireGuard INI):\n%s", n, ini)

	if *doTunnel {
		runM3(dconn, ini)
	}
}

// ─────────────────────── M3: userspace WG over the channel ──────────────────

func runM3(dconn net.Conn, ini string) {
	priv, pub, addrStr, dns, mtu := parseWGINI(ini)
	if priv == "" || pub == "" || addrStr == "" {
		log.Fatalf("M3: INI missing PrivateKey/PublicKey/Address")
	}
	prefix, err := netip.ParsePrefix(addrStr)
	if err != nil {
		log.Fatalf("M3: parse Address %q: %v", addrStr, err)
	}
	dnsAddr, err := netip.ParseAddr(dns)
	if err != nil {
		dnsAddr = netip.MustParseAddr("1.1.1.1")
	}

	// Userspace netstack TUN — no real TUN / no root.
	tdev, tnet, err := netstack.CreateNetTUN([]netip.Addr{prefix.Addr()}, []netip.Addr{dnsAddr}, mtu)
	if err != nil {
		log.Fatalf("M3: netstack CreateNetTUN: %v", err)
	}

	wgdev := device.NewDevice(tdev, &dtlsBind{dconn: dconn}, device.NewLogger(device.LogLevelError, "wg: "))

	privHex, err := keyB64toHex(priv)
	if err != nil {
		log.Fatalf("M3: PrivateKey: %v", err)
	}
	pubHex, err := keyB64toHex(pub)
	if err != nil {
		log.Fatalf("M3: PublicKey: %v", err)
	}
	// endpoint is a throwaway — our dtlsBind ignores it (all traffic goes over dconn).
	uapi := fmt.Sprintf("private_key=%s\npublic_key=%s\nallowed_ip=0.0.0.0/0\nendpoint=127.0.0.1:51820\npersistent_keepalive_interval=25\n", privHex, pubHex)
	if err := wgdev.IpcSet(uapi); err != nil {
		log.Fatalf("M3: IpcSet: %v", err)
	}
	if err := wgdev.Up(); err != nil {
		log.Fatalf("M3: dev.Up: %v", err)
	}
	defer wgdev.Close()
	log.Printf("M3 — userspace WG up (addr %s); waiting for the WG handshake over the WRAP-A+DTLS channel…", addrStr)

	handshook := false
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(300 * time.Millisecond) {
		st, _ := wgdev.IpcGet()
		for _, ln := range strings.Split(st, "\n") {
			if strings.HasPrefix(ln, "last_handshake_time_sec=") && !strings.HasSuffix(ln, "=0") {
				handshook = true
			}
		}
		if handshook {
			break
		}
	}
	if handshook {
		log.Printf("✅ WG handshake established over WRAP-A+DTLS — control plane end-to-end OK.")
	} else {
		log.Printf("⚠️  no WG handshake within 10s.")
	}

	// HTTP GET through the tunnel: DNS (via 1.1.1.1) + TCP both ride the tunnel,
	// and api.ipify.org echoes the apparent source IP = the VPS egress (proves NAT).
	client := &http.Client{Timeout: 12 * time.Second, Transport: &http.Transport{DialContext: tnet.DialContext}}
	const url = "http://api.ipify.org"
	log.Printf("M3 — HTTP GET %s through the tunnel…", url)
	resp, err := client.Get(url)
	if err != nil {
		log.Fatalf("❌ M3 HTTP through tunnel FAILED: %v\n    (handshook=%v — if true, the WG tunnel itself works but the server's full-tunnel NAT/DNS may be off)", err, handshook)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
	log.Printf("✅ M3 PASS — HTTP %s through the tunnel; api.ipify.org → %q (apparent public IP = VPS egress, proving full WG-over-WRAP-A end-to-end).",
		resp.Status, strings.TrimSpace(string(body)))
}

func parseWGINI(s string) (priv, pub, addr, dns string, mtu int) {
	mtu = 1280
	for _, ln := range strings.Split(s, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(ln), "=")
		if !ok {
			continue
		}
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		switch k {
		case "PrivateKey":
			priv = v
		case "PublicKey":
			pub = v
		case "Address":
			addr = v
		case "DNS":
			dns = strings.TrimSpace(strings.Split(v, ",")[0])
		case "MTU":
			fmt.Sscanf(v, "%d", &mtu)
		}
	}
	return
}

func keyB64toHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", err
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("key not 32 bytes (%d)", len(raw))
	}
	return hex.EncodeToString(raw), nil
}

// dtlsBind implements conn.Bind by pumping WireGuard packets over the
// established DTLS conn (which is over WRAP-A obfs over UDP/VK-TURN).
type dtlsBind struct{ dconn net.Conn }

func (b *dtlsBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	recv := func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		for {
			n, err := b.dconn.Read(packets[0])
			if err != nil {
				return 0, err
			}
			if n <= 1 { // skip 1-byte keepalive pong
				continue
			}
			sizes[0] = n
			eps[0] = wgEndpoint{}
			return 1, nil
		}
	}
	return []conn.ReceiveFunc{recv}, port, nil
}

func (b *dtlsBind) Close() error         { return nil }
func (b *dtlsBind) SetMark(uint32) error { return nil }
func (b *dtlsBind) BatchSize() int       { return 1 }

func (b *dtlsBind) Send(bufs [][]byte, _ conn.Endpoint) error {
	for _, buf := range bufs {
		if _, err := b.dconn.Write(buf); err != nil {
			return err
		}
	}
	return nil
}

func (b *dtlsBind) ParseEndpoint(string) (conn.Endpoint, error) { return wgEndpoint{}, nil }

type wgEndpoint struct{}

func (wgEndpoint) ClearSrc()           {}
func (wgEndpoint) SrcToString() string { return "" }
func (wgEndpoint) DstToString() string { return "wrap-a:0" }
func (wgEndpoint) DstToBytes() []byte  { return []byte("wrap-a:0") }
func (wgEndpoint) DstIP() netip.Addr   { return netip.Addr{} }
func (wgEndpoint) SrcIP() netip.Addr   { return netip.Addr{} }
