package node

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"time"

	"tailnet-forwarder/internal/check"
)

// checkPath is the only route on the check socket.
const checkPath = "/check"

// ServeCheck serves GET /check on a unix socket at path until ctx ends. The
// socket is mode 0600 and replaces any stale file at path; it is removed on
// shutdown. info is called per request to read the node's current identity.
func ServeCheck(ctx context.Context, path string, info func(context.Context) check.NodeInfo) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("check socket: remove stale %s: %w", path, err)
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		return fmt.Errorf("check socket: %w", err)
	}
	defer os.Remove(path)
	if err := os.Chmod(path, 0600); err != nil {
		ln.Close()
		return fmt.Errorf("check socket: chmod: %w", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET "+checkPath, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(info(r.Context())); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}

	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	select {
	case err := <-errc:
		return fmt.Errorf("check socket: %w", err)
	case <-ctx.Done():
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("check socket: shutdown: %w", err)
	}
	if err := <-errc; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("check socket: %w", err)
	}
	return nil
}

// FetchCheck asks the forwarder listening on the check socket at path for its
// node identity. Any failure (no socket, refused, bad reply) is an error.
func FetchCheck(path string) (check.NodeInfo, error) {
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", path)
			},
		},
	}
	resp, err := client.Get("http://forwarder" + checkPath)
	if err != nil {
		return check.NodeInfo{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return check.NodeInfo{}, fmt.Errorf("check socket: HTTP %d", resp.StatusCode)
	}
	var info check.NodeInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return check.NodeInfo{}, fmt.Errorf("check socket: decode: %w", err)
	}
	return info, nil
}
