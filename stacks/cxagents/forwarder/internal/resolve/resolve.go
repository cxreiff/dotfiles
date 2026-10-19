// Package resolve keeps an off-lock cache of route target addresses. The
// tsnet fallback callback reads it (cheap, lock-free); DNS lookups happen only
// in the background refresher.
package resolve

import (
	"context"
	"net"
	"net/netip"
	"slices"
	"sync"
	"sync/atomic"
	"time"
)

// Lookup resolves a host name to addresses.
type Lookup func(ctx context.Context, host string) ([]netip.Addr, error)

// DefaultLookup resolves IPv4 addresses with a 2 s timeout per name.
func DefaultLookup(ctx context.Context, host string) ([]netip.Addr, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	return net.DefaultResolver.LookupNetIP(ctx, "ip4", host)
}

const kickCap = 64

// Cache holds the last successful IPv4 result per name.
type Cache struct {
	lookup Lookup
	names  []string
	every  time.Duration

	cur atomic.Pointer[map[string][]netip.Addr] // copy-on-write, read lock-free

	kick   chan string
	mu     sync.Mutex
	queued map[string]bool // names with a refresh waiting or running
}

// New builds a cache over names, refreshed every `every` by Run. A nil lookup
// means DefaultLookup.
func New(lookup Lookup, names []string, every time.Duration) *Cache {
	if lookup == nil {
		lookup = DefaultLookup
	}
	c := &Cache{
		lookup: lookup,
		names:  names,
		every:  every,
		kick:   make(chan string, kickCap),
		queued: map[string]bool{},
	}
	empty := map[string][]netip.Addr{}
	c.cur.Store(&empty)
	return c
}

// Run refreshes every name immediately, then every interval, and serves
// Refresh requests, until ctx ends. It must run in one goroutine.
func (c *Cache) Run(ctx context.Context) {
	c.refreshAll(ctx)
	t := time.NewTicker(c.every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			c.refreshAll(ctx)
		case name := <-c.kick:
			c.refreshOne(ctx, name)
		}
	}
}

// Refresh asks for an asynchronous re-resolution of name. It never blocks;
// requests for a name already queued are coalesced.
func (c *Cache) Refresh(name string) {
	c.mu.Lock()
	if c.queued[name] {
		c.mu.Unlock()
		return
	}
	c.queued[name] = true
	c.mu.Unlock()
	select {
	case c.kick <- name:
	default:
		c.mu.Lock()
		delete(c.queued, name)
		c.mu.Unlock()
	}
}

// Get returns the last successful IPv4 result for name. The returned slice
// is shared and must not be modified.
func (c *Cache) Get(name string) ([]netip.Addr, bool) {
	addrs, ok := (*c.cur.Load())[name]
	return addrs, ok
}

func (c *Cache) refreshAll(ctx context.Context) {
	for _, n := range c.names {
		if ctx.Err() != nil {
			return
		}
		c.refreshOne(ctx, n)
	}
}

func (c *Cache) refreshOne(ctx context.Context, name string) {
	// Clear the queued flag first so a Refresh arriving during the lookup
	// queues a fresh one instead of being lost.
	c.mu.Lock()
	delete(c.queued, name)
	c.mu.Unlock()

	addrs, err := c.lookup(ctx, name)
	if err != nil {
		return // keep the previous good result
	}
	c.store(name, filterIPv4(addrs))
}

// store publishes a new snapshot. Only Run's goroutine writes, so the
// load-copy-store sequence cannot race with another writer.
func (c *Cache) store(name string, addrs []netip.Addr) {
	old := *c.cur.Load()
	next := make(map[string][]netip.Addr, len(old)+1)
	for k, v := range old {
		next[k] = v
	}
	next[name] = addrs
	c.cur.Store(&next)
}

func filterIPv4(in []netip.Addr) []netip.Addr {
	out := make([]netip.Addr, 0, len(in))
	for _, a := range in {
		a = a.Unmap()
		if a.Is4() && !slices.Contains(out, a) {
			out = append(out, a)
		}
	}
	slices.SortFunc(out, func(a, b netip.Addr) int { return a.Compare(b) })
	return out
}
