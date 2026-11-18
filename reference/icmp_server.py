#!/usr/bin/env python3
"""ICMP-echo transport (server side). Run as root. Needs: sysctl net.ipv4.icmp_echo_ignore_all=1

usage: icmp_server.py TARGET_UDP_PORT   (forwards to 127.0.0.1:PORT, e.g. a Hysteria2 server)
"""
import collections
import select
import socket
import struct
import sys

TARGET = ("127.0.0.1", int(sys.argv[1]))
MAGIC = b"RT"
MAXQ = 150
DUP = int(sys.argv[2]) if len(sys.argv) > 2 else 2

R = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
R.setblocking(False)
R.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
R.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
U = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
U.bind(("127.0.0.1", 0))
U.setblocking(False)
U.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
q = collections.deque()


def cksum(b):
    if len(b) % 2:
        b += b"\0"
    s = sum(struct.unpack("!%dH" % (len(b) // 2), b))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


def reply(addr, ident, seq, payload):
    h = struct.pack("!BBHHH", 0, 0, 0, ident, seq)
    c = cksum(h + payload)
    try:
        R.sendto(struct.pack("!BBHHH", 0, 0, c, ident, seq) + payload, (addr, 0))
    except OSError:
        pass


import time
pend = collections.deque()  # (time, addr, ident, seq) requests waiting for downlink data
HOLD = 0.25


def flush(now):
    while q and pend:
        _t, a, ident, seq = pend.popleft()
        d = MAGIC + b"\x01" + q.popleft()
        reply(a, ident, seq, d)
        for _ in range(DUP - 1):
            if len(pend) > 8:  # only duplicate when there is spare poll credit
                _t, a, ident, seq = pend.popleft()
                reply(a, ident, seq, d)
    while pend and (now - pend[0][0] > HOLD or len(pend) > 600):
        _t, a, ident, seq = pend.popleft()
        reply(a, ident, seq, MAGIC + b"\x00")


while True:
    r, _, _ = select.select([R, U], [], [], 0.02)
    now = time.time()
    if U in r:
        for _ in range(256):
            try:
                d, _a = U.recvfrom(65535)
            except BlockingIOError:
                break
            if len(q) < MAXQ:
                q.append(d)
    if R in r:
        for _ in range(256):
            try:
                d, a = R.recvfrom(65535)
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
                    U.sendto(p[3:], TARGET)
                except OSError:
                    pass
            pend.append((now, a[0], ident, seq))
    flush(now)
