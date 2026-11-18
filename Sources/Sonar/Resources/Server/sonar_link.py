#!/usr/bin/env python3
# version: 1
"""Sonar server helper. Runs as root. Managed by the Sonar app; do not run by hand.

    sonar_link.py TARGET_PORT [N]
    sonar_link.py --version
"""
import collections
import select
import socket
import struct
import sys
import time

VERSION = 1
MAGIC = b"RT"
MAXQ = 150      # downlink queue cap (packets); larger queues caused multi-second delays under load
HOLD = 0.25     # seconds a poll may wait for downlink data
MAXPEND = 600   # pending polls cap


def cksum(b):
    if len(b) % 2:
        b += b"\0"
    s = sum(struct.unpack("!%dH" % (len(b) // 2), b))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--version":
        print(VERSION)
        return
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    target = ("127.0.0.1", int(sys.argv[1]))
    dup = int(sys.argv[2]) if len(sys.argv) > 2 else 1

    raw = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
    raw.setblocking(False)
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", 0))
    udp.setblocking(False)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)

    q = collections.deque()      # downlink datagrams waiting for a poll
    pend = collections.deque()   # (time, addr, ident, seq) requests waiting for downlink data

    def reply(addr, ident, seq, payload):
        h = struct.pack("!BBHHH", 0, 0, 0, ident, seq)
        c = cksum(h + payload)
        try:
            raw.sendto(struct.pack("!BBHHH", 0, 0, c, ident, seq) + payload, (addr, 0))
        except OSError:
            pass

    def flush(now):
        while q and pend:
            _t, a, ident, seq = pend.popleft()
            d = MAGIC + b"\x01" + q.popleft()
            reply(a, ident, seq, d)
            for _ in range(dup - 1):
                if len(pend) > 8:  # duplicate only when there is spare poll credit
                    _t, a, ident, seq = pend.popleft()
                    reply(a, ident, seq, d)
        while pend and (now - pend[0][0] > HOLD or len(pend) > MAXPEND):
            _t, a, ident, seq = pend.popleft()
            reply(a, ident, seq, MAGIC + b"\x00")

    while True:
        r, _, _ = select.select([raw, udp], [], [], 0.02)
        now = time.time()
        if udp in r:
            for _ in range(256):
                try:
                    d, _a = udp.recvfrom(65535)
                except BlockingIOError:
                    break
                if len(q) < MAXQ:
                    q.append(d)
        if raw in r:
            for _ in range(256):
                try:
                    d, a = raw.recvfrom(65535)
                except (BlockingIOError, OSError):
                    break
                ip = (d[0] & 15) * 4
                if len(d) < ip + 8 or d[ip] != 8:
                    continue
                ident, seq = struct.unpack("!HH", d[ip + 4:ip + 8])
                p = d[ip + 8:]
                if p[:2] != MAGIC:
                    reply(a[0], ident, seq, p)  # behave like a normal ping responder
                    continue
                if p[2:3] == b"\x01" and len(p) > 3:
                    try:
                        udp.sendto(p[3:], target)
                    except OSError:
                        pass
                pend.append((now, a[0], ident, seq))
        flush(now)


if __name__ == "__main__":
    main()
