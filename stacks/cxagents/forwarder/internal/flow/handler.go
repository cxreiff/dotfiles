package flow

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/netip"
	"sync"
	"time"
)

// Handler serves accepted flows. Serve runs in its own goroutine (started by
// Decider), so it may dial and block. It always releases the flow's slot and
// closes both connections before returning.
type Handler struct {
	Dial        func(ctx context.Context, addr netip.AddrPort) (net.Conn, error) // default: net.Dialer
	DialTimeout time.Duration                                                    // default 2 s
	IdleFirst   time.Duration                                                    // default 10 s: pre-first-byte cap, both sides silent
	Handshake   time.Duration                                                    // default 10 s: TLS handshake deadline
	TLS         *tls.Config                                                      // GetCertificate from tsnet; ALPN http/1.1 only
	OnDialFail  func(target string)                                              // e.g. resolver.Refresh
	// WhoIs names the source node, called with a 1 s timeout. An empty
	// answer or nil WhoIs logs the source ip:port instead.
	WhoIs func(ctx context.Context, src netip.AddrPort) string
	// Log gets exactly one line per flow: mode is tls, raw or "-"; outcome is
	// ok, refused, idle, closed or handshake-error.
	Log func(f Flow, mode, outcome string, d time.Duration)
}

const (
	defaultDialTimeout = 2 * time.Second
	defaultIdleFirst   = 10 * time.Second
	defaultHandshake   = 10 * time.Second
	whoIsTimeout       = time.Second
	readChunk          = 4096
)

// Serve terminates or splices one accepted flow.
func (h *Handler) Serve(f Flow) {
	start := time.Now()
	mode, outcome := h.serve(f)
	f.Release()
	f.Node = h.whoIs(f.Src)
	if h.Log != nil {
		h.Log(f, mode, outcome, time.Since(start))
	}
}

// first is the result of the first Read on one side.
type first struct {
	buf []byte
	err error
}

func (h *Handler) serve(f Flow) (mode, outcome string) {
	client := f.Conn

	ctx, cancel := context.WithTimeout(context.Background(), orDefault(h.DialTimeout, defaultDialTimeout))
	target, err := h.dial(ctx, f.Addr)
	cancel()
	if err != nil {
		if h.OnDialFail != nil {
			h.OnDialFail(f.Target)
		}
		reset(client)
		return "-", "refused"
	}

	// First-byte race. Deadlines are set before the reads start, so an idle
	// flow ends at IdleFirst on both sides.
	idle := orDefault(h.IdleFirst, defaultIdleFirst)
	client.SetReadDeadline(time.Now().Add(idle))
	target.SetReadDeadline(time.Now().Add(idle))
	clientCh := make(chan first, 1)
	targetCh := make(chan first, 1)
	go readFirst(client, clientCh)
	go readFirst(target, targetCh)

	var got [2]*first // index 0 client, 1 target; nil until that side has reported
	winner := -1
	for winner < 0 && (got[0] == nil || got[1] == nil) {
		select {
		case r := <-clientCh:
			got[0] = &r
		case r := <-targetCh:
			got[1] = &r
		}
		for i := range got {
			if got[i] != nil && len(got[i].buf) > 0 {
				winner = i
				break
			}
		}
	}

	if winner < 0 {
		// Neither side sent a byte. A side that ended is "closed"; both
		// sides merely silent until the cap is "idle".
		closeAll(client, target)
		if isTimeout(got[0].err) && isTimeout(got[1].err) {
			return "-", "idle"
		}
		return "-", "closed"
	}

	// A decision was made: nothing may time out from here on. Clearing the
	// loser's deadline lets its pending Read wait for data or EOF.
	client.SetDeadline(time.Time{})
	target.SetDeadline(time.Time{})

	// A nil first means that side has not reported yet; its pump waits on the channel.
	clientSide := net.Conn(client)
	clientFirst := got[0]
	targetFirst := got[1]

	mode = "raw"
	if winner == 0 && isTLSHello(got[0].buf) {
		mode = "tls"
		client.SetDeadline(time.Now().Add(orDefault(h.Handshake, defaultHandshake)))
		tc := tls.Server(&prefixConn{Conn: client, prefix: got[0].buf}, h.TLS)
		if err := tc.Handshake(); err != nil {
			closeAll(client, target)
			return mode, "handshake-error"
		}
		client.SetDeadline(time.Time{})
		clientSide = tc
		clientFirst = &first{} // the hello bytes are inside the TLS stream now
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		if err := pump(target, clientSide, clientFirst, clientCh); err != nil {
			closeAll(client, target) // one broken direction ends the flow
		}
	}()
	go func() {
		defer wg.Done()
		if err := pump(clientSide, target, targetFirst, targetCh); err != nil {
			closeAll(client, target)
		}
	}()
	wg.Wait()
	closeAll(client, target)
	return mode, "ok"
}

// pump moves one direction: the side's first result (waited for on ch if it
// has not arrived), then io.Copy. The destination is half-closed when the
// source ends. A first read that timed out before the decision carries no
// data, so it is treated like "no error yet" and the copy still runs.
func pump(dst, src net.Conn, pending *first, ch <-chan first) error {
	if pending == nil {
		r := <-ch
		pending = &r
	}
	if len(pending.buf) > 0 {
		if _, err := dst.Write(pending.buf); err != nil {
			return err
		}
	}
	if pending.err == nil || isTimeout(pending.err) {
		if _, err := io.Copy(dst, src); err != nil {
			return err
		}
	}
	halfClose(dst)
	return nil
}

func (h *Handler) dial(ctx context.Context, addr netip.AddrPort) (net.Conn, error) {
	if h.Dial != nil {
		return h.Dial(ctx, addr)
	}
	var d net.Dialer
	return d.DialContext(ctx, "tcp", addr.String())
}

func (h *Handler) whoIs(src netip.AddrPort) string {
	if h.WhoIs == nil {
		return src.String()
	}
	ctx, cancel := context.WithTimeout(context.Background(), whoIsTimeout)
	defer cancel()
	if name := h.WhoIs(ctx, src); name != "" {
		return name
	}
	return src.String()
}

func readFirst(c net.Conn, ch chan<- first) {
	buf := make([]byte, readChunk)
	n, err := c.Read(buf)
	ch <- first{buf: buf[:n], err: err}
}

// isTLSHello reports whether the first bytes look like a TLS handshake record.
func isTLSHello(b []byte) bool {
	return len(b) > 0 && b[0] == 0x16 && (len(b) == 1 || b[1] == 0x03)
}

// isTimeout reports whether err is a deadline expiry. It asks for net.Error
// rather than os.ErrDeadlineExceeded: tsnet's connections (gonet) report a
// deadline as a net.Error whose Timeout() is true without wrapping that value.
func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

// reset makes the close a RST where the connection type allows it.
func reset(c net.Conn) {
	if tc, ok := c.(interface{ SetLinger(int) error }); ok {
		tc.SetLinger(0)
	}
	c.Close()
}

func closeAll(conns ...net.Conn) {
	for _, c := range conns {
		c.Close()
	}
}

// halfClose sends FIN on the write side. For TLS it sends close_notify and
// then half-closes the TCP connection underneath.
func halfClose(c net.Conn) {
	if tc, ok := c.(*tls.Conn); ok {
		tc.CloseWrite()
		c = tc.NetConn()
	}
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		cw.CloseWrite()
	}
}

// prefixConn replays bytes already read from the client (the TLS hello)
// before reading the connection itself.
type prefixConn struct {
	net.Conn
	prefix []byte
}

func (p *prefixConn) Read(b []byte) (int, error) {
	if len(p.prefix) > 0 {
		n := copy(b, p.prefix)
		p.prefix = p.prefix[n:]
		return n, nil
	}
	return p.Conn.Read(b)
}

func (p *prefixConn) CloseWrite() error {
	if cw, ok := p.Conn.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}
	return nil
}

func orDefault[T ~int64](v, def T) T {
	if v <= 0 {
		return def
	}
	return v
}
