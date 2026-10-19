// Package routes parses the forwarder's routes table: which target container
// is reachable on which port range, and which ports within it are denied.
//
// File format: `#` comments and blank lines are ignored; every other line is
// `TARGET FROM-TO DENY`, where DENY is `-` or a comma-separated list of ports.
package routes

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Route maps a port range on the forwarder to one target container.
type Route struct {
	Target   string
	From, To uint16
	Deny     map[uint16]bool
	Line     int
}

// Table is a parsed routes file. Its ranges are sorted by From and disjoint.
type Table struct{ routes []Route }

var targetRE = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)

// Parse reads a routes table. Every error is prefixed `routes:LINE:`.
func Parse(r io.Reader) (*Table, error) {
	var rs []Route
	sc := bufio.NewScanner(r)
	line := 0
	for sc.Scan() {
		line++
		text := sc.Text()
		if i := strings.IndexByte(text, '#'); i >= 0 {
			text = text[:i]
		}
		fields := strings.Fields(text)
		if len(fields) == 0 {
			continue
		}
		rt, err := parseLine(line, fields)
		if err != nil {
			return nil, err
		}
		rs = append(rs, rt)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("routes: %w", err)
	}
	sort.SliceStable(rs, func(i, j int) bool { return rs[i].From < rs[j].From })
	// Sorted by From, consecutive disjointness implies full disjointness.
	for i := 1; i < len(rs); i++ {
		prev, cur := rs[i-1], rs[i]
		if cur.From <= prev.To {
			return nil, fmt.Errorf("routes:%d: range %d-%d overlaps line %d (%d-%d)",
				cur.Line, cur.From, cur.To, prev.Line, prev.From, prev.To)
		}
	}
	return &Table{routes: rs}, nil
}

// Load parses the routes file at path.
func Load(path string) (*Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return Parse(f)
}

func parseLine(line int, f []string) (Route, error) {
	if len(f) != 3 {
		return Route{}, fmt.Errorf("routes:%d: want 3 fields (target FROM-TO DENY), got %d", line, len(f))
	}
	target := f[0]
	if !targetRE.MatchString(target) {
		return Route{}, fmt.Errorf("routes:%d: invalid target %q (letters, digits, '_', '.', '-'; start with a letter or digit)", line, target)
	}
	from, to, err := parseRange(f[1])
	if err != nil {
		return Route{}, fmt.Errorf("routes:%d: range %q: %v", line, f[1], err)
	}
	deny := map[uint16]bool{}
	if f[2] != "-" {
		for _, s := range strings.Split(f[2], ",") {
			p, err := parsePort(s)
			if err != nil {
				return Route{}, fmt.Errorf("routes:%d: deny %q: %v", line, f[2], err)
			}
			if p < from || p > to {
				return Route{}, fmt.Errorf("routes:%d: deny port %d is outside its range %d-%d", line, p, from, to)
			}
			deny[p] = true
		}
	}
	return Route{Target: target, From: from, To: to, Deny: deny, Line: line}, nil
}

func parseRange(s string) (uint16, uint16, error) {
	lo, hi, ok := strings.Cut(s, "-")
	if !ok {
		return 0, 0, fmt.Errorf("want FROM-TO")
	}
	from, err := parsePort(lo)
	if err != nil {
		return 0, 0, err
	}
	to, err := parsePort(hi)
	if err != nil {
		return 0, 0, err
	}
	if from > to {
		return 0, 0, fmt.Errorf("FROM %d is greater than TO %d", from, to)
	}
	return from, to, nil
}

func parsePort(s string) (uint16, error) {
	n, err := strconv.ParseUint(s, 10, 16)
	if err != nil || n == 0 {
		return 0, fmt.Errorf("%q is not a port 1-65535", s)
	}
	return uint16(n), nil
}

// Lookup returns the route whose range contains port, if any.
func (t *Table) Lookup(port uint16) (Route, bool) {
	i := sort.Search(len(t.routes), func(i int) bool { return t.routes[i].From > port }) - 1
	if i >= 0 && port <= t.routes[i].To {
		return t.routes[i], true
	}
	return Route{}, false
}

// Allowed reports whether port is inside the route's range and not denied.
func (r Route) Allowed(port uint16) bool {
	return port >= r.From && port <= r.To && !r.Deny[port]
}

// Routes returns a copy of the table's routes, sorted by From.
func (t *Table) Routes() []Route {
	return append([]Route(nil), t.routes...)
}
