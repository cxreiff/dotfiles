package check

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

var now = time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)

func good() NodeInfo {
	return NodeInfo{
		Name:         "cxagents",
		DNSName:      "cxagents.faun-fir.ts.net.",
		ID:           "nXYZ",
		Tags:         []string{"tag:cxagents"},
		Online:       true,
		BackendState: "Running",
		CertNotAfter: now.Add(90 * day),
	}
}

func TestEvaluateAllGoodHasNoProblems(t *testing.T) {
	if got := Evaluate(good(), "cxagents", "tag:cxagents", now); len(got) != 0 {
		t.Fatalf("problems = %q, want none", got)
	}
}

func TestEvaluateEachSingleDefectIsOneProblem(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*NodeInfo)
		want   string
	}{
		{"renamed", func(n *NodeInfo) {
			n.Name = "cxagents-1"
			n.DNSName = "cxagents-1.faun-fir.ts.net."
		}, "cxagents-1"},
		{"untagged", func(n *NodeInfo) { n.Tags = nil }, "tag"},
		{"extra tag", func(n *NodeInfo) { n.Tags = []string{"tag:cxagents", "tag:other"} }, "tag"},
		{"offline", func(n *NodeInfo) { n.Online = false }, "offline"},
		{"cert 14 days", func(n *NodeInfo) { n.CertNotAfter = now.Add(14 * day) }, "cert"},
		{"cert 13 days", func(n *NodeInfo) { n.CertNotAfter = now.Add(13 * day) }, "cert"},
		{"zero cert", func(n *NodeInfo) { n.CertNotAfter = time.Time{} }, "cert"},
		{"needs login", func(n *NodeInfo) { n.BackendState = "NeedsLogin" }, "NeedsLogin"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			n := good()
			c.mutate(&n)
			got := Evaluate(n, "cxagents", "tag:cxagents", now)
			if len(got) != 1 {
				t.Fatalf("problems = %q, want exactly one", got)
			}
			if !strings.Contains(got[0], c.want) {
				t.Fatalf("problem %q does not mention %q", got[0], c.want)
			}
		})
	}
}

func TestEvaluateCertBoundaryAboveFourteenDaysIsFine(t *testing.T) {
	n := good()
	n.CertNotAfter = now.Add(15 * day)
	if got := Evaluate(n, "cxagents", "tag:cxagents", now); len(got) != 0 {
		t.Fatalf("15-day cert: problems = %q, want none", got)
	}
}

func TestEvaluateRenamedNodeMessageNamesBothNames(t *testing.T) {
	n := good()
	n.Name = "cxagents-1"
	n.DNSName = "cxagents-1.faun-fir.ts.net."
	got := Evaluate(n, "cxagents", "tag:cxagents", now)
	want := "node is named cxagents-1, not cxagents (stale device? see login)"
	if len(got) != 1 || got[0] != want {
		t.Fatalf("problems = %q, want [%q]", got, want)
	}
}

func TestFormatGoldenLines(t *testing.T) {
	want := "node:   cxagents (cxagents.faun-fir.ts.net.)\n" +
		"id:     nXYZ\n" +
		"tags:   tag:cxagents\n" +
		"online: yes\n" +
		"cert:   expires 2027-01-16 (90 days)\n"
	if got := Format(good(), now); got != want {
		t.Fatalf("Format =\n%s\nwant\n%s", got, want)
	}
}

func TestFormatEmptyAndZeroFields(t *testing.T) {
	n := good()
	n.Tags = nil
	n.Online = false
	n.CertNotAfter = time.Time{}
	want := "node:   cxagents (cxagents.faun-fir.ts.net.)\n" +
		"id:     nXYZ\n" +
		"tags:   (none)\n" +
		"online: no\n" +
		"cert:   none\n"
	if got := Format(n, now); got != want {
		t.Fatalf("Format =\n%s\nwant\n%s", got, want)
	}
}

func TestNodeInfoJSONRoundTrip(t *testing.T) {
	in := good()
	b, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	var out NodeInfo
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	if out.Name != in.Name || out.DNSName != in.DNSName || out.ID != in.ID ||
		out.Online != in.Online || out.BackendState != in.BackendState ||
		!out.CertNotAfter.Equal(in.CertNotAfter) || len(out.Tags) != 1 || out.Tags[0] != "tag:cxagents" {
		t.Fatalf("round trip changed the value: %+v", out)
	}
}
