package netcheck

import (
	"net/netip"
	"testing"
)

func TestInside(t *testing.T) {
	subnet := netip.MustParsePrefix("172.30.0.0/16")
	cases := []struct {
		addr string
		want bool
	}{
		{"172.30.0.5", true},
		{"172.30.255.254", true},
		{"172.19.0.5", false},
		{"172.31.0.1", false},
		{"10.0.0.1", false},
	}
	for _, c := range cases {
		if got := Inside(subnet, netip.MustParseAddr(c.addr)); got != c.want {
			t.Errorf("Inside(%v, %s) = %v, want %v", subnet, c.addr, got, c.want)
		}
	}
}

func TestPick(t *testing.T) {
	one := netip.MustParsePrefix("172.30.0.7/16")
	two := netip.MustParsePrefix("10.0.0.2/24")

	t.Run("none is an error", func(t *testing.T) {
		if _, _, err := pick(nil); err == nil {
			t.Fatal("want error for zero candidates")
		}
	})
	t.Run("one candidate yields address and masked subnet", func(t *testing.T) {
		addr, subnet, err := pick([]netip.Prefix{one})
		if err != nil {
			t.Fatal(err)
		}
		if addr != netip.MustParseAddr("172.30.0.7") {
			t.Errorf("addr = %v", addr)
		}
		if subnet != netip.MustParsePrefix("172.30.0.0/16") {
			t.Errorf("subnet = %v", subnet)
		}
	})
	t.Run("two candidates fail closed", func(t *testing.T) {
		if _, _, err := pick([]netip.Prefix{one, two}); err == nil {
			t.Fatal("want error for two candidates")
		}
	})
}
