// Package status serves the agent-facing status endpoint: GET /status lists
// the ports a calling container's target is listening on, as this forwarder
// can reach them. The caller is identified by its source address, and the
// results are scanned at most once per CacheFor per target.
package status

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"

	"tailnet-forwarder/internal/routes"
)

// Server is the status endpoint. Zero-valued durations and limits take the
// defaults documented on each field; the Server must not be copied after use.
type Server struct {
	Routes  *routes.Table
	Targets interface {
		Get(string) ([]netip.Addr, bool)
	}
	Domain func() string // e.g. "cxagents.faun-fir.ts.net"
	// Dial connects to a port for the open/closed check. Nil means net.Dialer.
	Dial func(ctx context.Context, addr netip.AddrPort) (net.Conn, error)
	// HTTPProbe classifies an open port; any HTTP response is true. Nil means
	// defaultProbe (HEAD /).
	HTTPProbe    func(ctx context.Context, addr netip.AddrPort) bool
	DialTimeout  time.Duration // default 300 ms per port
	ProbeTimeout time.Duration // default 1 s per HEAD
	CacheFor     time.Duration // default 5 s per target
	MaxScans     int           // default 2 concurrent scans; beyond that, 503
	DialSlots    int           // default 128 concurrent dials across all scans

	now func() time.Time // test hook; nil means time.Now

	setup   sync.Once
	group   singleflight.Group
	mu      sync.Mutex
	cache   map[string]cachedScan
	scanSem chan struct{}
	dialSem chan struct{}
}

const (
	defaultDialTimeout  = 300 * time.Millisecond
	defaultProbeTimeout = time.Second
	defaultCacheFor     = 5 * time.Second
	defaultMaxScans     = 2
	defaultDialSlots    = 128
)

func (s *Server) init() {
	s.setup.Do(func() {
		if s.DialTimeout <= 0 {
			s.DialTimeout = defaultDialTimeout
		}
		if s.ProbeTimeout <= 0 {
			s.ProbeTimeout = defaultProbeTimeout
		}
		if s.CacheFor <= 0 {
			s.CacheFor = defaultCacheFor
		}
		if s.MaxScans <= 0 {
			s.MaxScans = defaultMaxScans
		}
		if s.DialSlots <= 0 {
			s.DialSlots = defaultDialSlots
		}
		s.cache = map[string]cachedScan{}
		s.scanSem = make(chan struct{}, s.MaxScans)
		s.dialSem = make(chan struct{}, s.DialSlots)
	})
}

func (s *Server) clock() time.Time {
	if s.now != nil {
		return s.now()
	}
	return time.Now()
}

// ServeHTTP answers GET /status only.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.init()
	if r.URL.Path != "/status" {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	src, err := sourceAddr(r.RemoteAddr)
	if err != nil {
		http.Error(w, "not a cxagents target", http.StatusNotFound)
		return
	}
	target, rs, code, msg := s.identify(src)
	if code != 0 {
		http.Error(w, msg, code)
		return
	}

	filter, err := parsePorts(r.URL.Query())
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	res, err := s.scanCoalesced(target, src, rs)
	if err == errBusy {
		http.Error(w, "scan limit reached; retry in a few seconds", http.StatusServiceUnavailable)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	v := newView(target, s.domain(), rs, filterOpen(res.Listening, filter))
	if r.URL.Query().Get("format") == "json" {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(v.jsonOut())
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(v.text()))
}

func (s *Server) domain() string {
	if s.Domain == nil {
		return ""
	}
	return s.Domain()
}

// identify maps the caller's address to its single route target. It returns
// an HTTP status and message instead of a target when the caller is unknown
// (404) or ambiguous (500).
func (s *Server) identify(src netip.Addr) (string, []routes.Route, int, string) {
	var hits []string
	seen := map[string]bool{}
	for _, rt := range s.Routes.Routes() {
		if seen[rt.Target] {
			continue
		}
		seen[rt.Target] = true
		addrs, ok := s.Targets.Get(rt.Target)
		if !ok || !slices.Contains(addrs, src) {
			continue
		}
		if len(addrs) > 1 {
			return "", nil, http.StatusInternalServerError,
				fmt.Sprintf("ambiguous: %s resolves to %d addresses", rt.Target, len(addrs))
		}
		hits = append(hits, rt.Target)
	}
	switch len(hits) {
	case 0:
		return "", nil, http.StatusNotFound, "not a cxagents target"
	case 1:
		return hits[0], routesFor(s.Routes, hits[0]), 0, ""
	default:
		return "", nil, http.StatusInternalServerError,
			fmt.Sprintf("ambiguous: %s and %s both resolve to %s", hits[0], hits[1], src)
	}
}

func routesFor(t *routes.Table, target string) []routes.Route {
	var out []routes.Route
	for _, rt := range t.Routes() {
		if rt.Target == target {
			out = append(out, rt)
		}
	}
	return out
}

func sourceAddr(remote string) (netip.Addr, error) {
	ap, err := netip.ParseAddrPort(remote)
	if err != nil {
		return netip.Addr{}, err
	}
	return ap.Addr().Unmap(), nil
}

// parsePorts reads ?ports=a,b,c. Absent means no filter (nil); present must
// be a non-empty list of ports 1-65535.
func parsePorts(q url.Values) (map[uint16]bool, error) {
	if !q.Has("ports") {
		return nil, nil
	}
	out := map[uint16]bool{}
	for _, part := range strings.Split(q.Get("ports"), ",") {
		n, err := strconv.ParseUint(part, 10, 16)
		if err != nil || n == 0 {
			return nil, fmt.Errorf("ports: %q is not a port 1-65535", part)
		}
		out[uint16(n)] = true
	}
	return out, nil
}

func filterOpen(in []open, filter map[uint16]bool) []open {
	out := make([]open, 0, len(in))
	for _, o := range in {
		if filter == nil || filter[o.Port] {
			out = append(out, o)
		}
	}
	return out
}

// view is the rendered content of one status response.
type view struct {
	target    string
	domain    string
	routes    []routes.Route
	listening []open
}

func newView(target, domain string, rs []routes.Route, listening []open) view {
	return view{target: target, domain: domain, routes: rs, listening: listening}
}

func (v view) deny() []uint16 {
	var out []uint16
	for _, rt := range v.routes {
		for p := range rt.Deny {
			out = append(out, p)
		}
	}
	slices.Sort(out)
	return out
}

func (v view) text() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%-8s%s\n", "target:", v.target)
	fmt.Fprintf(&b, "%-8s%s\n", "node:", "https://"+v.domain+":<port>")

	var ranges []string
	for _, rt := range v.routes {
		ranges = append(ranges, fmt.Sprintf("%d-%d", rt.From, rt.To))
	}
	deny := "-"
	if d := v.deny(); len(d) > 0 {
		deny = joinPorts(d)
	}
	fmt.Fprintf(&b, "%-8s%s   deny: %s\n", "range:", strings.Join(ranges, ", "), deny)

	b.WriteString("listening (reachable from the forwarder):\n")
	if len(v.listening) == 0 {
		b.WriteString("  (none)\n")
	}
	for _, o := range v.listening {
		if o.HTTP {
			fmt.Fprintf(&b, "  %-4d  %-8s   %s\n", o.Port, "http=yes", v.url(o.Port))
		} else {
			fmt.Fprintf(&b, "  %-4d  %-8s   (raw TCP)  %s\n", o.Port, "http=no", v.hostPort(o.Port))
		}
	}
	return b.String()
}

func joinPorts(ps []uint16) string {
	parts := make([]string, len(ps))
	for i, p := range ps {
		parts[i] = strconv.Itoa(int(p))
	}
	return strings.Join(parts, ",")
}

func (v view) url(port uint16) string { return fmt.Sprintf("https://%s:%d", v.domain, port) }

func (v view) hostPort(port uint16) string { return fmt.Sprintf("%s:%d", v.domain, port) }

type jsonRange struct {
	From uint16 `json:"from"`
	To   uint16 `json:"to"`
}

type jsonEntry struct {
	Port uint16 `json:"port"`
	HTTP bool   `json:"http"`
	URL  string `json:"url"`
}

// jsonOutput is the design's single-route shape. A target with several routes
// adds "ranges" (every route); "range" is then its first route, so no gap
// between routes is ever reported as reachable.
type jsonOutput struct {
	Target    string      `json:"target"`
	Node      string      `json:"node"`
	Range     jsonRange   `json:"range"`
	Ranges    []jsonRange `json:"ranges,omitempty"`
	Deny      []uint16    `json:"deny"`
	Listening []jsonEntry `json:"listening"`
}

func (v view) jsonOut() jsonOutput {
	out := jsonOutput{
		Target:    v.target,
		Node:      v.domain,
		Range:     jsonRange{From: v.routes[0].From, To: v.routes[0].To},
		Deny:      []uint16{},
		Listening: []jsonEntry{},
	}
	if len(v.routes) > 1 {
		for _, rt := range v.routes {
			out.Ranges = append(out.Ranges, jsonRange{From: rt.From, To: rt.To})
		}
	}
	out.Deny = append(out.Deny, v.deny()...)
	for _, o := range v.listening {
		e := jsonEntry{Port: o.Port, HTTP: o.HTTP}
		if o.HTTP {
			e.URL = v.url(o.Port)
		} else {
			e.URL = v.hostPort(o.Port)
		}
		out.Listening = append(out.Listening, e)
	}
	return out
}
