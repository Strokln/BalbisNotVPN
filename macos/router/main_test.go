package main

import (
	"bufio"
	"bytes"
	"context"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestDomainRoutes(t *testing.T) {
	r := &router{domains: parseDomains("# comment\nchatgpt.com\ngemini.google.com\nyoutube.com\nfoo..bar\nsndcdn.comå\n")}
	for _, host := range []string{"chatgpt.com", "api.chatgpt.com", "gemini.google.com", "youtube.com"} {
		if !r.abroad(host) {
			t.Fatalf("missing foreign route %s", host)
		}
	}
	for _, host := range []string{"notchatgpt.com", "chatgpt.com.evil", "google.com", "www.google.com", "mail.google.com", "gemini.google.com.evil", "127.0.0.1", "foo..bar", "sndcdn.comå"} {
		if r.abroad(host) {
			t.Fatalf("unexpected foreign route %s", host)
		}
	}
	for _, host := range []string{"evil\r\nHost: x", "foo..bar", "", "-bad.com", "bad_.com"} {
		if _, err := normalizeHost(host); err == nil {
			t.Errorf("accepted invalid host %q", host)
		}
	}
}
func TestFullRoutesAndNoFallback(t *testing.T) {
	var dpiCalls, foreignCalls atomic.Int32
	r := &router{dpi: "127.0.0.1:11001", foreign: "127.0.0.1:11002", domains: parseDomains("chatgpt.com\ngemini.google.com"), active: map[net.Conn]bool{}}
	var failForeign atomic.Bool
	r.dial = func(ctx context.Context, network, endpoint string) (net.Conn, error) {
		a, b := net.Pipe()
		if endpoint == r.foreign {
			foreignCalls.Add(1)
			go func() {
				defer b.Close()
				reader := bufio.NewReader(b)
				var request strings.Builder
				for {
					line, err := reader.ReadString('\n')
					if err != nil {
						return
					}
					request.WriteString(line)
					if line == "\r\n" {
						break
					}
				}
				if !strings.Contains(request.String(), "CONNECT api.chatgpt.com:443 HTTP/1.1") {
					t.Errorf("wrong CONNECT target")
				}
				if failForeign.Load() {
					io.WriteString(b, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
					return
				}
				// Coalesced post-header bytes must be preserved by the router.
				io.WriteString(b, "HTTP/1.1 200 Connection established\r\n\r\nBANNER")
				io.Copy(b, reader)
			}()
		} else {
			dpiCalls.Add(1)
			go func() {
				defer b.Close()
				greeting := make([]byte, 3)
				io.ReadFull(b, greeting)
				b.Write([]byte{5, 0})
				header := make([]byte, 4)
				io.ReadFull(b, header)
				host, err := address(b, header[3])
				if err != nil {
					return
				}
				if host != "www.google.com" {
					t.Errorf("wrong DPI target %s", host)
				}
				port := make([]byte, 2)
				io.ReadFull(b, port)
				reply(b, 0)
				io.Copy(b, b)
			}()
		}
		return a, nil
	}
	connect := func(host string, want byte) net.Conn {
		client, server := net.Pipe()
		go r.handle(server)
		client.SetDeadline(time.Now().Add(3 * time.Second))
		client.Write([]byte{5, 1, 0})
		greeting := make([]byte, 2)
		if _, err := io.ReadFull(client, greeting); err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(greeting, []byte{5, 0}) {
			t.Fatal("greeting")
		}
		client.Write(socksRequest(host, 443))
		response := make([]byte, 10)
		if _, err := io.ReadFull(client, response); err != nil {
			t.Fatal(err)
		}
		if response[1] != want {
			t.Fatalf("%s: wanted %d got %d", host, want, response[1])
		}
		return client
	}
	foreign := connect("api.chatgpt.com", 0)
	banner := make([]byte, 6)
	if _, err := io.ReadFull(foreign, banner); err != nil || string(banner) != "BANNER" {
		t.Fatal("CONNECT buffered data lost", err)
	}
	foreign.Write([]byte("TLS bytes"))
	echo := make([]byte, 9)
	io.ReadFull(foreign, echo)
	if string(echo) != "TLS bytes" {
		t.Fatal("foreign stream changed")
	}
	foreign.Close()
	dpi := connect("www.google.com", 0)
	dpi.Write([]byte("direct"))
	plain := make([]byte, 6)
	io.ReadFull(dpi, plain)
	if string(plain) != "direct" {
		t.Fatal("DPI stream changed")
	}
	dpi.Close()
	failForeign.Store(true)
	failed := connect("api.chatgpt.com", 5)
	failed.Close()
	if dpiCalls.Load() != 1 || foreignCalls.Load() != 2 {
		t.Fatal("foreign failure fell back to DPI")
	}
	denied := connect("127.0.0.1", 2)
	denied.Close()
	r.closeAll()
}
func TestHTTPHeaderBound(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	go func() {
		defer b.Close()
		r := bufio.NewReader(b)
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				return
			}
			if line == "\r\n" {
				break
			}
		}
		io.WriteString(b, "HTTP/1.1 200 OK\r\nX: "+strings.Repeat("a", 20000))
	}()
	a.SetDeadline(time.Now().Add(time.Second))
	if _, err := httpConnect(a, "chatgpt.com", 443); err == nil {
		t.Fatal("unbounded CONNECT headers accepted")
	}
}

func TestHTTPConnectEagerAndIdleStream(t *testing.T) {
	r := &router{dpi: "127.0.0.1:11001", foreign: "127.0.0.1:11002", domains: parseDomains("chatgpt.com"), active: map[net.Conn]bool{}}
	r.dial = func(ctx context.Context, network, endpoint string) (net.Conn, error) {
		if endpoint != r.foreign {
			t.Error("CONNECT used wrong route")
		}
		a, b := net.Pipe()
		go func() {
			defer b.Close()
			reader := bufio.NewReader(b)
			for {
				line, err := reader.ReadString('\n')
				if err != nil {
					return
				}
				if line == "\r\n" {
					break
				}
			}
			io.WriteString(b, "HTTP/1.1 200 Connection established\r\n\r\n")
			io.Copy(b, reader)
		}()
		return a, nil
	}
	a, b := net.Pipe()
	defer a.Close()
	defer r.closeAll()
	go r.handle(b)
	a.SetDeadline(time.Now().Add(25 * time.Second))
	a.Write([]byte("CONNECT ws.chatgpt.com:443 HTTP/1.1\r\nHost: ws.chatgpt.com:443\r\n\r\nEARLY"))
	reader := bufio.NewReader(a)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if line == "\r\n" {
			break
		}
	}
	early := make([]byte, 5)
	if _, err := io.ReadFull(reader, early); err != nil || string(early) != "EARLY" {
		t.Fatal("eager TLS bytes lost", err)
	}
	// A WebSocket/SSE tunnel must survive idle longer than the 15s handshake limit.
	time.Sleep(16 * time.Second)
	a.Write([]byte("STREAM"))
	data := make([]byte, 6)
	if _, err := io.ReadFull(reader, data); err != nil || string(data) != "STREAM" {
		t.Fatal("idle stream was truncated", err)
	}
}
func TestHTTPRejectsUnsafeTargetsAndMethods(t *testing.T) {
	r := &router{domains: parseDomains("chatgpt.com"), active: map[net.Conn]bool{}, dial: func(context.Context, string, string) (net.Conn, error) {
		t.Error("must not dial invalid target")
		return nil, io.EOF
	}}
	defer r.closeAll()
	for _, test := range []struct{ request, status string }{
		{"GET http://chatgpt.com/ HTTP/1.1\r\nHost: chatgpt.com\r\n\r\n", "405"},
		{"CONNECT 127.0.0.1:80 HTTP/1.1\r\nHost: 127.0.0.1:80\r\n\r\n", "403"},
		{"CONNECT chatgpt.com:0 HTTP/1.1\r\nHost: chatgpt.com:0\r\n\r\n", "400"},
		{"CONNECT chatgpt.com:443 HTTP/1.1\r\nHost: chatgpt.com:443\r\nContent-Length: 5\r\n\r\n", "400"},
	} {
		a, b := net.Pipe()
		go r.handle(b)
		a.SetDeadline(time.Now().Add(time.Second))
		a.Write([]byte(test.request))
		line, err := bufio.NewReader(a).ReadString('\n')
		if err != nil || !strings.Contains(line, test.status) {
			t.Errorf("wanted %s got %q %v", test.status, line, err)
		}
		a.Close()
	}
}
