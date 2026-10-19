// Package flow decides and serves inbound TCP flows. Decide runs inside tsnet's
// fallback callback (with tsnet's mutex held), so it does only in-memory work.
// Serve runs after the handshake, in its own goroutine, and does the dialing.
package flow

import (
	"net"
	"net/netip"
	"sync"
	"time"

	"tailnet-forwarder/internal/netcheck"
	"tailnet-forwarder/internal/routes"
)

// Resolver is the off-lock target address cache (see package resolve).
type Resolver interface {
	Get(name string) ([]netip.Addr, bool)
	Refresh(name string)
}

// Decider implements the tsnet fallback callback for every inbound TCP flow.
type Decider struct {
	Routes  *routes.Table
	Subnet  netip.Prefix
	Targets Resolver
	Caps    *Caps
	// Handle serves an accepted flow. It is started in its own goroutine and
	// must release the flow's slot when it finishes (Flow.Release).
	Handle func(f Flow)
	// Log records one line per rejected flow (accepted flows are logged by Handle).
	Log func(f Flow, outcome string)
	// OrphanAfter reclaims a cap slot whose handler tsnet never invoked.
	// Zero means 15 s.
	OrphanAfter time.Duration
}

// Flow is one accepted inbound connection and where it is headed.
type Flow struct {
	Conn    net.Conn
	Src     netip.AddrPort
	Port    uint16
	Target  string
	Addr    netip.AddrPort // target ip:port, validated inside Subnet
	Node    string         // source node name, filled in by Handler before logging
	release func()
}

// Release frees the flow's cap slot. It is safe to call more than once.
func (f Flow) Release() {
	if f.release != nil {
		f.release()
	}
}

// Decide is the tsnet fallback callback. Every rejection is (nil, true), which
// tsnet answers with a RST. An accepted flow gets a handler that returns
// immediately; the dial happens later, in Handle.
func (d *Decider) Decide(src, dst netip.AddrPort) (func(net.Conn), bool) {
	port := dst.Port()
	r, ok := d.Routes.Lookup(port)
	if !ok {
		d.log(Flow{Src: src, Port: port}, "rst-noroute")
		return nil, true
	}
	if !r.Allowed(port) {
		d.log(Flow{Src: src, Port: port, Target: r.Target}, "rst-deny")
		return nil, true
	}
	addrs, ok := d.Targets.Get(r.Target)
	if !ok || len(addrs) != 1 || !netcheck.Inside(d.Subnet, addrs[0]) {
		// Unresolved, ambiguous, or off-subnet: ask for a fresh lookup.
		d.Targets.Refresh(r.Target)
		d.log(Flow{Src: src, Port: port, Target: r.Target}, "rst-target")
		return nil, true
	}
	if !d.Caps.Acquire(port) {
		d.log(Flow{Src: src, Port: port, Target: r.Target}, "rst-cap")
		return nil, true
	}

	var once sync.Once
	release := func() { once.Do(func() { d.Caps.Release(port) }) }
	// tsnet may RST after we return (for example, the client vanishes
	// mid-handshake) without ever calling the handler. Reclaim the slot then.
	after := d.OrphanAfter
	if after <= 0 {
		after = 15 * time.Second
	}
	orphan := time.AfterFunc(after, release)

	f := Flow{
		Src:     src,
		Port:    port,
		Target:  r.Target,
		Addr:    netip.AddrPortFrom(addrs[0], port),
		release: release,
	}
	return func(c net.Conn) {
		if !orphan.Stop() {
			// The slot was already reclaimed; this late connection is dropped.
			c.Close()
			return
		}
		f.Conn = c
		go d.Handle(f)
	}, true
}

func (d *Decider) log(f Flow, outcome string) {
	if d.Log != nil {
		d.Log(f, outcome)
	}
}
