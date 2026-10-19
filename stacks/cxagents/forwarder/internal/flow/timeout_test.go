package flow

import (
	"errors"
	"io"
	"net"
	"os"
	"sync/atomic"
	"testing"
	"time"
)

// gonetTimeout is the error tsnet's *gonet.TCPConn returns at a read deadline:
// it reports Timeout() but does not wrap os.ErrDeadlineExceeded.
type gonetTimeout struct{}

func (gonetTimeout) Error() string   { return "i/o timeout" }
func (gonetTimeout) Timeout() bool   { return true }
func (gonetTimeout) Temporary() bool { return true }

// gonetLikeConn converts deadline errors the way tsnet's connections do.
type gonetLikeConn struct{ net.Conn }

func (c gonetLikeConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	if errors.Is(err, os.ErrDeadlineExceeded) {
		err = gonetTimeout{}
	}
	return n, err
}

// AC6.9 with the connection type tsnet really hands the handler: a flow that
// is silent on both sides must end as "idle", not "closed".
func TestGonetStyleTimeoutIsIdle(t *testing.T) {
	cfg, _ := testTLS(t)
	h, logs := newHandler(cfg, 200*time.Millisecond, nil)
	addr := target(t, func(c net.Conn) { io.Copy(io.Discard, c) })
	srv, _ := tcpPair(t)
	var released atomic.Int32
	serveAsync(t, h, newFlow(gonetLikeConn{srv}, addr, &released))

	if l := waitLog(t, logs); l.outcome != "idle" {
		t.Fatalf("outcome = %s, want idle", l.outcome)
	}
}

// A first read that timed out just before the decision was made carries no
// data, but the bytes behind it must still reach the other side.
func TestPumpTimedOutPendingStillCopiesSource(t *testing.T) {
	src, srcPeer := tcpPair(t)
	dst, dstPeer := tcpPair(t)
	if _, err := srcPeer.Write([]byte("late\n")); err != nil {
		t.Fatal(err)
	}
	srcPeer.Close()

	pump(dst, src, &first{err: gonetTimeout{}}, nil)

	dstPeer.SetReadDeadline(time.Now().Add(5 * time.Second))
	got, err := io.ReadAll(dstPeer)
	if err != nil || string(got) != "late\n" {
		t.Fatalf("destination got %q, %v; want the source's bytes", got, err)
	}
}
