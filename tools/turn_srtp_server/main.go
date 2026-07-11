// turn_srtp_server — server-side counterpart of tools/turn_srtp_test.
//
// Listens on a UDP port, accepts DTLS-SRTP sessions (one per source
// address), decrypts incoming RTP packets, and prints per-source +
// aggregate throughput. Used to measure what fraction of traffic
// SRTP-framed by turn_srtp_test actually reaches the server through
// VK's TURN relay.
//
// Usage on VPS:
//   ./turn_srtp_server -listen 0.0.0.0:9998 -duration 30s
//
// Or cross-compile for FreeBSD/Linux:
//   CGO_ENABLED=0 GOOS=freebsd GOARCH=amd64 \
//     go build -o turn_srtp_server-freebsd-amd64 ./tools/turn_srtp_server/

package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/cacggghp/vk-turn-proxy/pkg/proxy/srtpwrap"
)

type sourceStats struct {
	addr      string
	bytesRecv atomic.Int64
	pktsRecv  atomic.Int64
	firstRecv time.Time
	lastRecv  atomic.Int64 // unix nanos
}

func main() {
	var (
		listen   = flag.String("listen", "0.0.0.0:9998", "listen address (UDP)")
		duration = flag.Duration("duration", 0, "auto-exit after this duration (0 = run until SIGINT)")
		quiet    = flag.Bool("q", false, "don't print per-tick rate (only final summary)")
	)
	flag.Parse()

	la, err := net.ResolveUDPAddr("udp", *listen)
	if err != nil {
		log.Fatalf("resolve listen addr: %v", err)
	}
	srv, err := srtpwrap.Listen(la)
	if err != nil {
		log.Fatalf("srtpwrap.Listen: %v", err)
	}
	defer srv.Close()
	log.Printf("listening on %s (DTLS-SRTP)", srv.Addr())

	ctx, cancel := context.WithCancel(context.Background())
	if *duration > 0 {
		var cancelTimer context.CancelFunc
		ctx, cancelTimer = context.WithTimeout(ctx, *duration)
		defer cancelTimer()
	}
	defer cancel()

	// SIGINT/SIGTERM → graceful exit
	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Printf("signal received, shutting down")
		cancel()
	}()

	var (
		statsMu sync.Mutex
		stats   = make(map[string]*sourceStats)
	)

	getStats := func(addr string) *sourceStats {
		statsMu.Lock()
		s, ok := stats[addr]
		if !ok {
			s = &sourceStats{addr: addr, firstRecv: time.Now()}
			stats[addr] = s
		}
		statsMu.Unlock()
		return s
	}

	// Accept loop
	go func() {
		for {
			c, err := srv.Accept(ctx)
			if err != nil {
				if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, net.ErrClosed) {
					return
				}
				log.Printf("accept: %v", err)
				continue
			}
			s := getStats(c.RemoteAddr().String())
			log.Printf("new SRTP session from %s", c.RemoteAddr())
			go func() {
				defer c.Close()
				buf := make([]byte, 4096)
				for {
					n, err := c.Read(buf)
					if err != nil {
						if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
							return
						}
						log.Printf("[%s] read: %v", s.addr, err)
						return
					}
					if n == 0 {
						continue
					}
					s.bytesRecv.Add(int64(n))
					s.pktsRecv.Add(1)
					s.lastRecv.Store(time.Now().UnixNano())
				}
			}()
		}
	}()

	// Print tick
	startTime := time.Now()
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()

PRINT:
	for {
		select {
		case <-tick.C:
			if !*quiet {
				printRate(&statsMu, stats, time.Since(startTime))
			}
		case <-ctx.Done():
			break PRINT
		}
	}

	fmt.Println()
	fmt.Println("=== FINAL ===")
	printRate(&statsMu, stats, time.Since(startTime))
	printSummary(&statsMu, stats, time.Since(startTime))
}

func printRate(mu *sync.Mutex, stats map[string]*sourceStats, elapsed time.Duration) {
	mu.Lock()
	keys := make([]string, 0, len(stats))
	for k := range stats {
		keys = append(keys, k)
	}
	mu.Unlock()
	sort.Strings(keys)

	fmt.Printf("\n[%6.2fs]  per-source rate (%d sources):\n", elapsed.Seconds(), len(keys))
	for _, k := range keys {
		mu.Lock()
		s := stats[k]
		mu.Unlock()
		secs := elapsed.Seconds()
		if secs <= 0 {
			secs = 0.001
		}
		bps := float64(s.bytesRecv.Load()) / secs
		fmt.Printf("  %-25s   %.1f KB/s   pkts=%d   cum=%d B\n",
			s.addr, bps/1024, s.pktsRecv.Load(), s.bytesRecv.Load())
	}
}

func printSummary(mu *sync.Mutex, stats map[string]*sourceStats, elapsed time.Duration) {
	mu.Lock()
	defer mu.Unlock()
	var total int64
	var pkts int64
	for _, s := range stats {
		total += s.bytesRecv.Load()
		pkts += s.pktsRecv.Load()
	}
	secs := elapsed.Seconds()
	if secs <= 0 {
		secs = 0.001
	}
	fmt.Println()
	fmt.Printf("Aggregate:  %.1f KB/s  (%.2f Mbit/s)   %d pkts   from %d sources   %s\n",
		float64(total)/1024/secs,
		float64(total)*8/1_000_000/secs,
		pkts, len(stats), elapsed.Round(100*time.Millisecond))
}
