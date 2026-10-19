package status

import (
	"encoding/json"
	"net/http"
	"testing"
)

// A target with several routes keeps "range" as its first route and lists
// every route under "ranges"; "range" never claims the gap between routes.
func TestJSONListsEveryRouteOfATarget(t *testing.T) {
	f := newFakeNet([]uint16{20001, 30001}, nil)
	s, _ := newTestServer(t, "t1 20000-20009 -\nt1 30000-30009 30002\n", fakeTargets{"t1": {addr("10.0.0.5")}}, f)

	rec := get(s, "10.0.0.5", "/status?format=json")
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d", rec.Code)
	}
	var out struct {
		Range  jsonRange   `json:"range"`
		Ranges []jsonRange `json:"ranges"`
		Deny   []uint16    `json:"deny"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("json: %v", err)
	}
	if out.Range != (jsonRange{From: 20000, To: 20009}) {
		t.Fatalf("range = %+v, want the first route 20000-20009", out.Range)
	}
	want := []jsonRange{{From: 20000, To: 20009}, {From: 30000, To: 30009}}
	if len(out.Ranges) != len(want) || out.Ranges[0] != want[0] || out.Ranges[1] != want[1] {
		t.Fatalf("ranges = %+v, want %+v", out.Ranges, want)
	}
	if len(out.Deny) != 1 || out.Deny[0] != 30002 {
		t.Fatalf("deny = %v, want [30002]", out.Deny)
	}
}
