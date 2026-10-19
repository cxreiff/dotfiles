package status

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// AC7.5: every HTTP probe takes a global dial slot, so the probes of all scans
// together never run more than DialSlots at once.
func TestProbesShareGlobalDialSlots(t *testing.T) {
	var open []uint16
	for p := uint16(20001); p <= 20008; p++ {
		open = append(open, p)
	}
	f := newFakeNet(open, nil)
	s, _ := newTestServer(t, "t1 20000-20009 -\n", fakeTargets{"t1": {addr("10.0.0.5")}}, f)
	s.DialSlots = 2

	var cur, peak, probes atomic.Int32
	s.HTTPProbe = func(context.Context, netip.AddrPort) bool {
		n := cur.Add(1)
		for {
			p := peak.Load()
			if n <= p || peak.CompareAndSwap(p, n) {
				break
			}
		}
		time.Sleep(30 * time.Millisecond)
		cur.Add(-1)
		probes.Add(1)
		return true
	}

	if rec := get(s, "10.0.0.5", "/status"); rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
	if n := probes.Load(); n != 8 {
		t.Fatalf("probes = %d, want 8 (one per open port)", n)
	}
	if p := peak.Load(); p > 2 {
		t.Fatalf("peak concurrent probes = %d, want at most DialSlots (2)", p)
	}
}

// AC7.5: when the scan limit is full, a caller whose target has a cached
// result (even a stale one) gets that result; 503 is only for no cached result.
func TestBusyScanLimitServesStaleCache(t *testing.T) {
	f := newFakeNet([]uint16{20001}, nil)
	targets := fakeTargets{"t1": {addr("10.0.0.5")}, "t2": {addr("10.0.0.6")}}
	s, clk := newTestServer(t, "t1 20000-20009 -\nt2 30000-30009 -\n", targets, f)
	s.MaxScans = 1
	s.DialTimeout = time.Minute

	if rec := get(s, "10.0.0.5", "/status"); rec.Code != http.StatusOK {
		t.Fatalf("priming scan: code = %d", rec.Code)
	}
	clk.Advance(2 * time.Minute) // t1's cached result is stale (CacheFor is 1 minute)

	gate := make(chan struct{})
	f.mu.Lock()
	f.gate = gate
	f.mu.Unlock()
	var once sync.Once
	release := func() { once.Do(func() { close(gate) }) }
	t.Cleanup(release)

	// t2's scan takes the only scan slot and blocks in Dial.
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- get(s, "10.0.0.6", "/status") }()
	deadline := time.Now().Add(5 * time.Second)
	for f.dialCount(30000) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("t2's scan never started")
		}
		time.Sleep(time.Millisecond)
	}

	rec := get(s, "10.0.0.5", "/status?format=json")
	if rec.Code != http.StatusOK {
		t.Fatalf("stale request while the scan limit is full: code = %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `"port":20001`) {
		t.Fatalf("stale body = %s, want t1's cached listing", rec.Body.String())
	}
	if n := f.dialCount(20001); n != 1 {
		t.Fatalf("stale request rescanned t1: dials = %d, want 1", n)
	}

	release()
	if first := <-done; first.Code != http.StatusOK {
		t.Fatalf("t2 caller: code = %d, want 200", first.Code)
	}
}
