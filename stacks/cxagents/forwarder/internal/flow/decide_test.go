package flow

import (
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"tailnet-forwarder/internal/routes"
)

type fakeTargets struct {
	mu        sync.Mutex
	m         map[string][]netip.Addr
	refreshed []string
}

func (f *fakeTargets) Get(name string) ([]netip.Addr, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	a, ok := f.m[name]
	return a, ok
}

func (f *fakeTargets) Refresh(name string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.refreshed = append(f.refreshed, name)
}

func (f *fakeTargets) refreshCount(name string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, r := range f.refreshed {
		if r == name {
			n++
		}
	}
	return n
}

type outcomeLog struct {
	mu  sync.Mutex
	got []string
}

func (o *outcomeLog) add(f Flow, outcome string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.got = append(o.got, outcome)
}

func (o *outcomeLog) last() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	if len(o.got) == 0 {
		return ""
	}
	return o.got[len(o.got)-1]
}

const testRoutes = `
# shell is reachable on 3000-3199 except 3100
shell  3000-3199  3100
vite   5173-5173  -
web    8000-8000  -
`

var testSubnet = netip.MustParsePrefix("172.30.0.0/16")

func newTestDecider(t *testing.T, targets *fakeTargets, caps *Caps, orphan time.Duration, handle func(Flow)) (*Decider, *outcomeLog) {
	t.Helper()
	rt, err := routes.Parse(strings.NewReader(testRoutes))
	if err != nil {
		t.Fatal(err)
	}
	out := &outcomeLog{}
	if handle == nil {
		handle = func(Flow) {}
	}
	d := &Decider{
		Routes:      rt,
		Subnet:      testSubnet,
		Targets:     targets,
		Caps:        caps,
		Handle:      handle,
		Log:         out.add,
		OrphanAfter: orphan,
	}
	return d, out
}

func goodTargets() *fakeTargets {
	return &fakeTargets{m: map[string][]netip.Addr{
		"shell": {netip.MustParseAddr("172.30.0.5")},
		"vite":  {netip.MustParseAddr("172.30.0.6")},
		"web":   {netip.MustParseAddr("172.30.0.7")},
	}}
}

var (
	testSrc = netip.MustParseAddrPort("100.64.0.9:40000")
	testDst = netip.MustParseAddr("172.30.0.2")
)

func dst(port uint16) netip.AddrPort { return netip.AddrPortFrom(testDst, port) }

func TestDecideRejections(t *testing.T) {
	cases := []struct {
		name    string
		targets *fakeTargets
		port    uint16
		outcome string
	}{
		{"no route below every range", goodTargets(), 1000, "rst-noroute"},
		{"no route above every range", goodTargets(), 60000, "rst-noroute"},
		{"denied port inside a range", goodTargets(), 3100, "rst-deny"},
		{"target resolves outside the subnet (AC6.11)", &fakeTargets{m: map[string][]netip.Addr{
			"shell": {netip.MustParseAddr("172.19.0.5")},
		}}, 3050, "rst-target"},
		{"target unresolved", &fakeTargets{m: map[string][]netip.Addr{}}, 3050, "rst-target"},
		{"target resolves to two addresses", &fakeTargets{m: map[string][]netip.Addr{
			"shell": {netip.MustParseAddr("172.30.0.5"), netip.MustParseAddr("172.30.0.8")},
		}}, 3050, "rst-target"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			caps := NewCaps(10, 10)
			d, out := newTestDecider(t, c.targets, caps, time.Hour, nil)
			h, ok := d.Decide(testSrc, dst(c.port))
			if h != nil || !ok {
				t.Fatalf("Decide = (%v, %v), want (nil, true) RST", h != nil, ok)
			}
			if out.last() != c.outcome {
				t.Fatalf("outcome = %q, want %q", out.last(), c.outcome)
			}
		})
	}
}

func TestDecideUnresolvedTargetTriggersRefresh(t *testing.T) {
	targets := &fakeTargets{m: map[string][]netip.Addr{
		"shell": {netip.MustParseAddr("172.19.0.5")},
	}}
	d, _ := newTestDecider(t, targets, NewCaps(10, 10), time.Hour, nil)
	d.Decide(testSrc, dst(3050))
	if n := targets.refreshCount("shell"); n != 1 {
		t.Fatalf("Refresh(shell) calls = %d, want 1", n)
	}
}

func TestDecideAcceptsAndHandlerDialsTargetAddress(t *testing.T) {
	handled := make(chan Flow, 1)
	d, _ := newTestDecider(t, goodTargets(), NewCaps(10, 10), time.Hour, func(f Flow) { handled <- f })
	h, ok := d.Decide(testSrc, dst(3050))
	if h == nil || !ok {
		t.Fatalf("Decide = (nil? %v, %v), want accepted handler", h == nil, ok)
	}
	client, server := net.Pipe()
	t.Cleanup(func() { client.Close() })
	h(server) // must return immediately; Handle runs in its own goroutine

	select {
	case f := <-handled:
		if f.Addr != netip.MustParseAddrPort("172.30.0.5:3050") {
			t.Fatalf("Flow.Addr = %v, want 172.30.0.5:3050", f.Addr)
		}
		if f.Target != "shell" || f.Port != 3050 || f.Src != testSrc {
			t.Fatalf("Flow = %+v", f)
		}
		if f.Conn != server {
			t.Fatal("Flow.Conn is not the accepted connection")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Handle was not called")
	}
}

func TestDecideCapsRejectAndRecover(t *testing.T) {
	caps := NewCaps(2, 3)
	d, out := newTestDecider(t, goodTargets(), caps, time.Hour, nil)
	accept := func(port uint16) bool {
		t.Helper()
		h, ok := d.Decide(testSrc, dst(port))
		if !ok {
			t.Fatal("Decide must always report intercept")
		}
		return h != nil
	}
	if !accept(5173) || !accept(5173) {
		t.Fatal("first two flows on 5173 should be accepted")
	}
	if accept(5173) || out.last() != "rst-cap" {
		t.Fatalf("third flow on 5173 should be rst-cap, last outcome %q", out.last())
	}
	if !accept(8000) {
		t.Fatal("flow on 8000 should be accepted (total 3)")
	}
	if accept(8000) || out.last() != "rst-cap" {
		t.Fatal("fourth flow anywhere should be rst-cap")
	}
	caps.Release(5173)
	if !accept(5173) {
		t.Fatal("after Release a flow on 5173 should be accepted again")
	}
}

func TestDecideOrphanedFlowReclaimsSlot(t *testing.T) {
	const orphanAfter = 50 * time.Millisecond
	var handled atomic.Int32
	caps := NewCaps(1, 1)
	d, _ := newTestDecider(t, goodTargets(), caps, orphanAfter, func(Flow) { handled.Add(1) })

	stale, ok := d.Decide(testSrc, dst(5173))
	if stale == nil || !ok {
		t.Fatal("first flow should be accepted")
	}
	// The handler is never invoked (tsnet RST'd the client). The slot must
	// come back on its own, so a later flow is accepted again.
	deadline := time.Now().Add(5 * time.Second)
	var fresh func(net.Conn)
	for fresh == nil {
		if time.Now().After(deadline) {
			t.Fatal("orphaned slot was never reclaimed")
		}
		fresh, _ = d.Decide(testSrc, dst(5173))
		if fresh == nil {
			time.Sleep(orphanAfter / 5)
		}
	}

	// Invoking the stale handler now must drop its connection and not run Handle.
	client, server := net.Pipe()
	t.Cleanup(func() { client.Close() })
	stale(server)
	if _, err := client.Read(make([]byte, 1)); err == nil {
		t.Fatal("stale connection should be closed")
	}
	if n := handled.Load(); n != 0 {
		t.Fatalf("Handle ran %d times for the stale flow", n)
	}
}

func TestDecideZeroOrphanAfterDoesNotFireImmediately(t *testing.T) {
	handled := make(chan Flow, 1)
	caps := NewCaps(1, 1)
	d, _ := newTestDecider(t, goodTargets(), caps, 0, func(f Flow) { handled <- f })
	h, _ := d.Decide(testSrc, dst(5173))
	if h == nil {
		t.Fatal("flow should be accepted")
	}
	client, server := net.Pipe()
	t.Cleanup(func() { client.Close() })
	h(server)
	select {
	case <-handled:
	case <-time.After(5 * time.Second):
		t.Fatal("zero OrphanAfter must still hand the flow to Handle")
	}
}
