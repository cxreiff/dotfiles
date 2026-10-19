// Package netcheck finds the forwarder's own address on its single container
// network. The forwarder must sit on exactly one IPv4 network; anything else
// fails closed.
package netcheck

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
)

// Local returns the forwarder's IPv4 address and the masked prefix of the
// network it sits on. It errors unless exactly one up, non-loopback interface
// address is IPv4.
func Local() (netip.Addr, netip.Prefix, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return netip.Addr{}, netip.Prefix{}, err
	}
	var cands []netip.Prefix
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			return netip.Addr{}, netip.Prefix{}, err
		}
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip, ok := netip.AddrFromSlice(ipn.IP)
			if !ok {
				continue
			}
			ip = ip.Unmap()
			if !ip.Is4() || ip.IsLoopback() {
				continue
			}
			ones, bits := ipn.Mask.Size()
			if bits != 32 {
				continue
			}
			cands = append(cands, netip.PrefixFrom(ip, ones))
		}
	}
	return pick(cands)
}

// pick selects the single candidate. Zero or several is an error.
func pick(cands []netip.Prefix) (netip.Addr, netip.Prefix, error) {
	switch len(cands) {
	case 0:
		return netip.Addr{}, netip.Prefix{}, errors.New("netcheck: no IPv4 address on an up, non-loopback interface")
	case 1:
		p := cands[0]
		return p.Addr(), p.Masked(), nil
	default:
		return netip.Addr{}, netip.Prefix{}, fmt.Errorf("netcheck: %d IPv4 addresses; the forwarder must be on exactly one network", len(cands))
	}
}

// Inside reports whether a lies within subnet p.
func Inside(p netip.Prefix, a netip.Addr) bool {
	return p.Contains(a)
}
