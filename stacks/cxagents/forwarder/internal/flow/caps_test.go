package flow

import (
	"testing"
	"time"
)

func TestCapsPerPortAndTotal(t *testing.T) {
	c := NewCaps(2, 3)
	expect := func(port uint16, want bool) {
		t.Helper()
		if got := c.Acquire(port); got != want {
			t.Fatalf("Acquire(%d) = %v, want %v", port, got, want)
		}
	}
	expect(5173, true)
	expect(5173, true)
	expect(5173, false) // per-port cap of 2
	expect(8000, true)  // total is now 3
	expect(8000, false) // total cap of 3 reached, any port
	c.Release(5173)
	expect(8000, true) // one slot freed globally and on 5173
	expect(8001, false)
}

func TestCapsReleaseOfUnheldPortIsHarmless(t *testing.T) {
	c := NewCaps(1, 1)
	c.Release(9999) // never acquired: must not drive counts negative
	if !c.Acquire(9999) {
		t.Fatal("Acquire after spurious Release should succeed")
	}
	if c.Acquire(9998) {
		t.Fatal("total cap of 1 must hold after spurious Release")
	}
}

func TestCapsAcquireNeverBlocks(t *testing.T) {
	c := NewCaps(1, 1)
	c.Acquire(5173) // fill the caps
	done := make(chan bool, 1)
	go func() { done <- c.Acquire(5173) }()
	select {
	case got := <-done:
		if got {
			t.Fatal("Acquire on full caps returned true")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Acquire blocked on full caps")
	}
}
