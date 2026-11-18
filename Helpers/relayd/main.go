// relayd: Sonar's local helper.
//
//	relayd icmp   --server IP --listen 127.0.0.1:18096 [--cap 1800] [--dup 1] [--parent-pid N]
//	relayd probe  --server IP [--count 20] [--interval 20ms] [--wait 1.5s]
//	relayd doctor [--icmp 1.1.1.1,8.8.8.8] [--dns 1.1.1.1:53,8.8.8.8:53]
//	relayd guard  --parent-pid N PID [PID...]
//	relayd version
//
// icmp is a straight port of icmp_client.py: every datagram the local Hysteria2 client sends to the listen address
// becomes an ICMP echo request to the server (payload "RT" + 0x01 + data). Because the server can only answer, the
// helper also keeps small "poll" echo requests flowing; the server holds each poll until it has a downlink datagram
// for it. The poll rate adapts: clamp(1.5 * ema(data replies/s) + 100, 100, cap).
//
// It uses an unprivileged ICMP datagram socket (SOCK_DGRAM, IPPROTO_ICMP), so no root is needed on macOS.
package main

import (
	"fmt"
	"os"
)

const version = "1.0.0"

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "run":
		err = runICMP(os.Args[2:])
	case "check":
		err = runProbe(os.Args[2:])
	case "net":
		err = runDoctor(os.Args[2:])
	case "watch":
		err = runGuard(os.Args[2:])
	case "version", "--version", "-v":
		fmt.Println(version)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "err:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: run|check|net|watch|version [flags]")
	os.Exit(2)
}
