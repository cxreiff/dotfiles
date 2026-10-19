package flow

import "sync"

// Caps bounds in-flight flows per destination port and globally. Acquire
// never blocks: a flow over either cap is reset, not queued.
type Caps struct {
	mu         sync.Mutex
	perPort    map[uint16]int
	total      int
	maxPerPort int
	maxTotal   int
}

// NewCaps returns caps allowing maxPerPort flows on any one port and
// maxTotal flows overall.
func NewCaps(maxPerPort, maxTotal int) *Caps {
	return &Caps{perPort: map[uint16]int{}, maxPerPort: maxPerPort, maxTotal: maxTotal}
}

// Acquire takes a slot for port. It reports false, without waiting, when
// either cap is reached.
func (c *Caps) Acquire(port uint16) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.total >= c.maxTotal || c.perPort[port] >= c.maxPerPort {
		return false
	}
	c.total++
	c.perPort[port]++
	return true
}

// Release returns a slot taken by Acquire(port). Releasing a port with no
// held slot is a no-op.
func (c *Caps) Release(port uint16) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.perPort[port] == 0 {
		return
	}
	c.perPort[port]--
	if c.perPort[port] == 0 {
		delete(c.perPort, port)
	}
	c.total--
}
