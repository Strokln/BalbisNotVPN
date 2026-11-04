package main

import (
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

var (
	freeProxyIPPattern   = regexp.MustCompile(`data-ip="([^"]+)"`)
	freeProxyPortPattern = regexp.MustCompile(`data-port="([^"]+)"`)
)

func fetchFreeProxyToFile(sourceURL, outPath string, timeout time.Duration) (int, error) {
	proxies, err := fetchFreeProxyList(sourceURL, timeout)
	if err != nil {
		return 0, err
	}
	if len(proxies) == 0 {
		return 0, fmt.Errorf("no proxies found at %s", sourceURL)
	}
	if err := os.WriteFile(outPath, []byte(strings.Join(proxies, "\n")+"\n"), 0o644); err != nil {
		return 0, err
	}
	return len(proxies), nil
}

func fetchFreeProxyList(sourceURL string, timeout time.Duration) ([]string, error) {
	client := &http.Client{Timeout: timeout}
	seen := make(map[string]struct{})
	proxies := make([]string, 0, 256)

	for page := 1; ; page++ {
		pageURL, err := freeProxyPageURL(sourceURL, page)
		if err != nil {
			return nil, err
		}

		pageProxies, err := fetchFreeProxyPage(client, pageURL)
		if err != nil {
			return nil, fmt.Errorf("page %d: %w", page, err)
		}
		if len(pageProxies) == 0 {
			break
		}

		for _, proxy := range pageProxies {
			if _, ok := seen[proxy]; ok {
				continue
			}
			seen[proxy] = struct{}{}
			proxies = append(proxies, proxy)
		}
	}

	return proxies, nil
}

func freeProxyPageURL(rawURL string, page int) (string, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return "", fmt.Errorf("parse url: %w", err)
	}

	query := parsed.Query()
	if page <= 1 {
		query.Del("page")
	} else {
		query.Set("page", fmt.Sprintf("%d", page))
	}
	parsed.RawQuery = query.Encode()

	return parsed.String(), nil
}

func fetchFreeProxyPage(client *http.Client, pageURL string) ([]string, error) {
	req, err := http.NewRequest(http.MethodGet, pageURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "opera-proxy freeproxy fetcher/1.0")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status %s", resp.Status)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	ipMatches := freeProxyIPPattern.FindAllSubmatch(body, -1)
	portMatches := freeProxyPortPattern.FindAllSubmatch(body, -1)
	rowCount := min(len(ipMatches), len(portMatches))

	proxies := make([]string, 0, rowCount)
	for i := 0; i < rowCount; i++ {
		ip, err := freeProxyDecodeBase64(string(ipMatches[i][1]))
		if err != nil {
			return nil, fmt.Errorf("decode ip on row %d: %w", i+1, err)
		}
		port, err := freeProxyDecodeBase64(string(portMatches[i][1]))
		if err != nil {
			return nil, fmt.Errorf("decode port on row %d: %w", i+1, err)
		}
		proxies = append(proxies, ip+":"+port)
	}

	return proxies, nil
}

func freeProxyDecodeBase64(value string) (string, error) {
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		return "", err
	}
	return string(decoded), nil
}
