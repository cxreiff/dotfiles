package routes

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseValid(t *testing.T) {
	tab, err := Parse(strings.NewReader(`# cxagents routes

dev-web  1024-3099  -
shell    3100-9999  3100
`))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	rs := tab.Routes()
	if len(rs) != 2 {
		t.Fatalf("got %d routes, want 2", len(rs))
	}
	if rs[0].Target != "dev-web" || rs[0].Line != 3 || rs[1].Target != "shell" || rs[1].Line != 4 {
		t.Fatalf("unexpected routes: %+v", rs)
	}

	r, ok := tab.Lookup(3100)
	if !ok || r.Target != "shell" {
		t.Fatalf("Lookup(3100) = %+v, %v; want shell", r, ok)
	}
	if r.Allowed(3100) {
		t.Errorf("Allowed(3100) = true, want false (denied)")
	}
	if !r.Allowed(4000) {
		t.Errorf("Allowed(4000) = false, want true")
	}
	if _, ok := tab.Lookup(1023); ok {
		t.Errorf("Lookup(1023) found a route, want none (below every range)")
	}
	if r, ok := tab.Lookup(1024); !ok || r.Target != "dev-web" {
		t.Errorf("Lookup(1024) = %+v, %v; want dev-web", r, ok)
	}
}

func TestParseMultiDenyAndGap(t *testing.T) {
	tab, err := Parse(strings.NewReader("a 1024-3000 -\nb 4000-5000 4100,4500\n"))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if _, ok := tab.Lookup(3500); ok {
		t.Errorf("Lookup(3500) found a route in a gap, want none")
	}
	b, ok := tab.Lookup(4500)
	if !ok || b.Target != "b" {
		t.Fatalf("Lookup(4500) = %+v, %v; want b", b, ok)
	}
	if b.Allowed(4500) {
		t.Errorf("Allowed(4500) = true, want false (second denied port)")
	}
	if b.Allowed(4100) {
		t.Errorf("Allowed(4100) = true, want false (first denied port)")
	}
	if b.Allowed(3100) {
		t.Errorf("Allowed(3100) = true, want false (outside the range)")
	}
	if !b.Allowed(4001) {
		t.Errorf("Allowed(4001) = false, want true")
	}
}

func TestParseRoutesSortedByFrom(t *testing.T) {
	tab, err := Parse(strings.NewReader("late 6000-7000 -\nearly 1024-2000 -\n"))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	rs := tab.Routes()
	if len(rs) != 2 || rs[0].Target != "early" || rs[1].Target != "late" {
		t.Fatalf("Routes() not sorted by From: %+v", rs)
	}
}

func TestParseAdjacentRangesAccepted(t *testing.T) {
	tab, err := Parse(strings.NewReader("a 1024-4999 -\nb 5000-6000 -\n"))
	if err != nil {
		t.Fatalf("adjacent ranges rejected: %v", err)
	}
	if r, ok := tab.Lookup(4999); !ok || r.Target != "a" {
		t.Errorf("Lookup(4999) = %+v, %v; want a", r, ok)
	}
	if r, ok := tab.Lookup(5000); !ok || r.Target != "b" {
		t.Errorf("Lookup(5000) = %+v, %v; want b", r, ok)
	}
}

func TestParseRejectsMalformed(t *testing.T) {
	cases := []struct {
		name string
		src  string
		line int
		want string
	}{
		{"too few fields", "a 1024-5000\n", 1, "fields"},
		{"too many fields", "a 1024-5000 - extra\n", 1, "fields"},
		{"from greater than to", "a 5000-4000 -\n", 1, "range"},
		{"port zero", "a 0-10 -\n", 1, "range"},
		{"port above 65535", "a 1-70000 -\n", 1, "range"},
		{"non-numeric range", "a 10-x -\n", 1, "range"},
		{"deny outside range", "a 1024-5000 80\n", 1, "deny"},
		{"deny non-numeric", "a 1024-5000 abc\n", 1, "deny"},
		{"deny empty element", "a 1024-5000 3100,\n", 1, "deny"},
		{"deny zero", "a 1024-5000 0\n", 1, "deny"},
		{"target leading dash", "-bad 1024-5000 -\n", 1, "target"},
		{"target invalid character", "a/b 1024-5000 -\n", 1, "target"},
		{"line number counts comments and blanks", "# c\n\na 1024-5000 -\nb 0-1 -\n", 4, "range"},
		{"overlap names both lines", "a 1024-5000 -\nb 4000-6000 -\n", 2, "overlaps line 1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Parse(strings.NewReader(tc.src))
			if err == nil {
				t.Fatalf("Parse(%q) accepted a malformed file", tc.src)
			}
			prefix := fmt.Sprintf("routes:%d:", tc.line)
			if !strings.HasPrefix(err.Error(), prefix) {
				t.Errorf("error %q does not start with %q", err, prefix)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not contain %q", err, tc.want)
			}
		})
	}
}

func TestLoad(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "routes")
	if err := os.WriteFile(good, []byte("a 1024-5000 -\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	tab, err := Load(good)
	if err != nil {
		t.Fatalf("Load(valid): %v", err)
	}
	if len(tab.Routes()) != 1 {
		t.Fatalf("Load(valid) gave %d routes, want 1", len(tab.Routes()))
	}

	bad := filepath.Join(dir, "bad")
	if err := os.WriteFile(bad, []byte("a 1024-4000 -\nb 3000-5000 -\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(bad); err == nil || !strings.Contains(err.Error(), "overlaps") {
		t.Errorf("Load(overlap) error = %v, want an overlap error", err)
	}

	if _, err := Load(filepath.Join(dir, "missing")); err == nil {
		t.Errorf("Load(missing) returned no error")
	}
}
