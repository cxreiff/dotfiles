package node

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// writeState writes a tailscaled.state fixture into dir. Values are []byte,
// so json.Marshal base64-encodes them exactly as tailscaled does.
func writeState(t *testing.T, dir string, entries map[string][]byte) {
	t.Helper()
	b, err := json.Marshal(entries)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "tailscaled.state"), b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// TestStateNodeIDFromWellFormedState uses the layout tailscaled actually writes
// (ipn/ipnlocal/profiles.go): _current-profile holds the profile's StateKey, and
// _profiles is keyed by ProfileID with ipn.LoginProfile values (no json tags).
func TestStateNodeIDFromWellFormedState(t *testing.T) {
	dir := t.TempDir()
	writeState(t, dir, map[string][]byte{
		"_current-profile": []byte("profile-abcd"),
		"_profiles":        []byte(`{"abcd":{"ID":"abcd","Name":"cxagents","Key":"profile-abcd","NodeID":"nXYZ"}}`),
	})
	id, err := StateNodeID(dir)
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if id != "nXYZ" {
		t.Fatalf("id = %q, want nXYZ", id)
	}
}

func TestStateNodeIDEmptyCases(t *testing.T) {
	cases := map[string]map[string][]byte{
		"empty profiles": {
			"_current-profile": []byte("abcd"),
			"_profiles":        []byte(`{}`),
		},
		"missing current profile": {
			"_profiles": []byte(`{"abcd":{"NodeID":"nXYZ"}}`),
		},
		"current profile not in profiles": {
			"_current-profile": []byte("zzzz"),
			"_profiles":        []byte(`{"abcd":{"ID":"abcd","Key":"profile-abcd","NodeID":"nXYZ"}}`),
		},
		"current key matches no profile": {
			"_current-profile": []byte("profile-zzzz"),
			"_profiles":        []byte(`{"abcd":{"ID":"abcd","Key":"profile-abcd","NodeID":"nXYZ"}}`),
		},
		"missing profiles": {
			"_current-profile": []byte("abcd"),
		},
	}
	for name, entries := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			writeState(t, dir, entries)
			id, err := StateNodeID(dir)
			if err != nil {
				t.Fatalf("err = %v, want nil", err)
			}
			if id != "" {
				t.Fatalf("id = %q, want empty", id)
			}
		})
	}
}

func TestStateNodeIDMissingFileIsEmptyNotError(t *testing.T) {
	id, err := StateNodeID(t.TempDir())
	if err != nil {
		t.Fatalf("err = %v, want nil", err)
	}
	if id != "" {
		t.Fatalf("id = %q, want empty", id)
	}
}

func TestStateNodeIDCorruptFileIsError(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "tailscaled.state"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := StateNodeID(dir); err == nil {
		t.Fatal("corrupt state file: err = nil, want error")
	}
}

func TestStateNodeIDCorruptProfilesIsError(t *testing.T) {
	dir := t.TempDir()
	writeState(t, dir, map[string][]byte{
		"_current-profile": []byte("abcd"),
		"_profiles":        []byte(`{bad`),
	})
	if _, err := StateNodeID(dir); err == nil {
		t.Fatal("corrupt _profiles: err = nil, want error")
	}
}
