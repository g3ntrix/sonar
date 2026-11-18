package main

import (
	"errors"
	"flag"
	"strconv"
	"syscall"
	"time"
)

// guard kills the given child PIDs when the parent (the Sonar app) dies, so a crash never leaves Xray or the
// relay running. It exits on its own once all children are gone.
func runGuard(args []string) error {
	fs := flag.NewFlagSet("guard", flag.ExitOnError)
	parent := fs.Int("parent-pid", 0, "the app's PID")
	_ = fs.Parse(args)
	if *parent <= 0 || fs.NArg() == 0 {
		return errors.New("usage: watch --parent-pid N PID [PID...]")
	}
	var kids []int
	for _, a := range fs.Args() {
		pid, err := strconv.Atoi(a)
		if err != nil || pid <= 1 {
			return errors.New("bad pid: " + a)
		}
		kids = append(kids, pid)
	}
	for {
		time.Sleep(time.Second)
		anyAlive := false
		for _, k := range kids {
			if alive(k) {
				anyAlive = true
			}
		}
		if !anyAlive {
			return nil
		}
		if !alive(*parent) {
			for _, k := range kids {
				_ = syscall.Kill(k, syscall.SIGTERM)
			}
			time.Sleep(2 * time.Second)
			for _, k := range kids {
				if alive(k) {
					_ = syscall.Kill(k, syscall.SIGKILL)
				}
			}
			return nil
		}
	}
}
