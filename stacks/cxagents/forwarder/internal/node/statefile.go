// Package node holds the forwarder's tsnet wiring. This file reads node
// identity from the state directory without starting tsnet.
package node

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

const stateFile = "tailscaled.state"

// StateNodeID returns the node ID of the current profile in dir's
// tailscaled.state, or "" when there is no node yet: no state file, no
// current profile, or no matching profile entry. Unparseable state is an error.
//
// The file is a JSON object of byte values (base64 on disk), as written by
// tailscaled (ipn/ipnlocal/profiles.go). `_current-profile` holds the profile's
// StateKey (e.g. "profile-860c"), not its ProfileID. `_profiles` is keyed by
// ProfileID and its values are ipn.LoginProfile objects (no json tags, so field
// names are as-is): `Key` is the StateKey and `NodeID` the node.
func StateNodeID(dir string) (string, error) {
	b, err := os.ReadFile(filepath.Join(dir, stateFile))
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	var entries map[string][]byte
	if err := json.Unmarshal(b, &entries); err != nil {
		return "", fmt.Errorf("%s: %w", stateFile, err)
	}
	cur := entries["_current-profile"]
	if len(cur) == 0 {
		return "", nil
	}
	raw := entries["_profiles"]
	if len(raw) == 0 {
		return "", nil
	}
	var profiles map[string]struct {
		Key    string
		NodeID string
	}
	if err := json.Unmarshal(raw, &profiles); err != nil {
		return "", fmt.Errorf("%s: _profiles: %w", stateFile, err)
	}
	for _, p := range profiles {
		if p.Key == string(cur) {
			return p.NodeID, nil
		}
	}
	return "", nil
}
