package flow

import (
	"crypto/tls"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"
)

type logged struct {
	f       Flow
	mode    string
	outcome string
}

// newHandler builds a Handler whose log lines arrive on the returned channel.
func newHandler(cfg *tls.Config, idle time.Duration, onDialFail func(string)) (*Handler, chan logged) {
	logs := make(chan logged, 8)
	h := &Handler{
		TLS:         cfg,
		IdleFirst:   idle,
		Handshake:   10 * time.Second,
		DialTimeout: 2 * time.Second,
		OnDialFail:  onDialFail,
		Log: func(f Flow, mode, outcome string, _ time.Duration) {
			logs <- logged{f: f, mode: mode, outcome: outcome}
		},
	}
	return h, logs
}

func waitLog(t *testing.T, logs <-chan logged) logged {
	t.Helper()
	select {
	case l := <-logs:
		return l
	case <-time.After(5 * time.Second):
		t.Fatal("no log line from Serve")
		return logged{}
	}
}

// serveAsync runs Serve in a goroutine and checks, at cleanup, that it returned.
func serveAsync(t *testing.T, h *Handler, f Flow) <-chan struct{} {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		h.Serve(f)
	}()
	t.Cleanup(func() {
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("Serve goroutine did not return")
		}
	})
	return done
}

func waitServe(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Serve did not return")
	}
}

// tcpPair returns the server end (handed to Serve) and the client end.
func tcpPair(t *testing.T) (net.Conn, net.Conn) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	type res struct {
		c   net.Conn
		err error
	}
	acc := make(chan res, 1)
	go func() {
		c, err := ln.Accept()
		acc <- res{c, err}
	}()
	cli, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	r := <-acc
	if r.err != nil {
		cli.Close()
		t.Fatal(r.err)
	}
	t.Cleanup(func() { cli.Close(); r.c.Close() })
	return r.c, cli
}

// target starts a loopback listener and runs behave on the first connection.
// behave owns the connection and returns when the test is done with it.
func target(t *testing.T, behave func(c net.Conn)) netip.AddrPort {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		behave(c)
	}()
	return netip.MustParseAddrPort(ln.Addr().String())
}

func echo(c net.Conn) { io.Copy(c, c) }

func newFlow(srv net.Conn, addr netip.AddrPort, released *atomic.Int32) Flow {
	return Flow{
		Conn:    srv,
		Src:     testSrc,
		Port:    addr.Port(),
		Target:  "t",
		Addr:    addr,
		release: func() { released.Add(1) },
	}
}

// pingPong is a target that reads "ping\n" and answers "pong\n".
func pingPong(c net.Conn) {
	buf := make([]byte, 5)
	if _, err := io.ReadFull(c, buf); err == nil {
		c.Write([]byte("pong\n"))
	}
}

func TestEchoClientSpeaksFirst(t *testing.T) {
	cfg, _ := testTLS(t)
	h, logs := newHandler(cfg, time.Minute, nil)
	addr := target(t, echo)
	srv, cli := tcpPair(t)
	var released atomic.Int32
	done := serveAsync(t, h, newFlow(srv, addr, &released))

	if _, err := cli.Write([]byte("hello\n")); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, 6)
	cli.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(cli, got); err != nil || string(got) != "hello\n" {
		t.Fatalf("echo = %q, %v", got, err)
	}
	cli.Close()
	waitServe(t, done)

	l := waitLog(t, logs)
	if l.mode != "raw" || l.outcome != "ok" {
		t.Fatalf("log = %s/%s, want raw/ok", l.mode, l.outcome)
	}
	if n := released.Load(); n != 1 {
		t.Fatalf("release called %d times, want 1", n)
	}
}

func TestBannerServerSpeaksFirst(t *testing.T) {
	cfg, _ := testTLS(t)
	h, logs := newHandler(cfg, time.Minute, nil)
	received := make(chan string, 1)
	addr := target(t, func(c net.Conn) {
		c.Write([]byte("SSH-2.0-test\r\n"))
		buf := make([]byte, 1)
		if _, err := io.ReadFull(c, buf); err == nil {
			received <- string(buf)
		}
	})
	srv, cli := tcpPair(t)
	var released atomic.Int32
	serveAsync(t, h, newFlow(srv, addr, &released))

	cli.SetReadDeadline(time.Now().Add(5 * time.Second))
	banner := make([]byte, len("SSH-2.0-test\r\n"))
	if _, err := io.ReadFull(cli, banner); err != nil || string(banner) != "SSH-2.0-test\r\n" {
		t.Fatalf("banner = %q, %v", banner, err)
	}
	if _, err := cli.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	select {
	case s := <-received:
		if s != "x" {
			t.Fatalf("target got %q, want x", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("target never received client bytes")
	}
	cli.Close() // the flow ends once both directions have finished
	if l := waitLog(t, logs); l.mode != "raw" {
		t.Fatalf("mode = %s, want raw", l.mode)
	}
}

func TestTLSImmediateHandshakeAndHTTP11Only(t *testing.T) {
	cfg, pool := testTLS(t)
	h, logs := newHandler(cfg, time.Minute, nil)
	addr := target(t, pingPong)
	srv, cli := tcpPair(t)
	var released atomic.Int32
	done := serveAsync(t, h, newFlow(srv, addr, &released))

	cli.SetDeadline(time.Now().Add(10 * time.Second))
	tc := tls.Client(cli, &tls.Config{
		ServerName: "cxagents.test",
		RootCAs:    pool,
		NextProtos: []string{"h2", "http/1.1"},
	})
	if err := tc.Handshake(); err != nil {
		t.Fatalf("handshake: %v", err)
	}
	if p := tc.ConnectionState().NegotiatedProtocol; p != "http/1.1" {
		t.Fatalf("ALPN = %q, want http/1.1", p)
	}
	if _, err := tc.Write([]byte("ping\n")); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 5)
	if _, err := io.ReadFull(tc, reply); err != nil || string(reply) != "pong\n" {
		t.Fatalf("reply = %q, %v", reply, err)
	}
	tc.Close()
	waitServe(t, done)
	if l := waitLog(t, logs); l.mode != "tls" || l.outcome != "ok" {
		t.Fatalf("log = %s/%s, want tls/ok", l.mode, l.outcome)
	}
}

// The pre-first-byte cap is 10 s: a stalled first connection must be closed
// quickly so the client retries, but a late ClientHello (AC6.9) must survive.
func TestDefaultIdleFirstIsTenSeconds(t *testing.T) {
	if defaultIdleFirst != 10*time.Second {
		t.Fatalf("defaultIdleFirst = %v, want 10s", defaultIdleFirst)
	}
}

func TestTLSClientHelloArrivingAfterTwoSecondsStillTLS(t *testing.T) {
	cfg, pool := testTLS(t)
	h, logs := newHandler(cfg, defaultIdleFirst, nil) // the real default cap
	addr := target(t, pingPong)
	srv, cli := tcpPair(t)
	var released atomic.Int32
	serveAsync(t, h, newFlow(srv, addr, &released))

	time.Sleep(2 * time.Second) // AC6.9: the ClientHello arrives 2 s after connect
	cli.SetDeadline(time.Now().Add(10 * time.Second))
	tc := tls.Client(cli, &tls.Config{ServerName: "cxagents.test", RootCAs: pool})
	if err := tc.Handshake(); err != nil {
		t.Fatalf("late handshake: %v", err)
	}
	if _, err := tc.Write([]byte("ping\n")); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 5)
	if _, err := io.ReadFull(tc, reply); err != nil || string(reply) != "pong\n" {
		t.Fatalf("reply = %q, %v", reply, err)
	}
	tc.Close()
	if l := waitLog(t, logs); l.mode != "tls" || l.outcome != "ok" {
		t.Fatalf("log = %s/%s, want tls/ok", l.mode, l.outcome)
	}
}

func TestSilentBothSidesIdleCap(t *testing.T) {
	cfg, _ := testTLS(t)
	h, logs := newHandler(cfg, 300*time.Millisecond, nil)
	addr := target(t, func(c net.Conn) { io.Copy(io.Discard, c) })
	srv, cli := tcpPair(t)
	var released atomic.Int32
	start := time.Now()
	done := serveAsync(t, h, newFlow(srv, addr, &released))

	waitServe(t, done)
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("idle close took %v, want about IdleFirst", elapsed)
	}
	cli.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := cli.Read(make([]byte, 1)); err == nil || isTimeout(err) {
		t.Fatalf("client should be closed by the idle cap, got %v", err)
	}
	if l := waitLog(t, logs); l.outcome != "idle" {
		t.Fatalf("outcome = %s, want idle", l.outcome)
	}
}

func TestNoSNIFailsCleanly(t *testing.T) {
	cfg, _ := testTLS(t)
	h, logs := newHandler(cfg, time.Minute, nil)
	addr := target(t, func(c net.Conn) { io.Copy(io.Discard, c) })
	srv, cli := tcpPair(t)
	var released atomic.Int32
	done := serveAsync(t, h, newFlow(srv, addr, &released))

	cli.SetDeadline(time.Now().Add(10 * time.Second))
	tc := tls.Client(cli, &tls.Config{InsecureSkipVerify: true}) // no ServerName: no SNI
	if err := tc.Handshake(); err == nil {
		t.Fatal("handshake without SNI should fail")
	}
	tc.Close()
	waitServe(t, done)
	if l := waitLog(t, logs); l.mode != "tls" || l.outcome != "handshake-error" {
		t.Fatalf("log = %s/%s, want tls/handshake-error", l.mode, l.outcome)
	}
}

func TestRefusedThenServerStartedAfterwards(t *testing.T) {
	cfg, _ := testTLS(t)
	var failed []string
	h, logs := newHandler(cfg, time.Minute, func(tg string) { failed = append(failed, tg) })

	// Reserve a loopback port, then release it so nothing listens there.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := netip.MustParseAddrPort(ln.Addr().String())
	ln.Close()

	srv, cli := tcpPair(t)
	var released atomic.Int32
	done := serveAsync(t, h, newFlow(srv, addr, &released))

	cli.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, err = cli.Read(make([]byte, 1))
	if err == nil || isTimeout(err) {
		t.Fatalf("client should be reset or closed promptly, got %v", err)
	}
	waitServe(t, done)
	if l := waitLog(t, logs); l.outcome != "refused" {
		t.Fatalf("outcome = %s, want refused", l.outcome)
	}
	if len(failed) != 1 || failed[0] != "t" {
		t.Fatalf("OnDialFail calls = %v, want [t]", failed)
	}

	// A server started afterwards on the same port is reachable at once.
	ln2, err := net.Listen("tcp", addr.String())
	if err != nil {
		t.Skipf("port %v not reusable here: %v", addr, err)
	}
	t.Cleanup(func() { ln2.Close() })
	go func() {
		c, err := ln2.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		echo(c)
	}()
	srv2, cli2 := tcpPair(t)
	done2 := serveAsync(t, h, newFlow(srv2, addr, &released))
	cli2.SetDeadline(time.Now().Add(5 * time.Second))
	cli2.Write([]byte("hi\n"))
	got := make([]byte, 3)
	if _, err := io.ReadFull(cli2, got); err != nil || string(got) != "hi\n" {
		t.Fatalf("second flow echo = %q, %v", got, err)
	}
	cli2.Close()
	waitServe(t, done2)
	if l := waitLog(t, logs); l.outcome != "ok" {
		t.Fatalf("second outcome = %s, want ok", l.outcome)
	}
}

func TestHalfCloseClientWriteSideReachesTarget(t *testing.T) {
	cfg, _ := testTLS(t)
	h, logs := newHandler(cfg, time.Minute, nil)
	seen := make(chan string, 1)
	addr := target(t, func(c net.Conn) {
		all, _ := io.ReadAll(c) // returns only once the client's FIN arrives
		seen <- string(all)
		c.Write([]byte("bye\n"))
	})
	srv, cli := tcpPair(t)
	var released atomic.Int32
	done := serveAsync(t, h, newFlow(srv, addr, &released))

	cli.SetDeadline(time.Now().Add(10 * time.Second))
	cli.Write([]byte("hi\n"))
	cli.(*net.TCPConn).CloseWrite()
	select {
	case s := <-seen:
		if s != "hi\n" {
			t.Fatalf("target read %q, want hi\\n", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("target never saw client EOF")
	}
	reply, err := io.ReadAll(cli)
	if err != nil || string(reply) != "bye\n" {
		t.Fatalf("client reply = %q, %v", reply, err)
	}
	waitServe(t, done)
	if l := waitLog(t, logs); l.outcome != "ok" {
		t.Fatalf("outcome = %s, want ok", l.outcome)
	}
}

func TestClientEOFBeforeAnyByteThenBannerStillDelivered(t *testing.T) {
	cfg, _ := testTLS(t)
	h, logs := newHandler(cfg, 5*time.Second, nil)
	signal := make(chan struct{})
	addr := target(t, func(c net.Conn) {
		<-signal
		c.Write([]byte("SSH-2.0-late\r\n"))
	})
	srv, cli := tcpPair(t)
	var released atomic.Int32
	serveAsync(t, h, newFlow(srv, addr, &released))

	cli.(*net.TCPConn).CloseWrite() // client ends its side before sending anything
	close(signal)
	cli.SetReadDeadline(time.Now().Add(5 * time.Second))
	banner := make([]byte, len("SSH-2.0-late\r\n"))
	if _, err := io.ReadFull(cli, banner); err != nil || string(banner) != "SSH-2.0-late\r\n" {
		t.Fatalf("banner after client half-close = %q, %v", banner, err)
	}
	if l := waitLog(t, logs); l.mode != "raw" || l.outcome != "ok" {
		t.Fatalf("log = %s/%s, want raw/ok", l.mode, l.outcome)
	}
}

func TestTargetEOFBeforeAnyByteClosesClientPromptly(t *testing.T) {
	cfg, _ := testTLS(t)
	h, logs := newHandler(cfg, 300*time.Millisecond, nil)
	addr := target(t, func(c net.Conn) {}) // accepts, then closes at once
	srv, cli := tcpPair(t)
	var released atomic.Int32
	done := serveAsync(t, h, newFlow(srv, addr, &released))

	waitServe(t, done)
	cli.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := cli.Read(make([]byte, 1)); err == nil || isTimeout(err) {
		t.Fatalf("client should be closed, got %v", err)
	}
	if l := waitLog(t, logs); l.outcome != "closed" {
		t.Fatalf("outcome = %s, want closed", l.outcome)
	}
}

func TestNoIdleCapAfterFirstByte(t *testing.T) {
	cfg, _ := testTLS(t)
	h, logs := newHandler(cfg, 300*time.Millisecond, nil)
	addr := target(t, echo)
	srv, cli := tcpPair(t)
	var released atomic.Int32
	serveAsync(t, h, newFlow(srv, addr, &released))

	cli.SetDeadline(time.Now().Add(10 * time.Second))
	cli.Write([]byte("x"))
	buf := make([]byte, 1)
	if _, err := io.ReadFull(cli, buf); err != nil {
		t.Fatal(err)
	}
	time.Sleep(time.Second) // well past IdleFirst; the live socket must survive
	cli.Write([]byte("y"))
	if _, err := io.ReadFull(cli, buf); err != nil || buf[0] != 'y' {
		t.Fatalf("second exchange = %q, %v; flow was cut by the idle cap", buf, err)
	}
	cli.Close()
	if l := waitLog(t, logs); l.outcome != "ok" {
		t.Fatalf("outcome = %s, want ok", l.outcome)
	}
}
