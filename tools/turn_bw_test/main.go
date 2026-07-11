// turn_bw_test — measures TURN allocation throughput against a VK relay.
//
// Modes:
//   - Single allocation (default, -parallel=1 -allocs-per-cred=1): one
//     TURN allocation, one long-running send loop, prints rate every 2s
//     and final summary.
//   - Parallel allocations from distinct creds (-parallel=N): spawns N
//     independent allocations using N creds from the backup, each with
//     its own TURN client and send loop, all writing to the same dst.
//   - Multiple allocations per cred (-allocs-per-cred=K): each cred
//     supports up to K simultaneous allocations against VK's per-cred
//     quota of 10. Combined with -parallel=N this gives N*K total
//     allocations from N creds — the only way to drive worker counts
//     above what your backup has creds for. Example: 5 creds with K=10
//     gives 50 simultaneous allocations (matches the production app's
//     conn count) without needing 50 distinct creds in the backup.
//
// Used to detect VK shaping behaviour at varying parallelism: per-
// allocation cap, aggregate cap, per-cred cap, abusive-pattern
// classification, etc.
//
// Required setup:
//   1. On the VPS, run the matching server:
//        ./turn_bw_server -port=9999
//      (per-source rate + final summary; see ./tools/turn_bw_server.)
//      A `nc -u -k -l 9999 | pv -W -b -r -t > /dev/null` works as a
//      fallback but aggregates all parallel allocations into one number
//      and drops to 0 the moment the client stops, so prefer the server.
//   2. Disconnect the iOS VPN app — its 50 active conns hold quota
//      against these creds.
//   3. Export a backup from iOS Settings → Backup & Restore → Export Full
//      Backup. The JSON contains valid creds for each slot we'll use.
//   4. Move the backup file to the Mac.
//
// Usage:
//   # Single allocation (baseline):
//   go run ./tools/turn_bw_test -creds=backup.json -slot=0 \
//       -dst-ip=217.168.246.242 -dst-port=9999 \
//       -transport=tcp -duration=30s
//
//   # Parallel allocations (find shaping threshold):
//   go run ./tools/turn_bw_test -creds=backup.json -parallel=5 \
//       -dst-ip=217.168.246.242 -dst-port=9999 \
//       -transport=udp -duration=30s
//   (-slot ignored when -parallel>1; the first N creds present in the
//   backup are used, sorted by slot index — the pool routinely has
//   gaps, e.g. slots [0,1,2,4,6], and we don't care which exact
//   indices we get as long as they're distinct creds.)

package main

import (
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v5"
)

type backupCred struct {
	Address    string `json:"address"`
	LastUsedAt int64  `json:"last_used_at"`
	Password   string `json:"password"`
	Slot       int    `json:"slot"`
	Username   string `json:"username"`
}

type backupFile struct {
	TurnPool struct {
		Creds []backupCred `json:"creds"`
	} `json:"turn_pool"`
}

// workerStats holds per-allocation live counters used by the aggregate
// printer and end-of-test summary. With -allocs-per-cred=K several
// workerStats can share the same `slot` value; subIdx (0..K-1) makes
// them distinguishable in logs and aggregation.
type workerStats struct {
	slot      int
	subIdx    int // index within same-slot allocations; 0 when K==1
	bytesSent atomic.Int64
	pktsSent  atomic.Int64
	sendErrs  atomic.Int64
	lastErr   atomic.Value // error
	allocOK   atomic.Bool
	allocDur  time.Duration
	relayed   string
	startTime time.Time
}

// label returns a short human-readable identifier for this worker —
// "slot 0" when there's one allocation per cred, "slot 0/a3" when
// multiple. Used in stdout for the live ticker, allocate-OK lines,
// and the final RESULT block.
func (s *workerStats) label(allocsPerCred int) string {
	if allocsPerCred <= 1 {
		return fmt.Sprintf("slot %d", s.slot)
	}
	return fmt.Sprintf("slot %d/a%d", s.slot, s.subIdx)
}

func main() {
	credsPath := flag.String("creds", "", "path to backup JSON exported from iOS app")
	slot := flag.Int("slot", 0, "single-mode: which slot's cred to use (ignored if -parallel > 1)")
	parallel := flag.Int("parallel", 1, "number of parallel allocations (uses slots 0..N-1)")
	dstIP := flag.String("dst-ip", "217.168.246.242", "destination IP (your VPS)")
	dstPort := flag.Int("dst-port", 9999, "destination UDP port on the VPS")
	transport := flag.String("transport", "udp", "udp or tcp")
	duration := flag.Duration("duration", 30*time.Second, "test duration")
	pktSize := flag.Int("pkt-size", 1280, "send-payload size, bytes")
	verbose := flag.Bool("v", false, "verbose pion logging")
	tcpAllocation := flag.Bool("tcp-allocation", false,
		"use RFC 6062 TCP allocation (relay↔peer also TCP, not UDP). "+
			"VPS must have TCP listener on -dst-port instead of UDP. "+
			"Forces -transport=tcp.")
	allocsPerCred := flag.Int("allocs-per-cred", 1,
		"spawn this many independent TURN allocations per cred. Each "+
			"uses a fresh UDP socket and gets its own relayed transport "+
			"address on the relay. Total worker count = parallel * "+
			"allocs-per-cred. VK's per-cred quota is 10 — values above "+
			"that will produce 486 Allocation Quota Reached errors.")
	relayAddr := flag.String("relay-addr", "",
		"override TURN relay address (host:port). When set, all workers "+
			"connect to this address instead of cred.Address — used to "+
			"test the second URL from VK turn_server.urls without "+
			"modifying backup. Cred username/password are unchanged; if "+
			"VK rejects them on this relay, Allocate fails fast (401).")
	flag.Parse()

	if *credsPath == "" {
		log.Fatal("missing -creds <path>")
	}
	if *tcpAllocation {
		// TCP allocation requires the control connection to be TCP too —
		// it's a TCP-end-to-end mode. Force the transport.
		if *transport != "tcp" {
			fmt.Printf("note: -tcp-allocation forces -transport=tcp (was %s)\n", *transport)
			*transport = "tcp"
		}
	}
	if *transport != "udp" && *transport != "tcp" {
		log.Fatalf("transport must be udp or tcp, got %q", *transport)
	}
	if *parallel < 1 {
		log.Fatal("-parallel must be >= 1")
	}
	if *allocsPerCred < 1 {
		log.Fatal("-allocs-per-cred must be >= 1")
	}
	if *allocsPerCred > 10 {
		log.Printf("warning: -allocs-per-cred=%d exceeds VK's per-cred quota of 10; expect 486 Allocation Quota Reached errors",
			*allocsPerCred)
	}

	// Pre-load all creds we'll need, fail fast if anything's missing.
	// Single-allocation mode honours -slot directly. Parallel mode takes
	// the first N creds present in the backup sorted by slot index — the
	// pool can have gaps (e.g. [0,1,2,4,6]) because some slots are still
	// in saturation cooldown or never got filled, and there's no reason
	// to require slot indices to be contiguous from zero.
	var creds []*backupCred
	if *parallel == 1 {
		c, err := loadCred(*credsPath, *slot)
		if err != nil {
			log.Fatalf("load creds: %v", err)
		}
		creds = []*backupCred{c}
	} else {
		all, err := loadAllCreds(*credsPath)
		if err != nil {
			log.Fatalf("load creds: %v", err)
		}
		if len(all) < *parallel {
			avail := make([]int, len(all))
			for i, c := range all {
				avail[i] = c.Slot
			}
			log.Fatalf("need %d allocations but backup has only %d cred(s) (slots %v)",
				*parallel, len(all), avail)
		}
		creds = all[:*parallel]
	}

	// -relay-addr override: replace each cred's relay address with the
	// user-supplied one (typically the second URL from VK turn_server.urls
	// to test whether per-allocation blackhole rate differs across the two
	// relays VK returns). Cred username/password stay as-is — VK creds
	// from one vchat.joinConversationByLink are valid on any relay in
	// the URL list.
	if *relayAddr != "" {
		for _, c := range creds {
			c.Address = *relayAddr
		}
	}

	dstAddr := &net.UDPAddr{IP: net.ParseIP(*dstIP), Port: *dstPort}

	// Expand creds × allocs-per-cred into a flat list of workers. Each
	// entry pairs a cred with its sub-index (0..K-1) so multiple workers
	// sharing the same cred can be told apart in logs and live output.
	type workerSpec struct {
		cred   *backupCred
		subIdx int
	}
	specs := make([]workerSpec, 0, len(creds)*(*allocsPerCred))
	for _, c := range creds {
		for j := 0; j < *allocsPerCred; j++ {
			specs = append(specs, workerSpec{cred: c, subIdx: j})
		}
	}

	fmt.Printf("=== TURN bandwidth test ===\n")
	fmt.Printf("Transport:    %s\n", *transport)
	if *allocsPerCred > 1 {
		fmt.Printf("Parallel:     %d cred(s) × %d alloc/cred = %d total allocations (slots %v)\n",
			len(creds), *allocsPerCred, len(specs), slotsOf(creds))
	} else {
		fmt.Printf("Parallel:     %d allocation(s) (slots %v)\n",
			len(creds), slotsOf(creds))
	}
	if *relayAddr != "" {
		fmt.Printf("TURN relay:   %s (overridden via -relay-addr)\n", creds[0].Address)
	} else {
		fmt.Printf("TURN relay:   %s\n", creds[0].Address)
	}
	fmt.Printf("Destination:  %s\n", dstAddr)
	fmt.Printf("Duration:     %s, payload: %d bytes\n\n", *duration, *pktSize)

	loggerFactory := logging.NewDefaultLoggerFactory()
	if *verbose {
		loggerFactory.DefaultLogLevel = logging.LogLevelDebug
	} else {
		loggerFactory.DefaultLogLevel = logging.LogLevelWarn
	}

	// Spawn N*K workers, run them concurrently, aggregate live + final.
	stats := make([]*workerStats, len(specs))
	for i, sp := range specs {
		stats[i] = &workerStats{slot: sp.cred.Slot, subIdx: sp.subIdx}
	}
	var wg sync.WaitGroup
	startBarrier := make(chan struct{}) // released once all workers have allocated
	allocReady := make(chan int, len(specs))

	for i, sp := range specs {
		wg.Add(1)
		go func(idx int, cred *backupCred) {
			defer wg.Done()
			runWorker(idx, cred, dstAddr, *transport, *tcpAllocation, *pktSize, *duration,
				*allocsPerCred, loggerFactory, stats[idx], allocReady, startBarrier)
		}(i, sp.cred)
	}

	// Wait for all allocations or fail-fast on any error.
	allocCount := 0
	allocStart := time.Now()
	for allocCount < len(specs) {
		select {
		case idx := <-allocReady:
			allocCount++
			s := stats[idx]
			if s.allocOK.Load() {
				fmt.Printf("[%s] Allocate OK in %s, relayed %s\n",
					s.label(*allocsPerCred), s.allocDur.Round(time.Millisecond), s.relayed)
			} else {
				fmt.Printf("[%s] Allocate FAILED — see worker error\n",
					s.label(*allocsPerCred))
			}
		case <-time.After(30 * time.Second):
			fmt.Printf("!! timeout waiting for all allocations after %s; only %d/%d ready\n",
				time.Since(allocStart).Round(time.Millisecond), allocCount, len(specs))
			os.Exit(1)
		}
	}
	fmt.Printf("All %d allocations ready in %s, releasing send barrier\n\n",
		len(specs), time.Since(allocStart).Round(time.Millisecond))
	close(startBarrier)

	// Aggregate live tick — every 2s print per-worker + total rate. With
	// allocs-per-cred>1 the live ticker collapses workers down to a per-
	// slot summary to keep the output readable at high N (50 workers ×
	// every 2s = a wall of text otherwise).
	doneCh := make(chan struct{})
	go aggregatePrinter(stats, *allocsPerCred, doneCh)

	wg.Wait()
	close(doneCh)
	time.Sleep(100 * time.Millisecond) // let last printer line flush

	// Final summary.
	fmt.Printf("\n=== RESULT (transport=%s, parallel=%d, allocs-per-cred=%d, workers=%d) ===\n",
		*transport, len(creds), *allocsPerCred, len(specs))
	var totalBytes int64
	var totalPkts int64
	var totalErrs int64
	var maxElapsed time.Duration
	var failedCount int
	for _, s := range stats {
		// Workers whose Allocate failed never reached the send loop, so
		// startTime is the zero value and time.Since(zero) yields a
		// nonsensical 290000-year duration. Print them on their own line
		// and skip them from totals so the aggregate isn't polluted.
		if !s.allocOK.Load() {
			fmt.Printf("  %s: ALLOCATE FAILED — no data sent\n", s.label(*allocsPerCred))
			failedCount++
			continue
		}
		bs := s.bytesSent.Load()
		pk := s.pktsSent.Load()
		er := s.sendErrs.Load()
		totalBytes += bs
		totalPkts += pk
		totalErrs += er
		dur := time.Since(s.startTime)
		if dur > maxElapsed {
			maxElapsed = dur
		}
		bps := float64(bs) * 8 / dur.Seconds()
		fmt.Printf("  %s: %s sent (%d pkts, %d errs) in %s = %s\n",
			s.label(*allocsPerCred), humanBytes(bs), pk, er,
			dur.Round(10*time.Millisecond), humanRate(bps))
	}
	fmt.Printf("  ---\n")
	if maxElapsed > 0 {
		totalBps := float64(totalBytes) * 8 / maxElapsed.Seconds()
		fmt.Printf("  TOTAL:  %s sent (%d pkts, %d errs) over ~%s = %s",
			humanBytes(totalBytes), totalPkts, totalErrs,
			maxElapsed.Round(10*time.Millisecond), humanRate(totalBps))
	} else {
		fmt.Printf("  TOTAL:  no successful allocations")
	}
	if failedCount > 0 {
		fmt.Printf(" (%d/%d worker(s) failed Allocate)", failedCount, len(specs))
	}
	fmt.Printf("\n")
	fmt.Printf("\nNote: client-side rate is what the kernel buffered; the\n")
	fmt.Printf("      true network throughput is what your VPS pv showed.\n")
	fmt.Printf("      Compare both numbers — for UDP they often diverge.\n")
}

// runWorker handles one allocation's full lifecycle: connect, allocate,
// signal ready, wait for barrier, send for duration, log into stats.
func runWorker(idx int, cred *backupCred, dstAddr *net.UDPAddr,
	transport string, tcpAllocation bool, pktSize int, duration time.Duration,
	allocsPerCred int, loggerFactory *logging.DefaultLoggerFactory,
	stats *workerStats, allocReady chan<- int, startBarrier <-chan struct{},
) {
	turnAddr := cred.Address
	tag := stats.label(allocsPerCred)

	// Build the connection that pion/turn runs over.
	var conn net.PacketConn
	switch transport {
	case "udp":
		// Explicitly udp4 — net.ListenPacket("udp", ...) creates a dual-
		// stack socket whose LocalAddr appears as [::]:port (IPv6
		// representation), and pion auto-infers an IPv6 allocation
		// which VK silently drops.
		c, err := net.ListenPacket("udp4", "0.0.0.0:0")
		if err != nil {
			fmt.Printf("[%s] listen udp: %v\n", tag, err)
			allocReady <- idx
			return
		}
		conn = c
	case "tcp":
		dialer := net.Dialer{Timeout: 5 * time.Second}
		tcp, err := dialer.Dial("tcp", turnAddr)
		if err != nil {
			fmt.Printf("[%s] dial tcp: %v\n", tag, err)
			allocReady <- idx
			return
		}
		conn = turn.NewSTUNConn(tcp)
	}
	defer conn.Close()

	cfg := &turn.ClientConfig{
		STUNServerAddr:         turnAddr,
		TURNServerAddr:         turnAddr,
		Conn:                   conn,
		Username:               cred.Username,
		Password:               cred.Password,
		Realm:                  "okcdn.ru",
		Software:               "vk-turn-bw-test",
		LoggerFactory:          loggerFactory,
		RequestedAddressFamily: turn.RequestedAddressFamilyIPv4,
	}
	client, err := turn.NewClient(cfg)
	if err != nil {
		fmt.Printf("[%s] turn.NewClient: %v\n", tag, err)
		allocReady <- idx
		return
	}
	defer client.Close()

	if err := client.Listen(); err != nil {
		fmt.Printf("[%s] client.Listen: %v\n", tag, err)
		allocReady <- idx
		return
	}

	allocStart := time.Now()

	// Two allocation modes:
	//   - Standard (Allocate): UDP allocation. relayConn is a
	//     net.PacketConn; we WriteTo(dstAddr) per packet, relay forwards
	//     to peer via UDP. This is the default and what RFC 5766 covers.
	//   - TCP allocation (AllocateTCP, RFC 6062): relay opens a TCP
	//     connection to the peer (instead of UDP). The actual data flow
	//     uses a SECOND TCP connection from us to the relay, opened via
	//     alloc.Dial("tcp", peerAddr) — that returns a net.Conn that
	//     bidirectionally forwards bytes to the peer over TCP at both
	//     legs (us↔relay TCP, relay↔peer TCP). End-to-end TCP path,
	//     no UDP shaper applies anywhere.
	var sendFn func(payload []byte) (int, error)
	var sendCloser io.Closer

	if tcpAllocation {
		alloc, err := client.AllocateTCP()
		if err != nil {
			fmt.Printf("[%s] AllocateTCP: %v\n", tag, err)
			allocReady <- idx
			return
		}
		defer alloc.Close()

		// Dial through this allocation to the peer. Internally pion
		// sends a CONNECT request to the relay, gets a ConnectionID,
		// opens a separate TCP conn to the relay, and BindConnection
		// to that ID — RFC 6062 dance.
		dstStr := dstAddr.String()
		// alloc.Dial expects "tcp" / "tcp4" / "tcp6"; using "tcp"
		// matches the default IPv4 server.
		dataConn, err := alloc.Dial("tcp", dstStr)
		if err != nil {
			fmt.Printf("[%s] alloc.Dial(%s): %v\n", tag, dstStr, err)
			allocReady <- idx
			return
		}
		sendCloser = dataConn
		sendFn = func(payload []byte) (int, error) {
			return dataConn.Write(payload)
		}
		stats.relayed = alloc.Addr().String()
	} else {
		relayConn, err := client.Allocate()
		if err != nil {
			fmt.Printf("[%s] Allocate: %v\n", tag, err)
			allocReady <- idx
			return
		}
		sendCloser = relayConn
		sendFn = func(payload []byte) (int, error) {
			return relayConn.WriteTo(payload, dstAddr)
		}
		stats.relayed = relayConn.LocalAddr().String()
		// Drain reads in background — pion's UDP relay conn surfaces
		// refresh / binding messages. For TCP allocations the dataConn
		// is a separate stream (the control allocation handles its own
		// refreshes internally) so we don't drain there.
		doneCh := make(chan struct{})
		defer close(doneCh)
		go func() {
			buf := make([]byte, 64*1024)
			for {
				select {
				case <-doneCh:
					return
				default:
				}
				_ = relayConn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
				_, _, err := relayConn.ReadFrom(buf)
				if err != nil {
					if isTimeout(err) || err == io.EOF {
						continue
					}
					return
				}
			}
		}()
	}
	defer sendCloser.Close()

	stats.allocDur = time.Since(allocStart)
	stats.allocOK.Store(true)
	allocReady <- idx

	// Wait for all workers to finish allocating before sending starts —
	// gives a clean comparison window where everyone is sending in the
	// same time slice.
	<-startBarrier

	payload := make([]byte, pktSize)
	if _, err := rand.Read(payload); err != nil {
		fmt.Printf("[%s] rand: %v\n", tag, err)
		return
	}

	stats.startTime = time.Now()
	deadline := stats.startTime.Add(duration)

	for time.Now().Before(deadline) {
		n, err := sendFn(payload)
		if err != nil {
			stats.sendErrs.Add(1)
			stats.lastErr.Store(err)
			if stats.sendErrs.Load() > 100 {
				return
			}
			time.Sleep(10 * time.Millisecond)
			continue
		}
		stats.bytesSent.Add(int64(n))
		stats.pktsSent.Add(1)
	}
}

// aggregatePrinter ticks every 2s and prints per-worker (or per-slot,
// when allocs-per-cred>1) + total rate. Per-slot collapse keeps the
// output readable when there are 50 workers behind 5 creds.
func aggregatePrinter(stats []*workerStats, allocsPerCred int, doneCh <-chan struct{}) {
	type snap struct {
		t     time.Time
		bytes int64
	}
	prev := make([]snap, len(stats))
	for i, s := range stats {
		prev[i] = snap{t: time.Now(), bytes: s.bytesSent.Load()}
	}

	// When collapsing to per-slot, we need a deterministic order. Walk
	// stats in order and remember which slot each bucket index belongs
	// to so labels stay stable across ticks.
	var slotOrder []int            // distinct slot indices, in first-seen order
	slotIdxByValue := map[int]int{} // slot value → index into slotOrder/buckets
	for _, s := range stats {
		if _, seen := slotIdxByValue[s.slot]; !seen {
			slotIdxByValue[s.slot] = len(slotOrder)
			slotOrder = append(slotOrder, s.slot)
		}
	}

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-doneCh:
			return
		case t := <-ticker.C:
			var total int64
			// Per-worker deltas this tick.
			deltas := make([]int64, len(stats))
			for i, s := range stats {
				cur := s.bytesSent.Load()
				deltas[i] = cur - prev[i].bytes
				total += deltas[i]
				prev[i] = snap{t: t, bytes: cur}
			}

			parts := []string{}
			if allocsPerCred <= 1 {
				// Per-worker line, current behaviour.
				for i, s := range stats {
					rate := float64(deltas[i]) * 8 / 2.0
					parts = append(parts, fmt.Sprintf("[s%d]%s",
						s.slot, humanRate(rate)))
				}
			} else {
				// Collapse: sum deltas per slot.
				slotSum := make([]int64, len(slotOrder))
				for i, s := range stats {
					slotSum[slotIdxByValue[s.slot]] += deltas[i]
				}
				for i, slot := range slotOrder {
					rate := float64(slotSum[i]) * 8 / 2.0
					parts = append(parts, fmt.Sprintf("[s%d×%d]%s",
						slot, allocsPerCred, humanRate(rate)))
				}
			}

			totalRate := float64(total) * 8 / 2.0
			fmt.Printf("  %s   %s   TOTAL=%s\n",
				time.Now().Format("15:04:05"),
				strings.Join(parts, "  "),
				humanRate(totalRate))
		}
	}
}

func loadCred(path string, slot int) (*backupCred, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var bf backupFile
	if err := json.Unmarshal(data, &bf); err != nil {
		return nil, fmt.Errorf("parse backup JSON: %w", err)
	}
	for i := range bf.TurnPool.Creds {
		c := &bf.TurnPool.Creds[i]
		if c.Slot == slot {
			return c, nil
		}
	}
	return nil, fmt.Errorf("no cred for slot %d in %s", slot, path)
}

// loadAllCreds returns every cred in the backup, sorted by slot index.
// The slot indices may have gaps — that's fine, callers just want a list
// of distinct creds, not contiguous indices.
func loadAllCreds(path string) ([]*backupCred, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var bf backupFile
	if err := json.Unmarshal(data, &bf); err != nil {
		return nil, fmt.Errorf("parse backup JSON: %w", err)
	}
	out := make([]*backupCred, len(bf.TurnPool.Creds))
	for i := range bf.TurnPool.Creds {
		c := bf.TurnPool.Creds[i]
		out[i] = &c
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Slot < out[j].Slot })
	return out, nil
}

func slotsOf(creds []*backupCred) []int {
	out := make([]int, len(creds))
	for i, c := range creds {
		out[i] = c.Slot
	}
	return out
}

func humanBytes(b int64) string {
	const k = 1024.0
	switch {
	case float64(b) >= k*k*k:
		return fmt.Sprintf("%.2f GiB", float64(b)/k/k/k)
	case float64(b) >= k*k:
		return fmt.Sprintf("%.2f MiB", float64(b)/k/k)
	case float64(b) >= k:
		return fmt.Sprintf("%.1f KiB", float64(b)/k)
	default:
		return fmt.Sprintf("%d B", b)
	}
}

// humanRate formats bits-per-second adaptively. Single-conn UDP write
// rate easily hits Gbps so don't pin to a single unit.
func humanRate(bps float64) string {
	switch {
	case bps >= 1e9:
		return fmt.Sprintf("%.2f Gbps", bps/1e9)
	case bps >= 1e6:
		return fmt.Sprintf("%.2f Mbps", bps/1e6)
	case bps >= 1e3:
		return fmt.Sprintf("%.1f kbps", bps/1e3)
	default:
		return fmt.Sprintf("%.0f bps", bps)
	}
}

func isTimeout(err error) bool {
	if err == nil {
		return false
	}
	if t, ok := err.(interface{ Timeout() bool }); ok && t.Timeout() {
		return true
	}
	return strings.Contains(err.Error(), "timeout") || strings.Contains(err.Error(), "deadline exceeded")
}
