package dialer

import (
	"context"
	"errors"
	"net"
	"testing"
)

type recordingDialer struct {
	name      string
	addresses []string
}

func (d *recordingDialer) Dial(network, address string) (net.Conn, error) {
	return d.DialContext(context.Background(), network, address)
}

func (d *recordingDialer) DialContext(_ context.Context, _ string, address string) (net.Conn, error) {
	d.addresses = append(d.addresses, address)
	return nil, errors.New(d.name)
}

func TestBypassDialerRoutesByHostPattern(t *testing.T) {
	direct := &recordingDialer{name: "direct"}
	proxied := &recordingDialer{name: "proxied"}

	d, err := NewBypassDialer([]string{
		"api2.sec-tunnel.com",
		"*.example.com",
		"https://already.url.test/some/path",
	}, direct, proxied)
	if err != nil {
		t.Fatalf("NewBypassDialer() error = %v", err)
	}

	tests := []struct {
		address     string
		wantDirect  bool
		description string
	}{
		{address: "api2.sec-tunnel.com:443", wantDirect: true, description: "exact host"},
		{address: "cdn.example.com:8443", wantDirect: true, description: "wildcard host"},
		{address: "ALREADY.URL.TEST:443", wantDirect: true, description: "case insensitive"},
		{address: "other.test:443", wantDirect: false, description: "unmatched host"},
	}

	for _, tt := range tests {
		_, err := d.DialContext(context.Background(), "tcp", tt.address)
		if err == nil {
			t.Fatalf("%s: expected dial error", tt.description)
		}
		if tt.wantDirect && err.Error() != "direct" {
			t.Fatalf("%s: expected direct dialer, got %v", tt.description, err)
		}
		if !tt.wantDirect && err.Error() != "proxied" {
			t.Fatalf("%s: expected proxied dialer, got %v", tt.description, err)
		}
	}
}

func TestNewBypassDialerRejectsInvalidPattern(t *testing.T) {
	_, err := NewBypassDialer([]string{" "}, &recordingDialer{}, &recordingDialer{})
	if err == nil {
		t.Fatal("expected invalid pattern error")
	}
}
