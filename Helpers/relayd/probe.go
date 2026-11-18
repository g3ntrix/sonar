package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"sort"
	"strings"
	"sync"
	"time"
)

// ProbeResult is printed as one JSON line. The app parses it (tester stage 2, wizard live checklist, Change IP).
type ProbeResult struct {
	Server string `json:"server"`
	// Plain pings (no magic). Answered by the relay (acting as a ping responder) or by the kernel.
	PingSent    int     `json:"pingSent"`
	PingReplies int     `json:"pingReplies"`
	RTTMs       float64 `json:"rttMs"` // median of plain pings
	// Tunnel polls ("RT" 0x00 + padding). The relay answers with exactly "RT" 0x00 (or data); a kernel that
	// still answers pings echoes the whole 64-byte payload back, which means icmp_echo_ignore_all is 0.
	PollSent      int     `json:"pollSent"`
	RelayReplies  int     `json:"relayReplies"`
	KernelReplies int     `json:"kernelReplies"`
	LossPct       float64 `json:"lossPct"`
	Verdict       string  `json:"verdict"` // relay | kernel-only | relay+kernel | silent | error
	Error         string  `json:"error,omitempty"`
}

func runProbe(args []string) error {
	fs := flag.NewFlagSet("probe", flag.ExitOnError)
	server := fs.String("server", "", "server IPv4 address or hostname")
	count := fs.Int("count", 20, "pings and polls to send (each)")
	interval := fs.Duration("interval", 20*time.Millisecond, "gap between packets")
	wait := fs.Duration("wait", 1500*time.Millisecond, "extra wait for replies (the relay holds polls up to 0.25 s)")
	_ = fs.Parse(args)
	if *server == "" {
		return errors.New("--server is required")
	}
	res := probe(*server, *count, *interval, *wait)
	b, _ := json.Marshal(res)
	fmt.Println(string(b))
	return nil
}

func probe(server string, count int, interval, wait time.Duration) ProbeResult {
	res := ProbeResult{Server: server}
	conn, err := openICMP(server)
	if err != nil {
		res.Verdict, res.Error = "error", err.Error()
		return res
	}
	defer conn.Close()

	type sentInfo struct {
		at   time.Time
		poll bool
	}
	var mu sync.Mutex
	sent := map[uint16]sentInfo{}
	seen := map[uint16]bool{}
	var rtts []float64
	done := make(chan struct{})

	go func() {
		buf := make([]byte, 65535)
		for {
			select {
			case <-done:
				return
			default:
			}
			n, err := conn.Recv(buf)
			if err != nil {
				continue
			}
			r, ok := parseReply(buf[:n])
			if !ok || r.id != probeID {
				continue
			}
			mu.Lock()
			s, known := sent[r.seq]
			if known && !(seen[r.seq] && !s.poll) {
				switch {
				case !s.poll:
					seen[r.seq] = true
					res.PingReplies++
					rtts = append(rtts, float64(time.Since(s.at).Microseconds())/1000)
				case bytes.Equal(r.payload, pollPayloadWithSeq(r.seq)):
					res.KernelReplies++
				case bytes.HasPrefix(r.payload, magic):
					if !seen[r.seq] {
						seen[r.seq] = true
						res.RelayReplies++
					}
				}
			}
			mu.Unlock()
		}
	}()

	var seq uint16 = uint16(time.Now().UnixNano())
	for i := 0; i < count; i++ {
		for _, poll := range []bool{false, true} {
			seq++
			var payload []byte
			if poll {
				payload = pollPayloadWithSeq(seq)
			} else {
				payload = []byte("SONAR-PING-" + fmt.Sprint(seq))
			}
			mu.Lock()
			sent[seq] = sentInfo{time.Now(), poll}
			mu.Unlock()
			if err := conn.Send(echoRequest(probeID, seq, payload)); err != nil {
				mu.Lock()
				delete(sent, seq)
				mu.Unlock()
				if res.Error == "" {
					res.Error = err.Error()
				}
				continue
			}
			if poll {
				res.PollSent++
			} else {
				res.PingSent++
			}
		}
		time.Sleep(interval)
	}
	time.Sleep(wait)
	close(done)
	mu.Lock()
	defer mu.Unlock()

	if len(rtts) > 0 {
		sort.Float64s(rtts)
		res.RTTMs = rtts[len(rtts)/2]
	}
	if res.PollSent > 0 {
		res.LossPct = 100 * (1 - float64(res.RelayReplies)/float64(res.PollSent))
	}
	switch {
	case res.PingSent == 0 && res.PollSent == 0:
		res.Verdict = "error"
	case res.RelayReplies > 0 && res.KernelReplies > 0:
		res.Verdict = "relay+kernel"
	case res.RelayReplies > 0:
		res.Verdict = "relay"
	case res.KernelReplies > 0 || res.PingReplies > 0:
		res.Verdict = "kernel-only"
	default:
		res.Verdict = "silent"
	}
	return res
}

// pollPayloadWithSeq is a 64-byte poll whose padding carries the sequence number, so a kernel echo can be told
// apart from the relay's 3-byte "RT" 0x00 reply. The relay ignores the padding.
func pollPayloadWithSeq(seq uint16) []byte {
	b := make([]byte, pad)
	copy(b, pollPayload)
	binary.BigEndian.PutUint16(b[8:], seq)
	return b
}

// DoctorResult: what this network lets through (wizard step 0).
type DoctorResult struct {
	ICMP      bool    `json:"icmp"`
	ICMPHost  string  `json:"icmpHost,omitempty"`
	ICMPRTTMs float64 `json:"icmpRttMs,omitempty"`
	UDP       bool    `json:"udp"`
	UDPHost   string  `json:"udpHost,omitempty"`
	UDPRTTMs  float64 `json:"udpRttMs,omitempty"`
	Error     string  `json:"error,omitempty"`
}

func runDoctor(args []string) error {
	fs := flag.NewFlagSet("doctor", flag.ExitOnError)
	icmpHosts := fs.String("icmp", "1.1.1.1,8.8.8.8,9.9.9.9", "hosts to ping")
	dnsHosts := fs.String("dns", "1.1.1.1:53,8.8.8.8:53,9.9.9.9:53", "UDP DNS servers to query")
	_ = fs.Parse(args)
	var res DoctorResult
	for _, h := range strings.Split(*icmpHosts, ",") {
		p := probe(strings.TrimSpace(h), 4, 50*time.Millisecond, 800*time.Millisecond)
		if p.Error != "" && res.Error == "" {
			res.Error = p.Error
		}
		if p.PingReplies > 0 {
			res.ICMP, res.ICMPHost, res.ICMPRTTMs = true, h, p.RTTMs
			break
		}
	}
	for _, h := range strings.Split(*dnsHosts, ",") {
		if rtt, ok := udpDNS(strings.TrimSpace(h)); ok {
			res.UDP, res.UDPHost, res.UDPRTTMs = true, h, rtt
			break
		}
	}
	b, _ := json.Marshal(res)
	fmt.Println(string(b))
	return nil
}

// udpDNS sends a plain DNS query for example.com (type A) and waits for any answer with the same id.
func udpDNS(addr string) (float64, bool) {
	c, err := net.DialTimeout("udp4", addr, 2*time.Second)
	if err != nil {
		return 0, false
	}
	defer c.Close()
	q := []byte{0x53, 0x4f, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
		7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1}
	start := time.Now()
	for try := 0; try < 2; try++ {
		_ = c.SetDeadline(time.Now().Add(1500 * time.Millisecond))
		if _, err := c.Write(q); err != nil {
			return 0, false
		}
		buf := make([]byte, 1500)
		n, err := c.Read(buf)
		if err == nil && n >= 2 && buf[0] == 0x53 && buf[1] == 0x4f {
			return float64(time.Since(start).Microseconds()) / 1000, true
		}
	}
	return 0, false
}
