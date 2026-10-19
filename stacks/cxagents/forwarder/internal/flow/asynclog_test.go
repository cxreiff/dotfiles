package flow

import (
	"context"
	"sync"
	"testing"
	"time"
)

// Decide runs inside tsnet's callback with its mutex held, so a stalled log
// writer must never block a rejection.
func TestAsyncLogNeverBlocksWhenWriterStalls(t *testing.T) {
	gate := make(chan struct{})
	var once sync.Once
	release := func() { once.Do(func() { close(gate) }) }
	t.Cleanup(release)

	reports := make(chan uint64, 16)
	a := NewAsyncLog(4, 10*time.Millisecond,
		func(Flow, string) { <-gate },
		func(n uint64) { reports <- n })
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go a.Run(ctx)

	start := time.Now()
	for i := 0; i < 10000; i++ {
		a.Log(Flow{Port: 3050}, "rst-deny")
	}
	if d := time.Since(start); d > time.Second {
		t.Fatalf("10000 Log calls took %v with a stalled writer; want non-blocking", d)
	}

	release()
	select {
	case n := <-reports:
		if n == 0 {
			t.Fatal("reported 0 dropped lines")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no dropped-count report after the writer resumed")
	}
}

func TestAsyncLogEmitsQueuedLinesInOrder(t *testing.T) {
	got := make(chan string, 8)
	a := NewAsyncLog(8, time.Minute,
		func(_ Flow, outcome string) { got <- outcome },
		func(uint64) {})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go a.Run(ctx)

	a.Log(Flow{}, "rst-noroute")
	a.Log(Flow{}, "rst-cap")
	for _, want := range []string{"rst-noroute", "rst-cap"} {
		select {
		case o := <-got:
			if o != want {
				t.Fatalf("emitted %q, want %q", o, want)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("line %q was never emitted", want)
		}
	}
}
