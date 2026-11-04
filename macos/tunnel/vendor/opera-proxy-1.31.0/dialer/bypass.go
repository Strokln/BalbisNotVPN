package dialer

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"path"
	"strings"
)

type bypassPattern struct {
	raw  string
	host string
}

type BypassDialer struct {
	direct   ContextDialer
	proxied  ContextDialer
	patterns []bypassPattern
}

func NewBypassDialer(patterns []string, direct, proxied ContextDialer) (*BypassDialer, error) {
	compiled := make([]bypassPattern, 0, len(patterns))
	for _, raw := range patterns {
		hostPattern, err := normalizeBypassPattern(raw)
		if err != nil {
			return nil, fmt.Errorf("invalid proxy bypass pattern %q: %w", raw, err)
		}
		if _, err := path.Match(hostPattern, ""); err != nil {
			return nil, fmt.Errorf("invalid proxy bypass pattern %q: %w", raw, err)
		}
		compiled = append(compiled, bypassPattern{
			raw:  raw,
			host: hostPattern,
		})
	}
	return &BypassDialer{
		direct:   direct,
		proxied:  proxied,
		patterns: compiled,
	}, nil
}

func (d *BypassDialer) Dial(network, address string) (net.Conn, error) {
	return d.DialContext(context.Background(), network, address)
}

func (d *BypassDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	if d.shouldBypass(address) {
		return d.direct.DialContext(ctx, network, address)
	}
	return d.proxied.DialContext(ctx, network, address)
}

func (d *BypassDialer) shouldBypass(address string) bool {
	host := normalizeDialTarget(address)
	if host == "" {
		return false
	}
	for _, pattern := range d.patterns {
		matched, err := path.Match(pattern.host, host)
		if err != nil {
			continue
		}
		if matched {
			return true
		}
	}
	return false
}

func normalizeBypassPattern(raw string) (string, error) {
	pattern := strings.TrimSpace(raw)
	if pattern == "" {
		return "", fmt.Errorf("empty pattern")
	}

	switch {
	case strings.Contains(pattern, "://"):
		parsed, err := url.Parse(pattern)
		if err != nil {
			return "", fmt.Errorf("unable to parse URL: %w", err)
		}
		if parsed.Host == "" {
			return "", fmt.Errorf("URL does not contain a host")
		}
		pattern = parsed.Hostname()
	case strings.HasPrefix(pattern, "//"):
		parsed, err := url.Parse("https:" + pattern)
		if err != nil {
			return "", fmt.Errorf("unable to parse URL: %w", err)
		}
		if parsed.Host == "" {
			return "", fmt.Errorf("URL does not contain a host")
		}
		pattern = parsed.Hostname()
	case strings.ContainsAny(pattern, "/?"):
		parsed, err := url.Parse("https://" + strings.TrimLeft(pattern, "/"))
		if err != nil {
			return "", fmt.Errorf("unable to parse URL-like pattern: %w", err)
		}
		if parsed.Host == "" {
			return "", fmt.Errorf("pattern does not contain a host")
		}
		pattern = parsed.Hostname()
	default:
		if host, _, err := net.SplitHostPort(pattern); err == nil {
			pattern = host
		}
	}

	pattern = strings.Trim(pattern, "[]")
	pattern = strings.ToLower(pattern)
	if pattern == "" {
		return "", fmt.Errorf("empty host pattern")
	}
	return pattern, nil
}

func normalizeDialTarget(address string) string {
	host := strings.TrimSpace(address)
	if host == "" {
		return ""
	}
	if parsed, err := url.Parse(host); err == nil && parsed.Host != "" {
		host = parsed.Hostname()
	} else if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.Trim(host, "[]")
	return strings.ToLower(host)
}
