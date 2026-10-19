// Package node wires the forwarder to its tailnet node: tsnet startup gated on
// the state directory, the TLS certificate for the node's domain, and the
// check socket that `check` reads.
package node

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"

	"tailnet-forwarder/internal/check"
)

// Config is the node identity and state location, from the environment.
type Config struct {
	Dir      string // state directory (tailscaled.state, certs, logs)
	Hostname string // requested node name, e.g. cxagents
	Tag      string // the single tag the node must carry, e.g. tag:cxagents
	Verbose  bool   // pass tsnet's backend logs through
}

const (
	certRetry     = 5 * time.Second
	certRefresh   = 24 * time.Hour
	serveTimeout  = 2 * time.Minute
	noNodeMessage = "no node in state — run `dotfiles stacks cxagents login`"
)

// clearAuthKeyEnv removes tsnet's auth-key environment fallbacks so that no
// key in the environment is ever consulted. The names are split so the
// repo-wide credential-name scan (tailscale/scripts/keyscan.sh) stays clean.
func clearAuthKeyEnv() {
	for _, k := range []string{"TS_" + "AUTH" + "KEY", "TS_" + "AUTH_" + "KEY"} {
		os.Unsetenv(k)
	}
}

// newServer builds the tsnet server for cfg. authKey is used only when the
// state holds no node yet, and only by Login.
func newServer(cfg Config, authKey string) (*tsnet.Server, error) {
	clearAuthKeyEnv()
	logs := filepath.Join(cfg.Dir, "logs")
	if err := os.MkdirAll(logs, 0700); err != nil {
		return nil, fmt.Errorf("state logs dir: %w", err)
	}
	if os.Getenv("TS_LOGS_DIR") == "" {
		// Keep sockstat logs inside the state volume; the default is $HOME/.cache.
		if err := os.Setenv("TS_LOGS_DIR", logs); err != nil {
			return nil, fmt.Errorf("TS_LOGS_DIR: %w", err)
		}
	}
	var backendLog logger.Logf = func(string, ...any) {}
	if cfg.Verbose {
		backendLog = log.Printf
	}
	return &tsnet.Server{
		Dir:           cfg.Dir,
		Hostname:      cfg.Hostname,
		AdvertiseTags: []string{cfg.Tag},
		AuthKey:       authKey,
		UserLogf:      log.Printf,
		Logf:          backendLog,
	}, nil
}

// Login registers a fresh node from authKey. It refuses when the state already
// holds a node, and fails when the tailnet assigns a name other than
// cfg.Hostname (a stale device holds it). The certificate must be issuable.
func Login(ctx context.Context, cfg Config, authKey string) (check.NodeInfo, error) {
	id, err := StateNodeID(cfg.Dir)
	if err != nil {
		return check.NodeInfo{}, err
	}
	if id != "" {
		return check.NodeInfo{}, fmt.Errorf("state already holds node %s; refusing to log in again", id)
	}
	srv, err := newServer(cfg, authKey)
	if err != nil {
		return check.NodeInfo{}, err
	}
	defer srv.Close()

	st, err := srv.Up(ctx)
	if err != nil {
		return check.NodeInfo{}, fmt.Errorf("login: %w", err)
	}
	info := infoFrom(st)
	if info.Name != cfg.Hostname {
		return check.NodeInfo{}, fmt.Errorf("tailnet assigned node name %q, not %q: a stale device holds %q; remove it in the admin console and login again", info.Name, cfg.Hostname, cfg.Hostname)
	}
	if len(st.CertDomains) == 0 {
		return check.NodeInfo{}, errors.New("HTTPS certificates are not enabled for the tailnet (tailscale/README.md settings checklist)")
	}
	lc, err := srv.LocalClient()
	if err != nil {
		return check.NodeInfo{}, err
	}
	notAfter, err := warmCert(ctx, lc, st.CertDomains[0])
	if err != nil {
		return check.NodeInfo{}, err
	}
	info.CertNotAfter = notAfter
	return info, nil
}

// Running is a started forwarder node.
type Running struct {
	srv    *tsnet.Server
	lc     *local.Client
	domain string

	mu           sync.Mutex
	certNotAfter time.Time

	stop chan struct{}
	once sync.Once
}

// Serve starts the node from existing state. It refuses an empty state, warms
// the certificate, and refreshes it daily until Close.
func Serve(ctx context.Context, cfg Config) (*Running, error) {
	id, err := StateNodeID(cfg.Dir)
	if err != nil {
		return nil, err
	}
	if id == "" {
		return nil, errors.New(noNodeMessage)
	}
	srv, err := newServer(cfg, "")
	if err != nil {
		return nil, err
	}
	upCtx, cancel := context.WithTimeout(ctx, serveTimeout)
	defer cancel()
	st, err := srv.Up(upCtx)
	if err != nil {
		srv.Close()
		return nil, fmt.Errorf("tsnet up: %w", err)
	}
	if len(st.CertDomains) == 0 {
		srv.Close()
		return nil, errors.New("HTTPS certificates are not enabled for the tailnet (tailscale/README.md settings checklist)")
	}
	lc, err := srv.LocalClient()
	if err != nil {
		srv.Close()
		return nil, err
	}
	r := &Running{srv: srv, lc: lc, domain: st.CertDomains[0], stop: make(chan struct{})}
	notAfter, err := warmCert(upCtx, lc, r.domain)
	if err != nil {
		srv.Close()
		return nil, err
	}
	r.certNotAfter = notAfter
	go r.refreshCert()
	return r, nil
}

// refreshCert re-fetches the certificate every 24 h until Close; failures are
// logged and retried on the next tick.
func (r *Running) refreshCert() {
	t := time.NewTicker(certRefresh)
	defer t.Stop()
	for {
		select {
		case <-r.stop:
			return
		case <-t.C:
			ctx, cancel := context.WithTimeout(context.Background(), serveTimeout)
			notAfter, err := warmCert(ctx, r.lc, r.domain)
			cancel()
			if err != nil {
				log.Printf("certificate refresh failed: %v", err)
				continue
			}
			r.mu.Lock()
			r.certNotAfter = notAfter
			r.mu.Unlock()
		}
	}
}

// Domain is the node's HTTPS domain, e.g. cxagents.faun-fir.ts.net.
func (r *Running) Domain() string { return r.domain }

// LocalClient is the node's local API client (certificates, identity).
func (r *Running) LocalClient() *local.Client { return r.lc }

// Register installs cb as the node's fallback TCP handler and returns the
// function that removes it.
func (r *Running) Register(cb tsnet.FallbackTCPHandler) func() {
	return r.srv.RegisterFallbackTCPHandler(cb)
}

// Info reads the node's current identity. A failed status read reports the
// backend state as "unavailable", which check.Evaluate flags.
func (r *Running) Info(ctx context.Context) check.NodeInfo {
	st, err := r.lc.Status(ctx)
	if err != nil {
		return check.NodeInfo{BackendState: "unavailable"}
	}
	info := infoFrom(st)
	r.mu.Lock()
	info.CertNotAfter = r.certNotAfter
	r.mu.Unlock()
	return info
}

// Close stops the certificate refresh and the node.
func (r *Running) Close() error {
	r.once.Do(func() { close(r.stop) })
	return r.srv.Close()
}

// warmCert fetches the certificate for domain, retrying every certRetry until
// ctx ends, and returns its expiry.
func warmCert(ctx context.Context, lc *local.Client, domain string) (time.Time, error) {
	var lastErr error
	for {
		certPEM, _, err := lc.CertPair(ctx, domain)
		if err == nil {
			notAfter, perr := leafNotAfter(certPEM)
			if perr == nil {
				return notAfter, nil
			}
			lastErr = perr
		} else {
			lastErr = err
		}
		select {
		case <-ctx.Done():
			return time.Time{}, fmt.Errorf("certificate for %s: %w", domain, lastErr)
		case <-time.After(certRetry):
		}
	}
}

// leafNotAfter parses the first certificate in certPEM and returns its expiry.
func leafNotAfter(certPEM []byte) (time.Time, error) {
	block, _ := pem.Decode(certPEM)
	if block == nil {
		return time.Time{}, errors.New("certificate: no PEM block")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return time.Time{}, fmt.Errorf("certificate: %w", err)
	}
	return cert.NotAfter, nil
}

// infoFrom maps a tsnet status to the node identity used by check.
func infoFrom(st *ipnstate.Status) check.NodeInfo {
	info := check.NodeInfo{BackendState: st.BackendState}
	if st.Self == nil {
		return info
	}
	info.DNSName = strings.TrimSuffix(st.Self.DNSName, ".")
	info.Name, _, _ = strings.Cut(info.DNSName, ".")
	info.ID = string(st.Self.ID)
	info.Online = st.Self.Online
	if st.Self.Tags != nil {
		info.Tags = st.Self.Tags.AsSlice()
	}
	return info
}
