// Command tailnet-forwarder relays tailnet TCP flows to the cxagents Docker
// network. Subcommands: serve (default), login (one auth key on stdin), and
// check (inspect the running node or its state directory).
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"tailscale.com/client/local"

	"tailnet-forwarder/internal/check"
	"tailnet-forwarder/internal/flow"
	"tailnet-forwarder/internal/netcheck"
	"tailnet-forwarder/internal/node"
	"tailnet-forwarder/internal/resolve"
	"tailnet-forwarder/internal/routes"
	"tailnet-forwarder/internal/status"
)

const (
	maxKeyBytes       = 4 << 10
	targetResolveBy   = 5 * time.Second
	usageText         = "usage: tailnet-forwarder [serve | login | check [--state-only]]"
	noNodeHint        = "no node in state — run `dotfiles stacks cxagents login`"
	rejectLogBuffer   = 1024
	rejectReportEvery = 10 * time.Second
)

// localNet reports the container's cxagents address and subnet. It is a
// variable so tests can prove a path never reaches the network check.
var localNet = netcheck.Local

// config is the forwarder's environment, read once in main.
type config struct {
	StateDir        string
	Hostname        string
	Tag             string
	RoutesPath      string
	StatusPort      uint16
	MaxFlowsPerPort int
	MaxFlows        int
	Verbose         bool
}

func (c config) socketPath() string { return c.StateDir + "/forwarder.sock" }

func (c config) nodeConfig() node.Config {
	return node.Config{Dir: c.StateDir, Hostname: c.Hostname, Tag: c.Tag, Verbose: c.Verbose}
}

// configFrom reads the FORWARDER_* environment; unset keys take the defaults.
func configFrom(getenv func(string) string) (config, error) {
	or := func(key, def string) string {
		if v := getenv(key); v != "" {
			return v
		}
		return def
	}
	cfg := config{
		StateDir:   or("FORWARDER_STATE_DIR", "/state"),
		Hostname:   or("FORWARDER_HOSTNAME", "cxagents"),
		Tag:        or("FORWARDER_TAG", "tag:cxagents"),
		RoutesPath: or("FORWARDER_ROUTES", "/etc/forwarder/routes"),
		Verbose:    getenv("FORWARDER_TS_VERBOSE") == "1",
	}
	port, err := strconv.ParseUint(or("FORWARDER_STATUS_PORT", "8080"), 10, 16)
	if err != nil || port == 0 {
		return config{}, fmt.Errorf("FORWARDER_STATUS_PORT: want 1-65535")
	}
	cfg.StatusPort = uint16(port)
	if cfg.MaxFlowsPerPort, err = positiveEnv(or("FORWARDER_MAX_FLOWS_PER_PORT", "32"), "FORWARDER_MAX_FLOWS_PER_PORT"); err != nil {
		return config{}, err
	}
	if cfg.MaxFlows, err = positiveEnv(or("FORWARDER_MAX_FLOWS", "256"), "FORWARDER_MAX_FLOWS"); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func positiveEnv(s, key string) (int, error) {
	n, err := strconv.Atoi(s)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("%s: want a positive integer", key)
	}
	return n, nil
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	code := run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr, os.Getenv)
	stop()
	os.Exit(code)
}

// run dispatches the subcommand named by args[0] (serve when none is given).
func run(ctx context.Context, args []string, stdin io.Reader, stdout, stderr io.Writer, getenv func(string) string) int {
	cfg, err := configFrom(getenv)
	if err != nil {
		fmt.Fprintf(stderr, "tailnet-forwarder: %v\n", err)
		return 2
	}
	cmd, rest := "serve", args
	if len(args) > 0 {
		cmd, rest = args[0], args[1:]
	}
	switch cmd {
	case "serve":
		if len(rest) != 0 {
			fmt.Fprintln(stderr, usageText)
			return 2
		}
		return serveCmd(ctx, cfg, stdout, stderr)
	case "login":
		if len(rest) != 0 {
			fmt.Fprintln(stderr, usageText)
			return 2
		}
		return loginCmd(ctx, cfg, stdin, stdout, stderr)
	case "check":
		return checkCmd(cfg, rest, stdout, stderr)
	default:
		fmt.Fprintln(stderr, usageText)
		return 2
	}
}

// serveCmd runs the forwarder until ctx ends. The checks run in the order the
// design requires: routes, then state, then the network, then the node.
func serveCmd(ctx context.Context, cfg config, stdout, stderr io.Writer) int {
	table, err := routes.Load(cfg.RoutesPath)
	if err != nil {
		fmt.Fprintf(stderr, "tailnet-forwarder: %v\n", err)
		return 1
	}
	id, err := node.StateNodeID(cfg.StateDir)
	if err != nil {
		fmt.Fprintf(stderr, "tailnet-forwarder: %v\n", err)
		return 1
	}
	if id == "" {
		fmt.Fprintf(stderr, "tailnet-forwarder: %s\n", noNodeHint)
		return 1
	}
	local, subnet, err := localNet()
	if err != nil {
		fmt.Fprintf(stderr, "tailnet-forwarder: %v\n", err)
		return 1
	}

	r, err := node.Serve(ctx, cfg.nodeConfig())
	if err != nil {
		fmt.Fprintf(stderr, "tailnet-forwarder: %v\n", err)
		return 1
	}
	defer r.Close()

	names := targetNames(table)
	cache := resolve.New(resolve.DefaultLookup, names, 5*time.Second)
	go cache.Run(ctx)
	awaitResolved(ctx, cache, names, targetResolveBy)

	// The status listener binds the cxagents interface address only (an OS
	// socket). tsnet listeners live on the tailnet and are never used here.
	statusAddr := netip.AddrPortFrom(local, cfg.StatusPort).String()
	statusLn, err := net.Listen("tcp", statusAddr)
	if err != nil {
		fmt.Fprintf(stderr, "tailnet-forwarder: status listener: %v\n", err)
		return 1
	}
	mux := http.NewServeMux()
	mux.Handle("/status", &status.Server{Routes: table, Targets: cache, Domain: r.Domain})
	statusSrv := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := statusSrv.Serve(statusLn); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("status server: %v", err)
		}
	}()

	lc := r.LocalClient()
	handler := &flow.Handler{
		TLS: &tls.Config{
			GetCertificate: lc.GetCertificate,
			NextProtos:     []string{"http/1.1"}, // no h2: HTTP/1.1 dev servers only (AC6.10)
			MinVersion:     tls.VersionTLS12,
		},
		OnDialFail: cache.Refresh,
		WhoIs:      whoIsName(lc),
		Log:        logFlow,
	}
	// Decide runs with tsnet's mutex held, so rejection lines are queued and
	// written by a goroutine; a stalled log drops lines rather than blocking flows.
	rejects := flow.NewAsyncLog(rejectLogBuffer, rejectReportEvery,
		func(f flow.Flow, outcome string) {
			log.Printf("flow src=%s port=%d target=%s outcome=%s", f.Src, f.Port, f.Target, outcome)
		},
		func(dropped uint64) {
			log.Printf("flow rejection log: %d lines dropped since the last report", dropped)
		})
	go rejects.Run(ctx)
	decider := &flow.Decider{
		Routes:  table,
		Subnet:  subnet,
		Targets: cache,
		Caps:    flow.NewCaps(cfg.MaxFlowsPerPort, cfg.MaxFlows),
		Handle:  handler.Serve,
		Log:     rejects.Log,
	}
	unregister := r.Register(decider.Decide)

	checkErr := make(chan error, 1)
	go func() { checkErr <- node.ServeCheck(ctx, cfg.socketPath(), r.Info) }()
	log.Printf("serving %s; status on %s", r.Domain(), statusAddr)

	code := 0
	select {
	case <-ctx.Done():
		err = <-checkErr
	case err = <-checkErr:
		code = 1
	}
	if err != nil {
		fmt.Fprintf(stderr, "tailnet-forwarder: %v\n", err)
	}
	unregister()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := statusSrv.Shutdown(shutdownCtx); err != nil {
		log.Printf("status server shutdown: %v", err)
	}
	return code
}

// loginCmd registers the node from one auth key read from stdin. The key is
// never logged, printed, or placed in argv or the environment.
func loginCmd(ctx context.Context, cfg config, stdin io.Reader, stdout, stderr io.Writer) int {
	key, err := readKey(stdin)
	if err != nil {
		fmt.Fprintf(stderr, "login: %v\n", err)
		return 2
	}
	if key == "" {
		fmt.Fprintln(stderr, "login: no auth key on stdin")
		return 2
	}
	lctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	info, err := node.Login(lctx, cfg.nodeConfig(), key)
	if err != nil {
		fmt.Fprintf(stderr, "login: %v\n", err)
		return 1
	}
	fmt.Fprint(stdout, check.Format(info, time.Now()))
	return 0
}

// readKey reads the first line of r (at most maxKeyBytes) and trims it. The
// error text never includes the input.
func readKey(r io.Reader) (string, error) {
	line, err := bufio.NewReader(io.LimitReader(r, maxKeyBytes+1)).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", fmt.Errorf("reading stdin: %w", err)
	}
	if len(line) > maxKeyBytes {
		return "", fmt.Errorf("auth key exceeds %d bytes", maxKeyBytes)
	}
	return strings.TrimSpace(line), nil
}

// checkCmd prints the state's node ID (--state-only) or the running node's
// identity and problems.
func checkCmd(cfg config, args []string, stdout, stderr io.Writer) int {
	if len(args) == 1 && args[0] == "--state-only" {
		id, err := node.StateNodeID(cfg.StateDir)
		if err != nil {
			fmt.Fprintf(stderr, "check: %v\n", err)
			return 1
		}
		if id == "" {
			fmt.Fprintln(stdout, "state: empty")
			return 1
		}
		fmt.Fprintf(stdout, "state: node %s\n", id)
		return 0
	}
	if len(args) != 0 {
		fmt.Fprintln(stderr, "usage: check [--state-only]")
		return 2
	}
	info, err := node.FetchCheck(cfg.socketPath())
	if err != nil {
		fmt.Fprintf(stderr, "forwarder not running (%v)\n", err)
		return 1
	}
	now := time.Now()
	fmt.Fprint(stdout, check.Format(info, now))
	problems := check.Evaluate(info, cfg.Hostname, cfg.Tag, now)
	for _, p := range problems {
		fmt.Fprintf(stdout, "problem: %s\n", p)
	}
	if len(problems) > 0 {
		return 1
	}
	return 0
}

// targetNames lists each distinct route target once, in table order.
func targetNames(t *routes.Table) []string {
	seen := map[string]bool{}
	var names []string
	for _, r := range t.Routes() {
		if !seen[r.Target] {
			seen[r.Target] = true
			names = append(names, r.Target)
		}
	}
	return names
}

// awaitResolved waits until every name has a cached address, or until limit
// or ctx ends. A name still unresolved after that is retried by the cache.
func awaitResolved(ctx context.Context, c *resolve.Cache, names []string, limit time.Duration) {
	deadline := time.NewTimer(limit)
	defer deadline.Stop()
	t := time.NewTicker(50 * time.Millisecond)
	defer t.Stop()
	for {
		all := true
		for _, n := range names {
			if _, ok := c.Get(n); !ok {
				all = false
				break
			}
		}
		if all {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-deadline.C:
			return
		case <-t.C:
		}
	}
}

// whoIsName names the tailnet node behind a source address for the flow log.
func whoIsName(lc *local.Client) func(context.Context, netip.AddrPort) string {
	return func(ctx context.Context, src netip.AddrPort) string {
		resp, err := lc.WhoIs(ctx, src.String())
		if err != nil || resp == nil || resp.Node == nil {
			return ""
		}
		return resp.Node.ComputedName
	}
}

func logFlow(f flow.Flow, mode, outcome string, d time.Duration) {
	if mode == "" {
		mode = "-"
	}
	log.Printf("flow node=%s src=%s port=%d target=%s mode=%s outcome=%s duration=%s",
		f.Node, f.Src, f.Port, f.Target, mode, outcome, d.Round(time.Millisecond))
}
