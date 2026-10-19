package node

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"tailnet-forwarder/internal/check"
)

func TestCheckSocketRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "forwarder.sock")
	// A stale regular file at the socket path must be replaced, not reused.
	if err := os.WriteFile(path, []byte("stale"), 0600); err != nil {
		t.Fatal(err)
	}
	want := check.NodeInfo{
		Name:         "cxagents",
		DNSName:      "cxagents.faun-fir.ts.net",
		ID:           "nXYZ",
		Tags:         []string{"tag:cxagents"},
		Online:       true,
		BackendState: "Running",
		CertNotAfter: time.Date(2027, 1, 15, 0, 0, 0, 0, time.UTC),
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	served := make(chan error, 1)
	go func() {
		served <- ServeCheck(ctx, path, func(context.Context) check.NodeInfo { return want })
	}()

	var got check.NodeInfo
	var err error
	for i := 0; i < 100; i++ {
		got, err = FetchCheck(path)
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("FetchCheck: %v", err)
	}

	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if mode := fi.Mode().Perm(); mode != 0600 {
		t.Errorf("socket mode = %v, want 0600", mode)
	}
	if !got.CertNotAfter.Equal(want.CertNotAfter) {
		t.Fatalf("CertNotAfter = %v, want %v", got.CertNotAfter, want.CertNotAfter)
	}
	got.CertNotAfter = want.CertNotAfter
	if !reflect.DeepEqual(got, want) {
		t.Errorf("FetchCheck = %+v, want %+v", got, want)
	}

	cancel()
	select {
	case err := <-served:
		if err != nil {
			t.Errorf("ServeCheck returned %v after cancel, want nil", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("ServeCheck did not return after cancel")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("socket still present after shutdown: %v", err)
	}
}

func TestFetchCheckWithoutServer(t *testing.T) {
	path := filepath.Join(t.TempDir(), "none.sock")
	if _, err := FetchCheck(path); err == nil {
		t.Fatal("FetchCheck with no server: want error, got nil")
	}
}
