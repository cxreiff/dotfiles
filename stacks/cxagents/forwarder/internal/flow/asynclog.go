package flow

import (
	"context"
	"sync/atomic"
	"time"
)

// AsyncLog moves rejection lines off the caller's path. Log never blocks: when
// the buffer is full the line is counted as dropped instead. Run writes the
// queued lines and, every interval, reports how many were dropped since the
// previous report.
type AsyncLog struct {
	entries  chan logEntry
	dropped  atomic.Uint64
	emit     func(f Flow, outcome string)
	report   func(dropped uint64)
	interval time.Duration
}

type logEntry struct {
	f       Flow
	outcome string
}

// NewAsyncLog returns a log with room for size queued lines. A non-positive
// interval means one minute.
func NewAsyncLog(size int, interval time.Duration, emit func(f Flow, outcome string), report func(dropped uint64)) *AsyncLog {
	if size < 1 {
		size = 1
	}
	if interval <= 0 {
		interval = time.Minute
	}
	return &AsyncLog{
		entries:  make(chan logEntry, size),
		emit:     emit,
		report:   report,
		interval: interval,
	}
}

// Log queues one line for Run. It never blocks; a full buffer drops the line.
func (a *AsyncLog) Log(f Flow, outcome string) {
	select {
	case a.entries <- logEntry{f: f, outcome: outcome}:
	default:
		a.dropped.Add(1)
	}
}

// Run emits queued lines until ctx ends.
func (a *AsyncLog) Run(ctx context.Context) {
	t := time.NewTicker(a.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case e := <-a.entries:
			a.emit(e.f, e.outcome)
		case <-t.C:
			if n := a.dropped.Swap(0); n > 0 {
				a.report(n)
			}
		}
	}
}
