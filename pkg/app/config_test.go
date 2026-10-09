package app

import (
	"io/ioutil"
	"os"
	"path/filepath"
	"testing"
)

func tempDir(t *testing.T) string {
	dir, err := ioutil.TempDir("", "loadconfig")
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

func writeFile(t *testing.T, path, content string) {
	if err := ioutil.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
}

func TestLoadConfigMissingDirectory(t *testing.T) {
	dir := tempDir(t)
	defer os.RemoveAll(dir)

	cfg, err := LoadConfig(filepath.Join(dir, "does-not-exist"))
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if cfg == nil {
		t.Fatal("expected an empty map, got nil")
	}
	if len(cfg) != 0 {
		t.Fatalf("expected no keys, got %v", cfg)
	}
}

func TestLoadConfigReadsFilesAndTrimsValues(t *testing.T) {
	dir := tempDir(t)
	defer os.RemoveAll(dir)

	writeFile(t, filepath.Join(dir, "message"), "  hello from config\n")
	writeFile(t, filepath.Join(dir, "LOG_LEVEL"), "\tdebug \n\n")

	cfg, err := LoadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg) != 2 {
		t.Fatalf("expected 2 keys, got %d: %v", len(cfg), cfg)
	}
	if got := cfg["message"]; got != "hello from config" {
		t.Errorf("message = %q, want %q", got, "hello from config")
	}
	if got := cfg["LOG_LEVEL"]; got != "debug" {
		t.Errorf("LOG_LEVEL = %q, want %q", got, "debug")
	}
}

// A ConfigMap volume holds a timestamped data directory, a "..data" symlink
// pointing at it, and one symlink per key that resolves through "..data".
func TestLoadConfigIgnoresConfigMapInternalsAndSubdirectories(t *testing.T) {
	dir := tempDir(t)
	defer os.RemoveAll(dir)

	dataDir := filepath.Join(dir, "..2016_07_01_12_00_00.123456789")
	if err := os.Mkdir(dataDir, 0755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dataDir, "message"), "from configmap\n")
	if err := os.Symlink(filepath.Base(dataDir), filepath.Join(dir, "..data")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join("..data", "message"), filepath.Join(dir, "message")); err != nil {
		t.Fatal(err)
	}

	sub := filepath.Join(dir, "nested")
	if err := os.Mkdir(sub, 0755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(sub, "inner"), "should not be read")

	cfg, err := LoadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg) != 1 {
		t.Fatalf("expected only the message key, got %v", cfg)
	}
	if got := cfg["message"]; got != "from configmap" {
		t.Errorf("message = %q, want %q", got, "from configmap")
	}
}
