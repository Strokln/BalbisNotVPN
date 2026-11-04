package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestLoadProxyBypassList(t *testing.T) {
	dir := t.TempDir()
	filename := filepath.Join(dir, "proxy-bypass.txt")
	content := "" +
		"# comment only\n" +
		"api2.sec-tunnel.com\n" +
		"*.example.com, https://download.test.local/list.txt\n" +
		"api2.sec-tunnel.com # duplicate\n" +
		"\n"
	if err := os.WriteFile(filename, []byte(content), 0o644); err != nil {
		t.Fatalf("os.WriteFile() error = %v", err)
	}

	got, err := loadProxyBypassList(filename)
	if err != nil {
		t.Fatalf("loadProxyBypassList() error = %v", err)
	}

	want := []string{
		"api2.sec-tunnel.com",
		"*.example.com",
		"https://download.test.local/list.txt",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("loadProxyBypassList() = %#v, want %#v", got, want)
	}
}
