// Balbis macOS routing helper. All listeners and upstream hops are loopback-only.
// It forwards TLS unchanged and makes route decisions from SOCKS domain names.
package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type router struct {
	dpi, foreign string
	domains      map[string]bool
	dial         func(context.Context, string, string) (net.Conn, error)
	mu           sync.Mutex
	active       map[net.Conn]bool
	closed       bool
}

func normalizeHost(host string) (string, error) {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if ip := net.ParseIP(host); ip != nil {
		return ip.String(), nil
	}
	if len(host) == 0 || len(host) > 253 {
		return "", errors.New("invalid hostname")
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return "", errors.New("invalid hostname")
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return "", errors.New("invalid hostname")
			}
		}
	}
	return host, nil
}
func parseDomains(body string) map[string]bool {
	result := map[string]bool{}
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(strings.SplitN(line, "#", 2)[0])
		if host, err := normalizeHost(line); err == nil && net.ParseIP(host) == nil {
			result[host] = true
		}
	}
	return result
}
func (r *router) abroad(host string) bool {
	if net.ParseIP(host) != nil {
		return false
	}
	for {
		if r.domains[host] {
			return true
		}
		pos := strings.IndexByte(host, '.')
		if pos < 0 {
			return false
		}
		host = host[pos+1:]
	}
}
func (r *router) add(c net.Conn) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		c.Close()
		return false
	}
	r.active[c] = true
	return true
}
func (r *router) remove(c net.Conn) { c.Close(); r.mu.Lock(); delete(r.active, c); r.mu.Unlock() }
func (r *router) closeAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closed = true
	for c := range r.active {
		c.Close()
	}
}
func exact(w io.Writer, p []byte) error {
	for len(p) > 0 {
		n, err := w.Write(p)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		p = p[n:]
	}
	return nil
}
func socksRequest(host string, port uint16) []byte {
	request := []byte{5, 1, 0}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			request = append(request, 1)
			request = append(request, v4...)
		} else {
			request = append(request, 4)
			request = append(request, ip.To16()...)
		}
	} else {
		request = append(request, 3, byte(len(host)))
		request = append(request, host...)
	}
	return append(request, byte(port>>8), byte(port))
}
func address(reader io.Reader, kind byte) (string, error) {
	var size int
	switch kind {
	case 1:
		size = 4
	case 4:
		size = 16
	case 3:
		length := []byte{0}
		if _, err := io.ReadFull(reader, length); err != nil {
			return "", err
		}
		size = int(length[0])
	default:
		return "", errors.New("unsupported address")
	}
	data := make([]byte, size)
	if _, err := io.ReadFull(reader, data); err != nil {
		return "", err
	}
	if kind != 3 {
		return net.IP(data).String(), nil
	}
	return normalizeHost(string(data))
}
func socksConnect(c net.Conn, host string, port uint16) error {
	if err := exact(c, []byte{5, 1, 0}); err != nil {
		return err
	}
	answer := make([]byte, 2)
	if _, err := io.ReadFull(c, answer); err != nil {
		return err
	}
	if answer[0] != 5 || answer[1] != 0 {
		return errors.New("DPI SOCKS authentication failed")
	}
	if err := exact(c, socksRequest(host, port)); err != nil {
		return err
	}
	header := make([]byte, 4)
	if _, err := io.ReadFull(c, header); err != nil {
		return err
	}
	if header[0] != 5 || header[1] != 0 || header[2] != 0 {
		return errors.New("DPI SOCKS refused connection")
	}
	if _, err := address(c, header[3]); err != nil {
		return err
	}
	_, err := io.ReadFull(c, answer)
	return err
}
func httpConnect(c net.Conn, host string, port uint16) (io.Reader, error) {
	destination := net.JoinHostPort(host, fmt.Sprint(port))
	if err := exact(c, []byte("CONNECT "+destination+" HTTP/1.1\r\nHost: "+destination+"\r\n\r\n")); err != nil {
		return nil, err
	}
	reader := bufio.NewReaderSize(c, 4096)
	// Limit CONNECT headers without limiting the subsequent tunnel stream.
	header := make([]byte, 0, 1024)
	for len(header) < 16384 {
		b, err := reader.ReadByte()
		if err != nil {
			return nil, err
		}
		header = append(header, b)
		if len(header) >= 4 && string(header[len(header)-4:]) == "\r\n\r\n" {
			response, err := http.ReadResponse(bufio.NewReader(strings.NewReader(string(header))), &http.Request{Method: "CONNECT"})
			if err != nil {
				return nil, err
			}
			if response.StatusCode != 200 {
				return nil, fmt.Errorf("foreign CONNECT refused: %d", response.StatusCode)
			}
			return reader, nil
		}
	}
	return nil, errors.New("CONNECT header too large")
}
func reply(c net.Conn, code byte) error { return exact(c, []byte{5, code, 0, 1, 0, 0, 0, 0, 0, 0}) }

type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.reader.Read(p) }

// One loopback endpoint accepts SOCKS5 and HTTP CONNECT. Native client runtimes
// commonly support explicit HTTP_PROXY/HTTPS_PROXY even when they ignore PAC.
func (r *router) handle(client net.Conn) {
	if !r.add(client) {
		return
	}
	defer r.remove(client)
	client.SetDeadline(time.Now().Add(15 * time.Second))
	reader := bufio.NewReader(client)
	first, err := reader.Peek(1)
	if err != nil {
		return
	}
	conn := &bufferedConn{Conn: client, reader: reader}
	if first[0] == 5 {
		r.handleSOCKS(conn)
	} else {
		r.handleHTTP(conn, reader)
	}
}
func (r *router) handleSOCKS(client net.Conn) {
	greeting := make([]byte, 2)
	if _, err := io.ReadFull(client, greeting); err != nil || greeting[0] != 5 || greeting[1] == 0 {
		return
	}
	methods := make([]byte, int(greeting[1]))
	if _, err := io.ReadFull(client, methods); err != nil {
		return
	}
	noAuth := false
	for _, method := range methods {
		if method == 0 {
			noAuth = true
		}
	}
	if !noAuth {
		exact(client, []byte{5, 255})
		return
	}
	if exact(client, []byte{5, 0}) != nil {
		return
	}
	header := make([]byte, 4)
	if _, err := io.ReadFull(client, header); err != nil || header[0] != 5 || header[2] != 0 {
		return
	}
	if header[1] != 1 {
		reply(client, 7)
		return
	} // CONNECT only; never silently accept UDP.
	host, err := address(client, header[3])
	if err != nil {
		reply(client, 8)
		return
	}
	var bytes [2]byte
	if _, err := io.ReadFull(client, bytes[:]); err != nil {
		return
	}
	port := binary.BigEndian.Uint16(bytes[:])
	if port == 0 {
		reply(client, 2)
		return
	}
	upstream, incoming, code := r.openTunnel(host, port)
	if code != 0 {
		reply(client, code)
		return
	}
	defer r.remove(upstream)
	if reply(client, 0) != nil {
		return
	}
	relay(client, upstream, incoming)
}
func (r *router) openTunnel(host string, port uint16) (net.Conn, io.Reader, byte) {
	// Prevent local/LAN destinations reached through the unauthenticated listener.
	if host == "localhost" || (!strings.Contains(host, ".") && net.ParseIP(host) == nil) || strings.HasSuffix(host, ".local") {
		return nil, nil, 2
	}
	if ip := net.ParseIP(host); ip != nil && (ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() || ip.IsMulticast()) {
		return nil, nil, 2
	}
	// Without the original domain a split decision is impossible. Refuse IP-only
	// requests rather than silently sending an AI connection through the DPI route.
	if net.ParseIP(host) != nil {
		return nil, nil, 8
	}
	foreign := r.abroad(host)
	target := r.dpi
	if foreign {
		target = r.foreign
	}
	// Empty/unavailable foreign upstream is a hard failure. No DIRECT/DPI fallback.
	if target == "" {
		return nil, nil, 4
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	upstream, err := r.dial(ctx, "tcp", target)
	if err != nil {
		return nil, nil, 5
	}
	if !r.add(upstream) {
		return nil, nil, 5
	}
	upstream.SetDeadline(time.Now().Add(15 * time.Second))
	var incoming io.Reader = upstream
	if foreign {
		incoming, err = httpConnect(upstream, host, port)
	} else {
		err = socksConnect(upstream, host, port)
	}
	if err != nil {
		r.remove(upstream)
		return nil, nil, 5
	}
	return upstream, incoming, 0
}
func (r *router) handleHTTP(client net.Conn, reader *bufio.Reader) {
	fail := func(status int) {
		fmt.Fprintf(client, "HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status, http.StatusText(status))
	}
	header := make([]byte, 0, 1024)
	for {
		if len(header) >= 16384 {
			fail(431)
			return
		}
		b, err := reader.ReadByte()
		if err != nil {
			return
		}
		header = append(header, b)
		if len(header) >= 4 && string(header[len(header)-4:]) == "\r\n\r\n" {
			break
		}
	}
	request, err := http.ReadRequest(bufio.NewReader(strings.NewReader(string(header))))
	if err != nil {
		fail(400)
		return
	}
	if request.Method != "CONNECT" {
		fail(405)
		return
	}
	if request.ContentLength > 0 || len(request.TransferEncoding) > 0 {
		fail(400)
		return
	}
	host, portText, err := net.SplitHostPort(request.RequestURI)
	if err != nil {
		fail(400)
		return
	}
	host, err = normalizeHost(host)
	if err != nil {
		fail(400)
		return
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port == 0 {
		fail(400)
		return
	}
	upstream, incoming, code := r.openTunnel(host, uint16(port))
	if code != 0 {
		if code == 2 || code == 8 {
			fail(403)
		} else {
			fail(502)
		}
		return
	}
	defer r.remove(upstream)
	if exact(client, []byte("HTTP/1.1 200 Connection Established\r\n\r\n")) != nil {
		return
	}
	// client reads through the original buffered reader, preserving eager TLS bytes.
	relay(client, upstream, incoming)
}
func relay(client, upstream net.Conn, incoming io.Reader) {
	upstream.SetDeadline(time.Time{})
	client.SetDeadline(time.Time{})
	done := make(chan struct{}, 1)
	go func() {
		io.Copy(upstream, client)
		if tcp, ok := upstream.(*net.TCPConn); ok {
			tcp.CloseWrite()
		}
		done <- struct{}{}
	}()
	io.Copy(client, incoming)
	// Reverse EOF or cancellation closes both sides; bound the upload goroutine too.
	client.Close()
	upstream.Close()
	<-done
}
func loopback(value string) error {
	host, port, err := net.SplitHostPort(value)
	if err != nil || host != "127.0.0.1" || port == "" {
		return errors.New("only 127.0.0.1 endpoints are allowed")
	}
	_, err = net.ResolveTCPAddr("tcp4", value)
	return err
}
func main() {
	listen := flag.String("listen", "", "loopback SOCKS5 address")
	dpi := flag.String("dpi", "", "local DPI SOCKS5 backend")
	foreign := flag.String("foreign", "", "local HTTP CONNECT tunnel backend")
	domains := flag.String("domains", "", "foreign-route domain list")
	flag.Parse()
	for _, endpoint := range []string{*listen, *dpi, *foreign} {
		if err := loopback(endpoint); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
	}
	body, err := os.ReadFile(*domains)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot read routing list")
		os.Exit(2)
	}
	rules := parseDomains(string(body))
	if len(rules) == 0 {
		fmt.Fprintln(os.Stderr, "empty foreign domain list")
		os.Exit(2)
	}
	dialer := &net.Dialer{Timeout: 12 * time.Second, KeepAlive: 30 * time.Second}
	r := &router{dpi: *dpi, foreign: *foreign, domains: rules, dial: dialer.DialContext, active: map[net.Conn]bool{}}
	listener, err := net.Listen("tcp4", *listen)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot listen on SOCKS port")
		os.Exit(1)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	go func() { <-ctx.Done(); listener.Close(); r.closeAll() }()
	slots := make(chan struct{}, 256)
	for {
		conn, err := listener.Accept()
		if err != nil {
			break
		}
		select {
		case slots <- struct{}{}:
			go func() { defer func() { <-slots }(); r.handle(conn) }()
		default:
			conn.Close()
		}
	}
	r.closeAll()
}
