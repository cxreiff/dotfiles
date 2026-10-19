package node

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"testing"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/types/views"
)

func selfSignedPEM(t *testing.T, notAfter time.Time) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "cxagents.faun-fir.ts.net"},
		NotBefore:    notAfter.AddDate(-1, 0, 0),
		NotAfter:     notAfter,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func TestLeafNotAfterReadsExpiry(t *testing.T) {
	want := time.Date(2031, 2, 3, 4, 5, 6, 0, time.UTC)
	got, err := leafNotAfter(selfSignedPEM(t, want))
	if err != nil {
		t.Fatalf("leafNotAfter: %v", err)
	}
	if !got.Equal(want) {
		t.Fatalf("NotAfter = %v, want %v", got, want)
	}
}

func TestLeafNotAfterRejectsNonCertificates(t *testing.T) {
	cases := map[string][]byte{
		"no PEM block": []byte("not a certificate"),
		"PEM but not a certificate": pem.EncodeToMemory(&pem.Block{
			Type: "CERTIFICATE", Bytes: []byte("junk"),
		}),
	}
	for name, in := range cases {
		if _, err := leafNotAfter(in); err == nil {
			t.Fatalf("%s: leafNotAfter succeeded, want an error", name)
		}
	}
}

func TestInfoFromMapsSelfStatus(t *testing.T) {
	tags := views.SliceOf([]string{"tag:cxagents"})
	st := &ipnstate.Status{
		BackendState: "Running",
		Self: &ipnstate.PeerStatus{
			ID:      "nStable",
			DNSName: "cxagents-1.faun-fir.ts.net.",
			Online:  true,
			Tags:    &tags,
		},
	}
	info := infoFrom(st)
	if info.BackendState != "Running" || info.ID != "nStable" || !info.Online {
		t.Fatalf("info = %+v", info)
	}
	if info.DNSName != "cxagents-1.faun-fir.ts.net" {
		t.Fatalf("DNSName = %q, want the trailing dot stripped", info.DNSName)
	}
	if info.Name != "cxagents-1" {
		t.Fatalf("Name = %q, want the first label", info.Name)
	}
	if len(info.Tags) != 1 || info.Tags[0] != "tag:cxagents" {
		t.Fatalf("Tags = %v", info.Tags)
	}
	info.Tags[0] = "changed"
	if tags.At(0) != "tag:cxagents" {
		t.Fatal("info.Tags shares storage with the tsnet status")
	}
}

func TestInfoFromNilSelfAndNilTags(t *testing.T) {
	info := infoFrom(&ipnstate.Status{BackendState: "NoState"})
	if info.BackendState != "NoState" || info.Name != "" || info.DNSName != "" || info.Tags != nil {
		t.Fatalf("nil Self: info = %+v", info)
	}

	info = infoFrom(&ipnstate.Status{
		BackendState: "Running",
		Self:         &ipnstate.PeerStatus{DNSName: "cxagents.faun-fir.ts.net."},
	})
	if info.Name != "cxagents" || info.Tags != nil {
		t.Fatalf("nil Tags: info = %+v", info)
	}
}
