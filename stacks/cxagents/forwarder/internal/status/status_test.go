package status

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"tailnet-forwarder/internal/routes"
)

const testDomain = "cxagents.faun-fir.ts.net"

var errRefused = errors.New("refused")

// fakeTargets maps target names to resolved addresses.
type fakeTargets map[string][]netip.Addr

func (f fakeTargets) Get(name string) ([]netip.Addr, bool) {
	a, ok := f[name]
	return a, ok
}

// fakeNet scripts which ports are open and records every dial and probe.
type fakeNet struct {
	mu      sync.Mutex
	open    map[uint16]bool
	httpOK  map[uint16]bool
	dials   map[uint16]int
	probes  map[uint16]int
	gate    chan struct{} // when non-nil, Dial blocks until it is closed
	dialing chan struct{} // closed on the first Dial call
	once    sync.Once
}

func newFakeNet(open []uint16, httpOK []uint16) *fakeNet {
	f := &fakeNet{
		open:    map[uint16]bool{},
		httpOK:  map[uint16]bool{},
		dials:   map[uint16]int{},
		probes:  map[uint16]int{},
		dialing: make(chan struct{}),
	}
	for _, p := range open {
		f.open[p] = true
	}
	for _, p := range httpOK {
		f.httpOK[p] = true
	}
	return f
}

func (f *fakeNet) Dial(ctx context.Context, addr netip.AddrPort) (net.Conn, error) {
	f.once.Do(func() { close(f.dialing) })
	f.mu.Lock()
	f.dials[addr.Port()]++
	open := f.open[addr.Port()]
	gate := f.gate
	f.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if !open {
		return nil, errRefused
	}
	c1, c2 := net.Pipe()
	c2.Close()
	return c1, nil
}

func (f *fakeNet) Probe(_ context.Context, addr netip.AddrPort) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.probes[addr.Port()]++
	return f.httpOK[addr.Port()]
}

func (f *fakeNet) dialCount(port uint16) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.dials[port]
}

func (f *fakeNet) probeCount(port uint16) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.probes[port]
}

// clock is an injectable time source so cache expiry is deterministic.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

func newTestServer(t *testing.T, routeText string, targets fakeTargets, f *fakeNet) (*Server, *clock) {
	t.Helper()
	tbl, err := routes.Parse(strings.NewReader(routeText))
	if err != nil {
		t.Fatalf("routes: %v", err)
	}
	clk := &clock{t: time.Unix(1_800_000_000, 0)}
	s := &Server{
		Routes:       tbl,
		Targets:      targets,
		Domain:       func() string { return testDomain },
		Dial:         f.Dial,
		HTTPProbe:    f.Probe,
		DialTimeout:  time.Second,
		ProbeTimeout: time.Second,
		CacheFor:     time.Minute,
		MaxScans:     2,
		DialSlots:    4,
		now:          clk.Now,
	}
	return s, clk
}

func get(s *Server, src, target string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, target, nil)
	req.RemoteAddr = src + ":40000"
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	return rec
}

func addr(s string) netip.Addr { return netip.MustParseAddr(s) }

const oneTarget = "t1 20000-20009 20005\n"

func TestNotATargetIs404(t *testing.T) {
	f := newFakeNet(nil, nil)
	s, _ := newTestServer(t, oneTarget, fakeTargets{"t1": {addr("10.0.0.5")}}, f)

	rec := get(s, "10.0.0.9", "/status")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("code = %d, want 404", rec.Code)
	}
	if got := strings.TrimSpace(rec.Body.String()); got != "not a cxagents target" {
		t.Fatalf("body = %q", got)
	}
	if f.dialCount(20001) != 0 {
		t.Fatal("an unidentified caller must not trigger a scan")
	}
}

func TestAmbiguousTargetIs500(t *testing.T) {
	f := newFakeNet(nil, nil)
	targets := fakeTargets{"t1": {addr("10.0.0.5"), addr("10.0.0.6")}}
	s, _ := newTestServer(t, oneTarget, targets, f)

	rec := get(s, "10.0.0.5", "/status")
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("code = %d, want 500", rec.Code)
	}
	want := "ambiguous: t1 resolves to 2 addresses"
	if got := strings.TrimSpace(rec.Body.String()); got != want {
		t.Fatalf("body = %q, want %q", got, want)
	}
}

func TestDeniedPortNeverDialedOrProbed(t *testing.T) {
	f := newFakeNet([]uint16{20001, 20005}, []uint16{20001, 20005})
	s, _ := newTestServer(t, oneTarget, fakeTargets{"t1": {addr("10.0.0.5")}}, f)

	rec := get(s, "10.0.0.5", "/status?format=json")
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d", rec.Code)
	}
	if n := f.dialCount(20005); n != 0 {
		t.Fatalf("deny port 20005 dialed %d times", n)
	}
	if n := f.probeCount(20005); n != 0 {
		t.Fatalf("deny port 20005 probed %d times", n)
	}
	if n := f.dialCount(20001); n != 1 {
		t.Fatalf("open port 20001 dialed %d times, want 1", n)
	}
	if n := f.probeCount(20001); n != 1 {
		t.Fatalf("open port 20001 probed %d times, want 1", n)
	}
	if n := f.probeCount(20002); n != 0 {
		t.Fatalf("closed port 20002 probed %d times", n)
	}
}

func TestDefaultProbeClassifiesHTTPAndRaw(t *testing.T) {
	web := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	t.Cleanup(web.Close)
	webAddr := netip.MustParseAddrPort(strings.TrimPrefix(web.URL, "http://"))

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var held sync.Map // accepted connections, kept open and silent until cleanup
	t.Cleanup(func() {
		ln.Close()
		held.Range(func(k, _ any) bool { k.(net.Conn).Close(); return true })
	})
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			held.Store(c, true)
		}
	}()
	rawAddr := netip.MustParseAddrPort(ln.Addr().String())

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if !defaultProbe(ctx, webAddr) {
		t.Fatal("httptest server: probe = false, want true")
	}

	ctx2, cancel2 := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel2()
	start := time.Now()
	if defaultProbe(ctx2, rawAddr) {
		t.Fatal("silent raw TCP listener: probe = true, want false")
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("probe took %v, want about the 200ms bound", d)
	}
}

func TestConcurrentRequestsShareOneScan(t *testing.T) {
	f := newFakeNet([]uint16{20001, 20002, 20003, 20004, 20005, 20006, 20007, 20008, 20009, 20000}, nil)
	s, _ := newTestServer(t, "t1 20000-20009 -\n", fakeTargets{"t1": {addr("10.0.0.5")}}, f)

	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			rec := get(s, "10.0.0.5", "/status?ports="+portList(20000+uint16(i)))
			if rec.Code != http.StatusOK {
				t.Errorf("request %d: code = %d", i, rec.Code)
			}
		}(i)
	}
	wg.Wait()

	for p := uint16(20000); p <= 20009; p++ {
		if n := f.dialCount(p); n != 1 {
			t.Fatalf("port %d dialed %d times across 10 requests, want 1", p, n)
		}
	}
}

func TestCacheExpiresAfterCacheFor(t *testing.T) {
	f := newFakeNet([]uint16{20001}, nil)
	s, clk := newTestServer(t, oneTarget, fakeTargets{"t1": {addr("10.0.0.5")}}, f)
	s.CacheFor = 50 * time.Millisecond

	get(s, "10.0.0.5", "/status")
	clk.Advance(20 * time.Millisecond)
	get(s, "10.0.0.5", "/status")
	if n := f.dialCount(20001); n != 1 {
		t.Fatalf("inside CacheFor: dialed %d times, want 1", n)
	}
	clk.Advance(60 * time.Millisecond)
	get(s, "10.0.0.5", "/status")
	if n := f.dialCount(20001); n != 2 {
		t.Fatalf("after CacheFor: dialed %d times, want 2", n)
	}
}

func TestMaxScansFullReturns503(t *testing.T) {
	f := newFakeNet([]uint16{20001}, nil)
	f.gate = make(chan struct{})
	t.Cleanup(func() {
		select {
		case <-f.gate:
		default:
			close(f.gate)
		}
	})
	targets := fakeTargets{"t1": {addr("10.0.0.5")}, "t2": {addr("10.0.0.6")}}
	s, _ := newTestServer(t, "t1 20000-20009 -\nt2 30000-30009 -\n", targets, f)
	s.MaxScans = 1
	s.DialTimeout = time.Minute

	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- get(s, "10.0.0.5", "/status") }()
	<-f.dialing // t1's scan now holds the only scan slot

	rec := get(s, "10.0.0.6", "/status")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("second caller: code = %d, want 503", rec.Code)
	}
	if got := strings.TrimSpace(rec.Body.String()); got != "scan limit reached; retry in a few seconds" {
		t.Fatalf("body = %q", got)
	}

	close(f.gate)
	if first := <-done; first.Code != http.StatusOK {
		t.Fatalf("first caller: code = %d, want 200", first.Code)
	}
}

func TestPortsParamFiltersCachedScan(t *testing.T) {
	f := newFakeNet([]uint16{20001, 20002}, nil)
	s, _ := newTestServer(t, oneTarget, fakeTargets{"t1": {addr("10.0.0.5")}}, f)

	rec := get(s, "10.0.0.5", "/status?ports=20001,20003,20005&format=json")
	body := rec.Body.String()
	if !strings.Contains(body, `"port":20001`) || strings.Contains(body, `"port":20002`) ||
		strings.Contains(body, `"port":20003`) || strings.Contains(body, `"port":20005`) {
		t.Fatalf("filtered listing = %s", body)
	}
	get(s, "10.0.0.5", "/status?ports=20002")
	for p := uint16(20000); p <= 20009; p++ {
		want := 1
		if p == 20005 {
			want = 0
		}
		if n := f.dialCount(p); n != want {
			t.Fatalf("port %d dialed %d times, want %d (a ports filter must not scan)", p, n, want)
		}
	}
}

func TestMalformedPortsIs400(t *testing.T) {
	f := newFakeNet(nil, nil)
	s, _ := newTestServer(t, oneTarget, fakeTargets{"t1": {addr("10.0.0.5")}}, f)
	for _, q := range []string{"ports=abc", "ports=", "ports=20001,,20002", "ports=0", "ports=70000"} {
		if rec := get(s, "10.0.0.5", "/status?"+q); rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: code = %d, want 400", q, rec.Code)
		}
	}
}

func TestGoldenTextAndJSON(t *testing.T) {
	f := newFakeNet([]uint16{3100, 5173, 9000}, []uint16{5173})
	s, _ := newTestServer(t, "connectome-shell 1024-65535 3100\n",
		fakeTargets{"connectome-shell": {addr("10.0.0.7")}}, f)

	text := get(s, "10.0.0.7", "/status")
	wantText := "target: connectome-shell\n" +
		"node:   https://cxagents.faun-fir.ts.net:<port>\n" +
		"range:  1024-65535   deny: 3100\n" +
		"listening (reachable from the forwarder):\n" +
		"  5173  http=yes   https://cxagents.faun-fir.ts.net:5173\n" +
		"  9000  http=no    (raw TCP)  cxagents.faun-fir.ts.net:9000\n"
	if text.Code != http.StatusOK {
		t.Fatalf("text code = %d", text.Code)
	}
	if got := text.Body.String(); got != wantText {
		t.Fatalf("text mismatch\n got:\n%s\nwant:\n%s", got, wantText)
	}

	js := get(s, "10.0.0.7", "/status?format=json")
	wantJSON := `{"target":"connectome-shell","node":"cxagents.faun-fir.ts.net","range":{"from":1024,"to":65535},"deny":[3100],"listening":[{"port":5173,"http":true,"url":"https://cxagents.faun-fir.ts.net:5173"},{"port":9000,"http":false,"url":"cxagents.faun-fir.ts.net:9000"}]}`
	if got := strings.TrimSpace(js.Body.String()); got != wantJSON {
		t.Fatalf("json mismatch\n got: %s\nwant: %s", got, wantJSON)
	}
	if f.dialCount(3100) != 0 || f.probeCount(3100) != 0 {
		t.Fatal("deny port 3100 must never be dialed or probed")
	}
}

func TestEmptyListeningAndNoDenyText(t *testing.T) {
	f := newFakeNet(nil, nil)
	s, _ := newTestServer(t, "t1 20000-20009 -\n", fakeTargets{"t1": {addr("10.0.0.5")}}, f)

	got := get(s, "10.0.0.5", "/status").Body.String()
	want := "target: t1\n" +
		"node:   https://cxagents.faun-fir.ts.net:<port>\n" +
		"range:  20000-20009   deny: -\n" +
		"listening (reachable from the forwarder):\n" +
		"  (none)\n"
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestOnlyGETStatusIsServed(t *testing.T) {
	f := newFakeNet(nil, nil)
	s, _ := newTestServer(t, oneTarget, fakeTargets{"t1": {addr("10.0.0.5")}}, f)

	req := httptest.NewRequest(http.MethodPost, "/status", nil)
	req.RemoteAddr = "10.0.0.5:40000"
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /status: code = %d, want 405", rec.Code)
	}
	if rec := get(s, "10.0.0.5", "/other"); rec.Code != http.StatusNotFound {
		t.Fatalf("GET /other: code = %d, want 404", rec.Code)
	}
}

func portList(p uint16) string { return strconv.FormatUint(uint64(p), 10) }
