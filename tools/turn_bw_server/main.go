// turn_bw_server — receives traffic from a turn_bw_test client and reports
// per-source bandwidth and packet rates. Distinguishes parallel TURN
// allocations by source (ip,port) tuple — each VK TURN allocation has its
// own relayed transport address on the relay, so they show up as distinct
// (src_ip, src_port) here.
//
// Replaces the `nc -u -k -l 9999 | pv -W -b -r -t > /dev/null` workflow,
// which (a) prints a rate only during transfer and drops to 0 the moment
// the client stops, and (b) aggregates everything into one number, hiding
// per-allocation behaviour that the shaping investigation needs.
//
// What this gives you instead:
//   - Live per-source rate every -interval (default 2s) plus a TOTAL row
//     when more than one source is active.
//   - A FINAL line per source after -idle-timeout (default 10s) of silence,
//     with cumulative bytes/packets/duration/avg-rate/avg-pkt-size.
//   - On Ctrl-C, a full final summary across every source seen.
//
// Setup on the VPS:
//   # Build (anywhere with Go):
//   GOOS=linux GOARCH=amd64 go build -o turn_bw_server ./tools/turn_bw_server
//   scp turn_bw_server vps:~
//   # Run:
//   ./turn_bw_server -port=9999
//   # Open the firewall first; iptables example:
//   sudo iptables -A INPUT -p udp --dport 9999 -j ACCEPT
//
// Then on the client side (Mac):
//   go run ./tools/turn_bw_test -creds=backup.json -parallel=5 \
//       -dst-ip=<vps-ip> -dst-port=9999 -duration=30s
//
// Output is line-oriented and timestamped — suitable for `tee logfile.txt`
// and grep-based post-analysis.
//
// Notes:
//   - UDP only. RFC 6062 TCP allocations are currently rejected by VK
//     (error 442), and the TURN ?transport=tcp control transport still
//     uses UDP on the relay→peer leg. If that ever changes, add a TCP
//     listener mirroring the UDP one.
//   - "source" = the (ip,port) the kernel reports for received datagrams.
//     For TURN that's the relay's IP and the per-allocation relayed port.
//     If the client restarts and gets a new allocation, it shows up as a
//     new source — bytes from the previous allocation are not folded in.

package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type srcStats struct {
	bytes      atomic.Int64
	packets    atomic.Int64
	lastBytes  int64 // snapshot from previous tick — only the stats goroutine touches this
	firstAt    time.Time
	lastAtUnix atomic.Int64 // unix nanos; lock-free reads/writes
	finalised  atomic.Bool
}

func (s *srcStats) updateLast(now time.Time) {
	s.lastAtUnix.Store(now.UnixNano())
}

func (s *srcStats) lastAt() time.Time {
	return time.Unix(0, s.lastAtUnix.Load())
}

var sources sync.Map // map[string]*srcStats — key is src.String() ("ip:port")

func main() {
	port := flag.Int("port", 9999, "UDP port to listen on")
	bind := flag.String("bind", "0.0.0.0", "interface to bind (0.0.0.0 for all)")
	interval := flag.Duration("interval", 2*time.Second, "stats print interval")
	idleTimeout := flag.Duration("idle-timeout", 10*time.Second,
		"a source with no packets for this long is finalised (final line printed)")
	bufSize := flag.Int("buf-size", 65535, "per-recv buffer size, bytes")
	sockBuf := flag.Int("sock-buf", 8<<20, "kernel SO_RCVBUF for the UDP socket, bytes")
	verbose := flag.Bool("v", false, "verbose: also log every new-source detection")
	flag.Parse()

	addr := &net.UDPAddr{IP: net.ParseIP(*bind), Port: *port}
	if addr.IP == nil {
		fatalf("bad -bind address %q", *bind)
	}
	conn, err := net.ListenUDP("udp4", addr)
	if err != nil {
		fatalf("listen UDP %s: %v", addr, err)
	}
	defer conn.Close()

	if err := conn.SetReadBuffer(*sockBuf); err != nil {
		warnf("SetReadBuffer(%d) failed: %v (continuing with default)", *sockBuf, err)
	}

	logf("turn_bw_server listening on %s/udp (interval=%v idle-timeout=%v)",
		addr, *interval, *idleTimeout)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		fmt.Println()
		logf("received %s — final summary across all sources:", sig)
		printFinalAll()
		os.Exit(0)
	}()

	go statsLoop(*interval, *idleTimeout, *verbose)

	buf := make([]byte, *bufSize)
	for {
		n, src, err := conn.ReadFromUDP(buf)
		if err != nil {
			warnf("ReadFromUDP: %v", err)
			continue
		}
		now := time.Now()
		key := src.String()

		v, ok := sources.Load(key)
		var s *srcStats
		if !ok {
			s = &srcStats{firstAt: now}
			actual, loaded := sources.LoadOrStore(key, s)
			if loaded {
				s = actual.(*srcStats)
			} else if *verbose {
				logf("new source: %s", key)
			}
		} else {
			s = v.(*srcStats)
		}

		// If a previously-finalised source resumes sending, log it but keep
		// the cumulative counters — operator can see continuity in the live
		// stats. firstAt stays at the original first packet so duration
		// reflects total span.
		if s.finalised.CompareAndSwap(true, false) {
			logf("%s resumed sending after idle", key)
		}

		s.bytes.Add(int64(n))
		s.packets.Add(1)
		s.updateLast(now)
	}
}

// statsLoop ticks every `interval`, snapshots all sources, prints per-source
// rate + a TOTAL row, and finalises any source idle longer than `idleTimeout`.
func statsLoop(interval, idleTimeout time.Duration, verbose bool) {
	type row struct {
		key     string
		bytes   int64
		packets int64
		delta   int64
		idle    time.Duration
		s       *srcStats
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for tick := range ticker.C {
		var rows []row
		var totalBytes, totalDelta int64
		var liveCount int

		sources.Range(func(k, v any) bool {
			s := v.(*srcStats)
			cur := s.bytes.Load()
			delta := cur - s.lastBytes
			s.lastBytes = cur
			idle := tick.Sub(s.lastAt())
			rows = append(rows, row{
				key: k.(string), bytes: cur, packets: s.packets.Load(),
				delta: delta, idle: idle, s: s,
			})
			totalBytes += cur
			totalDelta += delta
			if !s.finalised.Load() {
				liveCount++
			}
			return true
		})
		if len(rows) == 0 {
			continue
		}
		sort.Slice(rows, func(i, j int) bool { return rows[i].key < rows[j].key })

		// Only print the periodic block if at least one source moved this
		// tick; avoids walls of "0/s idle=10s" noise long after a test ends.
		// Finalisation still happens below regardless.
		anyDelta := totalDelta > 0
		if anyDelta {
			logf("stats over last %v:", interval)
			for _, r := range rows {
				if r.delta == 0 && r.s.finalised.Load() {
					continue
				}
				rate := float64(r.delta) / interval.Seconds()
				fmt.Printf("  %-22s  %9s  %9s/s   total %9s (%6d pkts) idle=%v\n",
					r.key,
					fmtBytes(r.delta),
					fmtBytes(int64(rate)),
					fmtBytes(r.bytes),
					r.packets,
					r.idle.Round(100*time.Millisecond),
				)
			}
			if liveCount > 1 {
				totalRate := float64(totalDelta) / interval.Seconds()
				fmt.Printf("  %-22s  %9s  %9s/s   total %9s\n",
					"TOTAL", fmtBytes(totalDelta), fmtBytes(int64(totalRate)),
					fmtBytes(totalBytes))
			}
		}

		// Finalise any source that's been silent too long.
		for _, r := range rows {
			if r.idle <= idleTimeout || r.s.finalised.Load() {
				continue
			}
			if !r.s.finalised.CompareAndSwap(false, true) {
				continue
			}
			duration := r.s.lastAt().Sub(r.s.firstAt)
			if duration <= 0 {
				duration = interval
			}
			rate := float64(r.bytes) / duration.Seconds()
			avgPkt := int64(0)
			if r.packets > 0 {
				avgPkt = r.bytes / r.packets
			}
			logf("FINAL %s: %s in %v = %s/s (%d pkts, %d-byte avg)",
				r.key, fmtBytes(r.bytes), duration.Round(100*time.Millisecond),
				fmtBytes(int64(rate)), r.packets, avgPkt)
		}
	}
}

// printFinalAll dumps a one-line summary per source. Used on shutdown so
// the operator gets every source represented even if some never timed out.
func printFinalAll() {
	type row struct {
		key string
		s   *srcStats
	}
	var rows []row
	sources.Range(func(k, v any) bool {
		rows = append(rows, row{key: k.(string), s: v.(*srcStats)})
		return true
	})
	sort.Slice(rows, func(i, j int) bool { return rows[i].key < rows[j].key })

	if len(rows) == 0 {
		logf("(no sources seen)")
		return
	}

	var totalBytes, totalPkts int64
	for _, r := range rows {
		bytes := r.s.bytes.Load()
		packets := r.s.packets.Load()
		duration := r.s.lastAt().Sub(r.s.firstAt)
		if duration <= 0 {
			duration = time.Second
		}
		rate := float64(bytes) / duration.Seconds()
		avgPkt := int64(0)
		if packets > 0 {
			avgPkt = bytes / packets
		}
		fmt.Printf("  %-22s  %s in %v = %s/s (%d pkts, %d-byte avg)\n",
			r.key, fmtBytes(bytes), duration.Round(100*time.Millisecond),
			fmtBytes(int64(rate)), packets, avgPkt)
		totalBytes += bytes
		totalPkts += packets
	}
	if len(rows) > 1 {
		fmt.Printf("  %-22s  %s across %d sources (%d pkts)\n",
			"TOTAL", fmtBytes(totalBytes), len(rows), totalPkts)
	}
}

// fmtBytes renders a byte count with a binary unit (KiB / MiB / …) but
// short suffix (K / M / G / T) — same convention as the client tool's
// progress lines so output composes well in side-by-side comparisons.
func fmtBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%dB", n)
	}
	div, exp := int64(unit), 0
	for n2 := n / unit; n2 >= unit; n2 /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.2f%cB", float64(n)/float64(div), "KMGT"[exp])
}

func logf(f string, args ...any) {
	fmt.Printf("[%s] "+f+"\n", append([]any{time.Now().Format("15:04:05.000")}, args...)...)
}

func warnf(f string, args ...any) {
	fmt.Fprintf(os.Stderr, "[%s] WARN: "+f+"\n",
		append([]any{time.Now().Format("15:04:05.000")}, args...)...)
}

func fatalf(f string, args ...any) {
	fmt.Fprintf(os.Stderr, "[%s] FATAL: "+f+"\n",
		append([]any{time.Now().Format("15:04:05.000")}, args...)...)
	os.Exit(1)
}
