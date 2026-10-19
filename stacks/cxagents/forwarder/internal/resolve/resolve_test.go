package resolve

import (
	"context"
	"errors"
	"net/netip"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeLookup returns scripted results in order (the last one repeats) and
// counts calls per host.
type fakeLookup struct {
	mu    sync.Mutex
	steps []result
	calls map[string]int
}

type result struct {
	addrs []netip.Addr
	err   error
}

func (f *fakeLookup) lookup(_ context.Context, host string) ([]netip.Addr, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.calls == nil {
		f.calls = map[string]int{}
	}
	n := f.calls[host]
	f.calls[host]++
	if n >= len(f.steps) {
		n = len(f.steps) - 1
	}
	return f.steps[n].addrs, f.steps[n].err
}

func (f *fakeLookup) count(host string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[host]
}

func addrs(s ...string) []netip.Addr {
	var out []netip.Addr
	for _, x := range s {
		out = append(out, netip.MustParseAddr(x))
	}
	return out
}

// waitFor polls cond until it holds or the deadline passes. Used only where a
// goroutine must reach a state; the deadline is generous.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(time.Millisecond)
	}
}

func runCache(t *testing.T, c *Cache) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { c.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
}

func TestGetBeforeFirstRefreshIsFalse(t *testing.T) {
	f := &fakeLookup{steps: []result{{addrs: addrs("172.30.0.5")}}}
	c := New(f.lookup, []string{"connectome-shell"}, time.Hour)
	if _, ok := c.Get("connectome-shell"); ok {
		t.Fatal("Get before any refresh must report not ok")
	}
}

func TestRunResolvesNamesAndNormalises(t *testing.T) {
	f := &fakeLookup{steps: []result{{addrs: addrs("172.30.0.9", "172.30.0.5", "172.30.0.9", "2001:db8::1")}}}
	c := New(f.lookup, []string{"t1"}, time.Hour)
	runCache(t, c)
	waitFor(t, "first refresh", func() bool { _, ok := c.Get("t1"); return ok })
	got, _ := c.Get("t1")
	want := addrs("172.30.0.5", "172.30.0.9")
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("Get = %v, want %v (IPv4 only, deduplicated, sorted)", got, want)
	}
}

func TestLookupErrorKeepsPreviousGoodResult(t *testing.T) {
	f := &fakeLookup{steps: []result{
		{addrs: addrs("172.30.0.5")},
		{err: errors.New("servfail")},
	}}
	c := New(f.lookup, []string{"t1"}, time.Hour)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c.refreshAll(ctx) // first: success
	c.refreshAll(ctx) // second: error
	got, ok := c.Get("t1")
	if !ok || len(got) != 1 || got[0] != netip.MustParseAddr("172.30.0.5") {
		t.Fatalf("after lookup error Get = %v, %v; want previous result kept", got, ok)
	}
	if f.count("t1") != 2 {
		t.Fatalf("lookup calls = %d, want 2", f.count("t1"))
	}
}

func TestRefreshCoalescesBursts(t *testing.T) {
	// Cache with no configured names: only Refresh drives lookups.
	started := make(chan struct{}, 4)
	gate := make(chan struct{})
	done := make(chan struct{}, 4)
	var calls atomic.Int32
	lookup := func(_ context.Context, host string) ([]netip.Addr, error) {
		n := calls.Add(1)
		started <- struct{}{}
		if n == 1 {
			<-gate // hold the first refresh so a second burst arrives while it runs
		}
		done <- struct{}{}
		return addrs("172.30.0.5"), nil
	}
	c := New(lookup, nil, time.Hour)

	// Before Run: ten calls queue exactly one refresh.
	for i := 0; i < 10; i++ {
		c.Refresh("t1")
	}
	runCache(t, c)
	<-started // first lookup in flight, blocked on gate

	// Queue was cleared before the lookup began, so one more refresh is
	// queued and the other nine coalesce into it.
	for i := 0; i < 10; i++ {
		c.Refresh("t1")
	}
	close(gate)
	<-done
	<-done
	if n := calls.Load(); n != 2 {
		t.Fatalf("lookup calls = %d, want 2 (one per coalesced burst)", n)
	}
}

func TestRefreshOneIsNotBlocking(t *testing.T) {
	c := New(func(context.Context, string) ([]netip.Addr, error) { return nil, nil }, nil, time.Hour)
	finished := make(chan struct{})
	go func() {
		for i := 0; i < 1000; i++ {
			c.Refresh("t1") // Run is not started; must never block
		}
		close(finished)
	}()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("Refresh blocked without a running Cache")
	}
}
