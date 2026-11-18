package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// Tuning defaults, tested on a real network.
const (
	defaultCap = 1800.0
	minRate    = 100.0
	window     = 50 * time.Millisecond
)

type client struct {
	conn  icmpConn
	local *net.UDPConn
	cap   float64
	dup   int

	seq   atomic.Uint32
	caddr atomic.Pointer[net.UDPAddr]

	// counters (read by the stats printer)
	sent, replies, dataReplies atomic.Int64
	upBytes, downBytes         atomic.Int64
	winData                    atomic.Int64
	lastReply                  atomic.Int64 // unix nanos
	rateBits                   atomic.Uint64

	stop chan struct{}
	once sync.Once
}

func newClient(conn icmpConn, local *net.UDPConn, cap float64, dup int) *client {
	if dup < 1 {
		dup = 1
	}
	c := &client{conn: conn, local: local, cap: cap, dup: dup, stop: make(chan struct{})}
	c.setRate(minRate)
	return c
}

func (c *client) setRate(r float64) { c.rateBits.Store(uint64(r * 1000)) }
func (c *client) rate() float64     { return float64(c.rateBits.Load()) / 1000 }

func (c *client) send(payload []byte) {
	seq := uint16(c.seq.Add(1))
	if err := c.conn.Send(echoRequest(ident, seq, payload)); err == nil {
		c.sent.Add(1)
	}
}

func (c *client) shutdown() { c.once.Do(func() { close(c.stop) }) }

func (c *client) stopped() bool {
	select {
	case <-c.stop:
		return true
	default:
		return false
	}
}

// uplink: local UDP datagram -> echo request(s) carrying it, plus one poll so a reply slot is available.
func (c *client) uplink() {
	buf := make([]byte, 65535)
	for !c.stopped() {
		_ = c.local.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		n, addr, err := c.local.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		c.caddr.Store(addr)
		c.upBytes.Add(int64(n))
		p := dataPayload(buf[:n])
		for i := 0; i < c.dup; i++ {
			c.send(p)
		}
		c.send(pollPayload)
	}
}

// downlink: echo reply carrying "RT" 0x01 + data -> local client.
func (c *client) downlink() {
	buf := make([]byte, 65535)
	for !c.stopped() {
		n, err := c.conn.Recv(buf)
		if err != nil {
			if errors.Is(err, errTimeout) {
				continue
			}
			if c.stopped() {
				return
			}
			time.Sleep(10 * time.Millisecond)
			continue
		}
		r, ok := parseReply(buf[:n])
		if !ok || r.id != ident || !bytes.HasPrefix(r.payload, magic) {
			continue
		}
		c.replies.Add(1)
		c.lastReply.Store(time.Now().UnixNano())
		if len(r.payload) > 3 && r.payload[2] == typeData {
			c.dataReplies.Add(1)
			c.winData.Add(1)
			if a := c.caddr.Load(); a != nil {
				d := r.payload[3:]
				if _, err := c.local.WriteToUDP(d, a); err == nil {
					c.downBytes.Add(int64(len(d)))
				}
			}
		}
	}
}

// pacer sends empty polls at the adaptive rate. Same algorithm as icmp_client.py.
func (c *client) pacer() {
	ema := 0.0
	now := time.Now()
	next := now
	winStart := now
	for !c.stopped() {
		now = time.Now()
		if el := now.Sub(winStart); el >= window {
			inst := float64(c.winData.Swap(0)) / el.Seconds()
			ema = ema*0.7 + inst*0.3
			r := 1.5*ema + minRate
			if r > c.cap {
				r = c.cap
			}
			if r < minRate {
				r = minRate
			}
			c.setRate(r)
			winStart = now
		}
		step := time.Duration(float64(time.Second) / c.rate())
		for n := 0; !next.After(now) && n < 64; n++ {
			c.send(pollPayload)
			next = next.Add(step)
		}
		if next.Before(now.Add(-100 * time.Millisecond)) {
			next = now
		}
		wait := next.Sub(time.Now())
		if wait > 10*time.Millisecond {
			wait = 10 * time.Millisecond
		}
		if wait > 0 {
			time.Sleep(wait)
		}
	}
}

// stats prints one machine-readable line every interval for the app (live speed and path health).
func (c *client) stats(every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	var ps, pr, pu, pd int64
	for {
		select {
		case <-c.stop:
			return
		case <-t.C:
		}
		s, r, u, d := c.sent.Load(), c.replies.Load(), c.upBytes.Load(), c.downBytes.Load()
		ds, dr := s-ps, r-pr
		loss := 0.0
		if ds > 0 {
			loss = 100 * (1 - float64(dr)/float64(ds))
			if loss < 0 {
				loss = 0
			}
		}
		idle := -1.0
		if lr := c.lastReply.Load(); lr > 0 {
			idle = time.Since(time.Unix(0, lr)).Seconds()
		}
		fmt.Printf("STATS up=%d down=%d upTotal=%d downTotal=%d sent=%d replies=%d loss=%.1f rate=%.0f idle=%.1f\n",
			int64(float64(u-pu)/every.Seconds()), int64(float64(d-pd)/every.Seconds()), u, d, ds, dr, loss, c.rate(), idle)
		ps, pr, pu, pd = s, r, u, d
	}
}

func runICMP(args []string) error {
	fs := flag.NewFlagSet("icmp", flag.ExitOnError)
	server := fs.String("server", "", "server IPv4 address or hostname")
	listen := fs.String("listen", "127.0.0.1:18096", "local UDP address the Hysteria2 client sends to")
	capRate := fs.Float64("cap", defaultCap, "maximum polls per second")
	dup := fs.Int("dup", 1, "send each datagram this many times")
	parent := fs.Int("parent-pid", 0, "exit when this process dies")
	statsEvery := fs.Duration("stats", 2*time.Second, "stats line interval (0 = off)")
	_ = fs.Parse(args)
	if *server == "" {
		return errors.New("--server is required")
	}
	la, err := net.ResolveUDPAddr("udp4", *listen)
	if err != nil {
		return err
	}
	local, err := net.ListenUDP("udp4", la)
	if err != nil {
		return fmt.Errorf("cannot listen on %s: %w", *listen, err)
	}
	_ = local.SetReadBuffer(4 << 20)
	_ = local.SetWriteBuffer(4 << 20)
	conn, err := openICMP(*server)
	if err != nil {
		return fmt.Errorf("cannot open ICMP socket: %w", err)
	}
	c := newClient(conn, local, *capRate, *dup)
	fmt.Printf("READY local=%s\n", local.LocalAddr())

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() { <-sig; c.shutdown() }()
	if *parent > 0 {
		go func() {
			for !c.stopped() {
				time.Sleep(time.Second)
				if !alive(*parent) {
					c.shutdown()
				}
			}
		}()
	}
	var wg sync.WaitGroup
	for _, f := range []func(){c.uplink, c.downlink, c.pacer} {
		wg.Add(1)
		go func(f func()) { defer wg.Done(); f() }(f)
	}
	if *statsEvery > 0 {
		go c.stats(*statsEvery)
	}
	wg.Wait()
	_ = conn.Close()
	_ = local.Close()
	return nil
}

func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}
