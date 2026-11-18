#!/usr/bin/env python3
"""ICMP-echo transport (client side) for networks that block UDP and throttle TCP flows.

Local UDP datagrams (e.g. Hysteria2 client) -> 127.0.0.1:LOCAL -> ICMP echo requests -> SERVER.
Server answers each request with one queued datagram (or an empty reply), so the client polls.
No root needed on macOS (unprivileged ICMP datagram socket).

usage: icmp_client.py SERVER_IP LOCAL_PORT [MAX_POLLS_PER_SEC=2500]
"""
import select
import socket
import struct
import sys
import time

SERVER = sys.argv[1]
LOCAL = int(sys.argv[2])
CAP = float(sys.argv[3]) if len(sys.argv) > 3 else 2500.0
DUP = int(sys.argv[4]) if len(sys.argv) > 4 else 2  # send each datagram this many times (masks ICMP loss)
MAGIC = b"RT"
IDENT = 0x5254
PAD = 64

L = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
L.bind(("127.0.0.1", LOCAL))
L.setblocking(False)
L.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
I = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP)
I.setblocking(False)
I.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
I.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)

seq = 0
caddr = None


def cksum(b):
    if len(b) % 2:
        b += b"\0"
    s = sum(struct.unpack("!%dH" % (len(b) // 2), b))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


def send(payload):
    global seq
    seq = (seq + 1) & 0xFFFF
    h = struct.pack("!BBHHH", 8, 0, 0, IDENT, seq)
    c = cksum(h + payload)
    try:
        I.sendto(struct.pack("!BBHHH", 8, 0, c, IDENT, seq) + payload, (SERVER, 0))
    except (BlockingIOError, OSError):
        pass


rate = 100.0
ema = 0.0
next_poll = time.time()
win_start = time.time()
win_data = win_total = 0
POLL = MAGIC + b"\x00" + b"\0" * (PAD - 3)

while True:
    now = time.time()
    timeout = max(0.0, min(0.01, next_poll - now))
    r, _, _ = select.select([L, I], [], [], timeout)
    if L in r:
        for _ in range(128):
            try:
                d, a = L.recvfrom(65535)
            except BlockingIOError:
                break
            caddr = a
            for _ in range(DUP):
                send(MAGIC + b"\x01" + d)
            send(POLL)
    if I in r:
        for _ in range(256):
            try:
                d, _a = I.recvfrom(65535)
            except BlockingIOError:
                break
            except OSError:
                break
            ip = (d[0] & 15) * 4
            if len(d) < ip + 8 or d[ip] != 0:
                continue
            p = d[ip + 8:]
            if p[:2] != MAGIC:
                continue
            win_total += 1
            if p[2:3] == b"\x01" and len(p) > 3:
                win_data += 1
                if caddr:
                    try:
                        L.sendto(p[3:], caddr)
                    except Exception:
                        pass
    now = time.time()
    if now - win_start >= 0.05:
        inst = win_data / (now - win_start)  # data replies per second in this window
        ema = ema * 0.7 + inst * 0.3
        rate = min(CAP, max(100.0, 1.5 * ema + 100.0))
        win_start = now
        win_data = win_total = 0
    # paced polls
    n = 0
    while next_poll <= now and n < 64:
        send(POLL)
        next_poll += 1.0 / rate
        n += 1
    if next_poll < now - 0.1:
        next_poll = now
