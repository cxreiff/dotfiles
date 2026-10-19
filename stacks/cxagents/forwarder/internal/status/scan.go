package status

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"slices"
	"sync"
	"time"

	"tailnet-forwarder/internal/routes"
)

var errBusy = errors.New("scan limit reached")

// open is one listening port of a target, classified by HEAD probe.
type open struct {
	Port uint16
	HTTP bool
}

// scanResult is the full (unfiltered) scan of one target.
type scanResult struct {
	Listening []open // sorted by port; never includes deny ports
}

type cachedScan struct {
	at  time.Time
	res scanResult
}

// probeTransport never reuses connections, so a probe leaves nothing behind.
var probeTransport = &http.Transport{Proxy: nil, DisableKeepAlives: true}

// defaultProbe reports whether addr answers an HTTP HEAD / with any response.
// ctx bounds the whole exchange, so a silent or non-HTTP socket fails at the
// deadline.
func defaultProbe(ctx context.Context, addr netip.AddrPort) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, "http://"+addr.String()+"/", nil)
	if err != nil {
		return false
	}
	client := &http.Client{Transport: probeTransport}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}

// scanCoalesced runs at most one scan per target at a time; concurrent callers
// for the same target share its result. A fresh cached result is returned
// without scanning. A scan needs a free MaxScans slot, or it fails with errBusy.
func (s *Server) scanCoalesced(target string, ip netip.Addr, rs []routes.Route) (scanResult, error) {
	ch := s.group.DoChan(target, func() (any, error) {
		return s.scanOrCache(target, ip, rs)
	})
	r := <-ch
	if r.Err != nil {
		return scanResult{}, r.Err
	}
	return r.Val.(scanResult), nil
}

func (s *Server) scanOrCache(target string, ip netip.Addr, rs []routes.Route) (scanResult, error) {
	s.mu.Lock()
	c, cached := s.cache[target]
	s.mu.Unlock()
	if cached && s.clock().Sub(c.at) < s.CacheFor {
		return c.res, nil
	}

	select {
	case s.scanSem <- struct{}{}:
	default:
		// The scan limit is full: a cached result, even a stale one, beats a 503.
		if cached {
			return c.res, nil
		}
		return scanResult{}, errBusy
	}
	defer func() { <-s.scanSem }()

	res := s.scan(ip, rs)

	s.mu.Lock()
	s.cache[target] = cachedScan{at: s.clock(), res: res}
	s.mu.Unlock()
	return res, nil
}

// scan dials every allowed port of rs on ip, then probes the open ones.
// Deny ports are excluded before any dial.
func (s *Server) scan(ip netip.Addr, rs []routes.Route) scanResult {
	ports := allowedPorts(rs)

	isOpen := make([]bool, len(ports))
	idx := make(chan int)
	var wg sync.WaitGroup
	for w := 0; w < s.DialSlots; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range idx {
				isOpen[i] = s.dialOpen(netip.AddrPortFrom(ip, ports[i]))
			}
		}()
	}
	for i := range ports {
		idx <- i
	}
	close(idx)
	wg.Wait()

	var openPorts []uint16
	for i, o := range isOpen {
		if o {
			openPorts = append(openPorts, ports[i])
		}
	}
	listening := make([]open, len(openPorts))
	var pwg sync.WaitGroup
	for i, p := range openPorts {
		pwg.Add(1)
		go func() {
			defer pwg.Done()
			listening[i] = open{Port: p, HTTP: s.probeSlot(netip.AddrPortFrom(ip, p))}
		}()
	}
	pwg.Wait()
	return scanResult{Listening: listening}
}

// dialOpen reports whether a TCP connect to addr succeeds within DialTimeout.
// It takes one global DialSlots slot for the duration.
func (s *Server) dialOpen(addr netip.AddrPort) bool {
	s.dialSem <- struct{}{}
	defer func() { <-s.dialSem }()

	ctx, cancel := context.WithTimeout(context.Background(), s.DialTimeout)
	defer cancel()
	dial := s.Dial
	if dial == nil {
		dial = func(ctx context.Context, a netip.AddrPort) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "tcp", a.String())
		}
	}
	c, err := dial(ctx, addr)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// probeSlot runs one HTTP probe while holding a global DialSlots slot, so the
// probes of all concurrent scans share the same bound as the dials.
func (s *Server) probeSlot(addr netip.AddrPort) bool {
	s.dialSem <- struct{}{}
	defer func() { <-s.dialSem }()
	return s.probe(addr)
}

func (s *Server) probe(addr netip.AddrPort) bool {
	ctx, cancel := context.WithTimeout(context.Background(), s.ProbeTimeout)
	defer cancel()
	if s.HTTPProbe != nil {
		return s.HTTPProbe(ctx, addr)
	}
	return defaultProbe(ctx, addr)
}

// allowedPorts returns every non-denied port of rs, ascending and without duplicates.
func allowedPorts(rs []routes.Route) []uint16 {
	var ports []uint16
	for _, r := range rs {
		for p := uint32(r.From); p <= uint32(r.To); p++ {
			if r.Allowed(uint16(p)) {
				ports = append(ports, uint16(p))
			}
		}
	}
	slices.Sort(ports)
	return slices.Compact(ports)
}
