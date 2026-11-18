package main

import (
	"bytes"
	"encoding/binary"
	"net"
	"sync"
	"testing"
	"time"
)

func TestChecksumKnownVector(t *testing.T) {
	// Echo request id=0x5254 seq=1 payload "RT\x00": checksum must make the sum fold to 0xFFFF.
	pkt := echoRequest(ident, 1, []byte("RT\x00"))
	if checksum(pkt) != 0 {
		t.Fatalf("checksum over packet with checksum should be 0, got %#x", checksum(pkt))
	}
	if pkt[0] != 8 || binary.BigEndian.Uint16(pkt[4:]) != ident || binary.BigEndian.Uint16(pkt[6:]) != 1 {
		t.Fatalf("bad header % x", pkt[:8])
	}
}

func TestParseReplyWithAndWithoutIPHeader(t *testing.T) {
	icmp := []byte{0, 0, 0, 0, 0x52, 0x54, 0, 7, 'R', 'T', 1, 'x'}
	r, ok := parseReply(icmp)
	if !ok || r.id != ident || r.seq != 7 || !bytes.Equal(r.payload, []byte("RT\x01x")) {
		t.Fatalf("no header: %+v %v", r, ok)
	}
	ip := make([]byte, 20)
	ip[0] = 0x45
	r, ok = parseReply(append(ip, icmp...))
	if !ok || r.seq != 7 {
		t.Fatalf("with header: %+v %v", r, ok)
	}
	if _, ok := parseReply([]byte{8, 0, 0, 0, 0, 0, 0, 0}); ok {
		t.Fatal("echo request must not parse as reply")
	}
}

func TestPollPayloadShape(t *testing.T) {
	if len(pollPayload) != 64 || !bytes.HasPrefix(pollPayload, []byte("RT\x00")) {
		t.Fatalf("poll payload % x", pollPayload)
	}
	if !bytes.Equal(dataPayload([]byte("ab")), []byte("RT\x01ab")) {
		t.Fatal("data payload")
	}
}

// fakeServer reproduces icmp_server.py: queue downlink datagrams, hold polls up to HOLD, reply one datagram per
// pending request, and forward uplink data to a UDP target (here an echo service).
type fakeServer struct {
	mu      sync.Mutex
	q       [][]byte
	pend    []pending
	replies chan []byte
	target  *net.UDPConn
	lossN   int // drop every Nth request (0 = none)
	n       int
}

type pending struct {
	at      time.Time
	id, seq uint16
}

func (s *fakeServer) Send(pkt []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.n++
	if s.lossN > 0 && s.n%s.lossN == 0 {
		return nil
	}
	if pkt[0] != 8 || checksum(pkt) != 0 {
		panic("client sent a bad echo request")
	}
	id, seq := binary.BigEndian.Uint16(pkt[4:]), binary.BigEndian.Uint16(pkt[6:])
	p := pkt[8:]
	if !bytes.HasPrefix(p, magic) {
		return nil
	}
	if p[2] == typeData && len(p) > 3 {
		_, _ = s.target.Write(append([]byte(nil), p[3:]...))
	}
	s.pend = append(s.pend, pending{time.Now(), id, seq})
	s.flushLocked()
	return nil
}

func (s *fakeServer) push(d []byte) {
	s.mu.Lock()
	if len(s.q) < 150 {
		s.q = append(s.q, d)
	}
	s.flushLocked()
	s.mu.Unlock()
}

func (s *fakeServer) flushLocked() {
	for len(s.q) > 0 && len(s.pend) > 0 {
		p := s.pend[0]
		s.pend = s.pend[1:]
		d := s.q[0]
		s.q = s.q[1:]
		s.emit(p, append([]byte("RT\x01"), d...))
	}
	for len(s.pend) > 0 && (time.Since(s.pend[0].at) > 250*time.Millisecond || len(s.pend) > 600) {
		p := s.pend[0]
		s.pend = s.pend[1:]
		s.emit(p, []byte("RT\x00"))
	}
}

func (s *fakeServer) emit(p pending, payload []byte) {
	b := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint16(b[4:], p.id)
	binary.BigEndian.PutUint16(b[6:], p.seq)
	copy(b[8:], payload)
	ip := make([]byte, 20)
	ip[0] = 0x45 // macOS hands the IPv4 header to datagram ICMP sockets
	select {
	case s.replies <- append(ip, b...):
	default:
	}
}

func (s *fakeServer) Recv(buf []byte) (int, error) {
	select {
	case d := <-s.replies:
		return copy(buf, d), nil
	case <-time.After(50 * time.Millisecond):
		s.mu.Lock()
		s.flushLocked()
		s.mu.Unlock()
		return 0, errTimeout
	}
}

func (s *fakeServer) Close() error { return nil }

func TestRoundTripThroughFakeRelay(t *testing.T) {
	// UDP echo service standing in for Hysteria2 on the server.
	echo, _ := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	defer echo.Close()
	srv := &fakeServer{replies: make(chan []byte, 4096), lossN: 20}
	srv.target, _ = net.DialUDP("udp4", nil, echo.LocalAddr().(*net.UDPAddr))
	go func() {
		buf := make([]byte, 65535)
		for {
			n, a, err := echo.ReadFromUDP(buf)
			if err != nil {
				return
			}
			_, _ = echo.WriteToUDP(buf[:n], a)
		}
	}()
	// Server-side socket receiving the echo back: queue it for downlink.
	go func() {
		buf := make([]byte, 65535)
		for {
			n, err := srv.target.Read(buf)
			if err != nil {
				return
			}
			srv.push(append([]byte(nil), buf[:n]...))
		}
	}()

	local, _ := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	c := newClient(srv, local, defaultCap, 1)
	for _, f := range []func(){c.uplink, c.downlink, c.pacer} {
		go f()
	}
	defer c.shutdown()

	app, _ := net.DialUDP("udp4", nil, local.LocalAddr().(*net.UDPAddr))
	defer app.Close()
	got := map[string]bool{}
	deadline := time.Now().Add(5 * time.Second)
	for i := 0; i < 200; i++ {
		_, _ = app.Write([]byte{byte(i), 'h', 'y'})
	}
	buf := make([]byte, 100)
	for len(got) < 180 && time.Now().Before(deadline) {
		_ = app.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		n, err := app.Read(buf)
		if err != nil {
			continue
		}
		got[string(buf[:n])] = true
	}
	// 5% of requests are dropped, so a few datagrams may be lost (Hysteria2/Brutal handles that for real).
	if len(got) < 180 {
		t.Fatalf("only %d of 200 datagrams came back", len(got))
	}
	if c.rate() <= minRate {
		t.Logf("rate stayed at minimum (%.0f); fine for a short burst", c.rate())
	}
	if c.sent.Load() < 200 {
		t.Fatalf("sent only %d echo requests", c.sent.Load())
	}
}

func TestPollRateAdaptsAndCaps(t *testing.T) {
	srv := &fakeServer{replies: make(chan []byte, 65536)}
	srv.target, _ = net.DialUDP("udp4", nil, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 9})
	local, _ := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	c := newClient(srv, local, 300, 1)
	go c.downlink()
	go c.pacer()
	defer c.shutdown()
	// Heavy downlink: the server always has data, so every poll returns data and the rate climbs to the cap.
	stop := time.After(1500 * time.Millisecond)
loop:
	for {
		select {
		case <-stop:
			break loop
		default:
			srv.push([]byte("down"))
			time.Sleep(200 * time.Microsecond)
		}
	}
	if r := c.rate(); r < 250 || r > 300 {
		t.Fatalf("rate %.0f, want close to the cap of 300", r)
	}
}
