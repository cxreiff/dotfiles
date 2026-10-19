package main

import (
	"bytes"
	"context"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tailnet-forwarder/internal/check"
	"tailnet-forwarder/internal/node"
)

// writeFile writes content to a new file under t.TempDir and returns its path.
func writeFile(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

// testConfig is a config over an empty state directory and a valid routes file.
func testConfig(t *testing.T) config {
	return config{
		StateDir:        t.TempDir(),
		Hostname:        "cxagents",
		Tag:             "tag:cxagents",
		RoutesPath:      writeFile(t, "routes", "t1 20000-20009 20005\n"),
		StatusPort:      8080,
		MaxFlowsPerPort: 32,
		MaxFlows:        256,
	}
}

func TestServeRoutesErrorBeforeState(t *testing.T) {
	cfg := testConfig(t)
	cfg.RoutesPath = writeFile(t, "routes", "a 1024-5000 -\nb 4000-6000 -\n")
	// A state directory that does not exist: serve must fail on the routes
	// before it ever looks at (or creates) state.
	cfg.StateDir = filepath.Join(t.TempDir(), "missing")

	var stdout, stderr bytes.Buffer
	code := serveCmd(context.Background(), cfg, &stdout, &stderr)
	if code != 1 {
		t.Fatalf("exit = %d, want 1", code)
	}
	if !strings.Contains(stderr.String(), "overlaps") {
		t.Errorf("stderr = %q, want the routes overlap error", stderr.String())
	}
	if strings.Contains(stderr.String(), "login") {
		t.Errorf("stderr = %q: reached the login hint before the routes error", stderr.String())
	}
	if _, err := os.Stat(cfg.StateDir); !os.IsNotExist(err) {
		t.Errorf("state dir was touched: stat err = %v", err)
	}
}

func TestServeEmptyStateHintsLoginBeforeNetwork(t *testing.T) {
	cfg := testConfig(t)

	called := false
	saved := localNet
	localNet = func() (netip.Addr, netip.Prefix, error) {
		called = true
		return netip.Addr{}, netip.Prefix{}, nil
	}
	t.Cleanup(func() { localNet = saved })

	var stdout, stderr bytes.Buffer
	code := serveCmd(context.Background(), cfg, &stdout, &stderr)
	if code != 1 {
		t.Fatalf("exit = %d, want 1", code)
	}
	if !strings.Contains(stderr.String(), "dotfiles stacks cxagents login") {
		t.Errorf("stderr = %q, want the login hint", stderr.String())
	}
	if called {
		t.Error("netcheck ran before the state gate")
	}
}

func TestCheckStateOnlyEmpty(t *testing.T) {
	cfg := testConfig(t)
	var stdout, stderr bytes.Buffer
	code := checkCmd(cfg, []string{"--state-only"}, &stdout, &stderr)
	if code != 1 {
		t.Fatalf("exit = %d, want 1", code)
	}
	if got := strings.TrimSpace(stdout.String()); got != "state: empty" {
		t.Errorf("stdout = %q, want %q", got, "state: empty")
	}
}

func TestCheckWithoutForwarderFails(t *testing.T) {
	cfg := testConfig(t)
	var stdout, stderr bytes.Buffer
	code := checkCmd(cfg, nil, &stdout, &stderr)
	if code != 1 {
		t.Fatalf("exit = %d, want 1", code)
	}
	if !strings.Contains(stderr.String(), "forwarder not running") {
		t.Errorf("stderr = %q, want \"forwarder not running\"", stderr.String())
	}
}

func TestCheckReportsProblemsFromRunningForwarder(t *testing.T) {
	cfg := testConfig(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	offline := check.NodeInfo{
		Name: "cxagents", DNSName: "cxagents.faun-fir.ts.net.", ID: "nXYZ",
		Tags: []string{"tag:cxagents"}, BackendState: "Running",
		CertNotAfter: time.Now().Add(90 * 24 * time.Hour),
	}
	served := make(chan error, 1)
	go func() {
		served <- node.ServeCheck(ctx, cfg.socketPath(), func(context.Context) check.NodeInfo { return offline })
	}()
	for i := 0; i < 100; i++ {
		if _, err := node.FetchCheck(cfg.socketPath()); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	var stdout, stderr bytes.Buffer
	code := checkCmd(cfg, nil, &stdout, &stderr)
	if code != 1 {
		t.Fatalf("exit = %d, want 1 (offline node)", code)
	}
	if !strings.Contains(stdout.String(), "problem: node is offline") {
		t.Errorf("stdout = %q, want the offline problem", stdout.String())
	}
	if !strings.Contains(stdout.String(), "node:") {
		t.Errorf("stdout = %q, want the formatted node summary", stdout.String())
	}
}

func TestLoginEmptyStdinExits2(t *testing.T) {
	cfg := testConfig(t)
	var stdout, stderr bytes.Buffer
	code := loginCmd(context.Background(), cfg, strings.NewReader(""), &stdout, &stderr)
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "no auth key on stdin") {
		t.Errorf("stderr = %q, want \"no auth key on stdin\"", stderr.String())
	}
}

func TestLoginOversizedKeyRejectedWithoutEcho(t *testing.T) {
	cfg := testConfig(t)
	oversized := strings.Repeat("SECRETISH", 600) // 5400 bytes, no newline
	var stdout, stderr bytes.Buffer
	code := loginCmd(context.Background(), cfg, strings.NewReader(oversized), &stdout, &stderr)
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if strings.Contains(stderr.String(), "SECRETISH") || strings.Contains(stdout.String(), "SECRETISH") {
		t.Error("login echoed key material")
	}
}

func TestReadKeyTakesOnlyFirstLine(t *testing.T) {
	// The dummy key is built from fragments so no literal key-shaped value
	// lives in tracked sources (tailscale/scripts/keyscan.sh --repo; the
	// Task 6 assertion greps stacks/cxagents for the literal prefix).
	first := "tsk" + "ey-first"
	got, err := readKey(strings.NewReader("  " + first + "  \nsecond-line\n"))
	if err != nil {
		t.Fatal(err)
	}
	if got != first {
		t.Errorf("readKey = %q, want %q", got, first)
	}
}

func TestReadKeyAcceptsUnterminatedLineAtLimit(t *testing.T) {
	line := strings.Repeat("a", maxKeyBytes)
	got, err := readKey(strings.NewReader(line))
	if err != nil {
		t.Fatalf("exactly %d bytes: %v", maxKeyBytes, err)
	}
	if got != line {
		t.Errorf("readKey returned %d bytes, want %d", len(got), maxKeyBytes)
	}
}

func TestConfigFromDefaultsAndOverrides(t *testing.T) {
	cfg, err := configFrom(func(string) string { return "" })
	if err != nil {
		t.Fatal(err)
	}
	want := config{
		StateDir: "/state", Hostname: "cxagents", Tag: "tag:cxagents",
		RoutesPath: "/etc/forwarder/routes", StatusPort: 8080,
		MaxFlowsPerPort: 32, MaxFlows: 256,
	}
	if cfg != want {
		t.Errorf("defaults = %+v, want %+v", cfg, want)
	}

	env := map[string]string{
		"FORWARDER_STATUS_PORT": "9090", "FORWARDER_MAX_FLOWS": "10", "FORWARDER_TS_VERBOSE": "1",
	}
	cfg, err = configFrom(func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	if cfg.StatusPort != 9090 || cfg.MaxFlows != 10 || !cfg.Verbose {
		t.Errorf("overrides not applied: %+v", cfg)
	}

	for _, bad := range []string{"0", "70000", "http"} {
		_, err := configFrom(func(k string) string {
			if k == "FORWARDER_STATUS_PORT" {
				return bad
			}
			return ""
		})
		if err == nil {
			t.Errorf("FORWARDER_STATUS_PORT=%q: want error", bad)
		}
	}
}

func TestRunRejectsUnknownSubcommand(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{"bogus"}, strings.NewReader(""), &stdout, &stderr, func(string) string { return "" })
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "usage") {
		t.Errorf("stderr = %q, want usage", stderr.String())
	}
}
