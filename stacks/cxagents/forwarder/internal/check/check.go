// Package check judges the forwarder's tailnet identity: whether the node is
// running, named and tagged as expected, online, and holding a certificate
// that stays valid for more than two weeks.
package check

import (
	"fmt"
	"slices"
	"strings"
	"time"
)

// NodeInfo is the forwarder's own view of its tailnet node. It is served over
// the check socket and printed by `check`.
type NodeInfo struct {
	Name         string    `json:"name"`
	DNSName      string    `json:"dns_name"`
	ID           string    `json:"id"`
	Tags         []string  `json:"tags"`
	Online       bool      `json:"online"`
	BackendState string    `json:"backend_state"`
	CertNotAfter time.Time `json:"cert_not_after"`
}

const (
	day         = 24 * time.Hour
	certMinLife = 14 * day
)

// Evaluate returns one problem per defect. A healthy node returns none.
// The node's name is the first label of its DNS name.
func Evaluate(info NodeInfo, wantHost, wantTag string, now time.Time) []string {
	var problems []string
	if info.BackendState != "Running" {
		problems = append(problems, fmt.Sprintf("backend state is %s, not Running (see login)", info.BackendState))
	}
	name, _, _ := strings.Cut(info.DNSName, ".")
	if name != wantHost {
		problems = append(problems, fmt.Sprintf("node is named %s, not %s (stale device? see login)", name, wantHost))
	}
	if !slices.Equal(info.Tags, []string{wantTag}) {
		problems = append(problems, fmt.Sprintf("tags are [%s], want exactly [%s]", strings.Join(info.Tags, ", "), wantTag))
	}
	if !info.Online {
		problems = append(problems, "node is offline")
	}
	switch {
	case info.CertNotAfter.IsZero():
		problems = append(problems, "no certificate on file")
	case !info.CertNotAfter.After(now.Add(certMinLife)):
		problems = append(problems, fmt.Sprintf("cert expires in %d days; must be more than 14", daysUntil(info.CertNotAfter, now)))
	}
	return problems
}

// Format renders the human summary: node, id, tags, online and cert lines.
func Format(info NodeInfo, now time.Time) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%-8s%s (%s)\n", "node:", info.Name, info.DNSName)
	fmt.Fprintf(&b, "%-8s%s\n", "id:", info.ID)
	tags := "(none)"
	if len(info.Tags) > 0 {
		tags = strings.Join(info.Tags, ", ")
	}
	fmt.Fprintf(&b, "%-8s%s\n", "tags:", tags)
	online := "no"
	if info.Online {
		online = "yes"
	}
	fmt.Fprintf(&b, "%-8s%s\n", "online:", online)
	cert := "none"
	if !info.CertNotAfter.IsZero() {
		cert = fmt.Sprintf("expires %s (%d days)", info.CertNotAfter.UTC().Format("2006-01-02"), daysUntil(info.CertNotAfter, now))
	}
	fmt.Fprintf(&b, "%-8s%s\n", "cert:", cert)
	return b.String()
}

// daysUntil is the whole number of days from now to t (negative once past).
func daysUntil(t, now time.Time) int {
	return int(t.Sub(now) / day)
}
