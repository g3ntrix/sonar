package main

import (
	"encoding/binary"
	"errors"
	"net"
	"syscall"
	"time"
)

// Wire format shared with icmp_server.py. Do not change without changing the server.
const (
	ident    = 0x5254 // ICMP identifier of tunnel traffic ("RT")
	probeID  = 0x5350 // identifier used by probe/doctor, so their replies never mix with tunnel replies
	typeData = 0x01
	typePoll = 0x00
	pad      = 64 // client poll size
)

var magic = []byte("RT")

// pollPayload is the 64-byte empty poll: "RT" 0x00 + zero padding.
var pollPayload = func() []byte {
	b := make([]byte, pad)
	copy(b, magic)
	b[2] = typePoll
	return b
}()

func dataPayload(d []byte) []byte {
	b := make([]byte, 3+len(d))
	copy(b, magic)
	b[2] = typeData
	copy(b[3:], d)
	return b
}

func checksum(b []byte) uint16 {
	var s uint32
	for i := 0; i+1 < len(b); i += 2 {
		s += uint32(b[i])<<8 | uint32(b[i+1])
	}
	if len(b)%2 == 1 {
		s += uint32(b[len(b)-1]) << 8
	}
	s = (s >> 16) + (s & 0xFFFF)
	s += s >> 16
	return ^uint16(s)
}

// echoRequest builds an ICMP echo request (type 8) with a valid checksum.
func echoRequest(id, seq uint16, payload []byte) []byte {
	b := make([]byte, 8+len(payload))
	b[0] = 8
	binary.BigEndian.PutUint16(b[4:], id)
	binary.BigEndian.PutUint16(b[6:], seq)
	copy(b[8:], payload)
	binary.BigEndian.PutUint16(b[2:], checksum(b))
	return b
}

// reply is a parsed ICMP echo reply.
type reply struct {
	id, seq uint16
	payload []byte
}

// parseReply accepts a packet with or without a leading IPv4 header (macOS datagram ICMP sockets include it).
func parseReply(d []byte) (reply, bool) {
	if len(d) >= 20 && d[0]>>4 == 4 {
		ihl := int(d[0]&15) * 4
		if ihl < 20 || len(d) < ihl+8 {
			return reply{}, false
		}
		d = d[ihl:]
	}
	if len(d) < 8 || d[0] != 0 { // echo reply only
		return reply{}, false
	}
	return reply{binary.BigEndian.Uint16(d[4:]), binary.BigEndian.Uint16(d[6:]), d[8:]}, true
}

// icmpConn is the ICMP side of the relay. The real one is an unprivileged datagram socket; tests use a fake.
type icmpConn interface {
	Send(pkt []byte) error
	// Recv reads one packet. It returns errTimeout periodically so callers can notice shutdown.
	Recv(buf []byte) (int, error)
	Close() error
}

var errTimeout = errors.New("timeout")

type dgramICMP struct {
	fd   int
	addr syscall.SockaddrInet4
}

func openICMP(server string) (*dgramICMP, error) {
	ip := net.ParseIP(server).To4()
	if ip == nil {
		addrs, err := net.LookupIP(server)
		if err != nil {
			return nil, err
		}
		for _, a := range addrs {
			if ip = a.To4(); ip != nil {
				break
			}
		}
		if ip == nil {
			return nil, errors.New("no IPv4 address for " + server)
		}
	}
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, syscall.IPPROTO_ICMP)
	if err != nil {
		return nil, err
	}
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, 4<<20)
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, 4<<20)
	tv := syscall.NsecToTimeval(int64(200 * time.Millisecond))
	_ = syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
	c := &dgramICMP{fd: fd}
	copy(c.addr.Addr[:], ip)
	return c, nil
}

func (c *dgramICMP) Send(pkt []byte) error { return syscall.Sendto(c.fd, pkt, 0, &c.addr) }

func (c *dgramICMP) Recv(buf []byte) (int, error) {
	for {
		n, from, err := syscall.Recvfrom(c.fd, buf, 0)
		if err != nil {
			if err == syscall.EAGAIN || err == syscall.EWOULDBLOCK || err == syscall.EINTR {
				return 0, errTimeout
			}
			return 0, err
		}
		// Only accept replies from the server (other ICMP traffic on the Mac is delivered to this socket too).
		if sa, ok := from.(*syscall.SockaddrInet4); ok && sa.Addr != c.addr.Addr {
			continue
		}
		return n, nil
	}
}

func (c *dgramICMP) Close() error { return syscall.Close(c.fd) }
