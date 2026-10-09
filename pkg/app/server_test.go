package app

import (
	"encoding/json"
	"io/ioutil"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func get(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	req, err := http.NewRequest("GET", path, nil)
	if err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func decodeRoot(t *testing.T, rec *httptest.ResponseRecorder) map[string]string {
	if rec.Code != http.StatusOK {
		t.Fatalf("GET / status = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
	body := map[string]string{}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("body %q is not a JSON object of strings: %v", rec.Body.String(), err)
	}
	return body
}

func TestRootReturnsVersionHostnameAndConfiguredMessage(t *testing.T) {
	s := NewServer("0.1.0", map[string]string{"message": "from config"})
	body := decodeRoot(t, get(t, s.Handler(), "/"))

	host, _ := os.Hostname()
	if body["hostname"] != host {
		t.Errorf("hostname = %q, want %q", body["hostname"], host)
	}
	if body["version"] != "0.1.0" {
		t.Errorf("version = %q, want 0.1.0", body["version"])
	}
	if body["message"] != "from config" {
		t.Errorf("message = %q, want %q", body["message"], "from config")
	}
}

func TestRootFallsBackToHelloWithoutMessage(t *testing.T) {
	for _, cfg := range []map[string]string{nil, {}, {"message": ""}} {
		s := NewServer("0.1.0", cfg)
		body := decodeRoot(t, get(t, s.Handler(), "/"))
		if body["message"] != "hello" {
			t.Errorf("cfg %v: message = %q, want hello", cfg, body["message"])
		}
	}
}

func TestHealthIsOKUntilDrainStarts(t *testing.T) {
	s := NewServer("0.1.0", nil)
	h := s.Handler()

	rec := get(t, h, "/health")
	if rec.Code != http.StatusOK || strings.TrimSpace(rec.Body.String()) != "ok" {
		t.Fatalf("before drain: %d %q, want 200 ok", rec.Code, rec.Body.String())
	}

	s.StartDrain()

	rec = get(t, h, "/health")
	if rec.Code != http.StatusServiceUnavailable || strings.TrimSpace(rec.Body.String()) != "draining" {
		t.Fatalf("after drain: %d %q, want 503 draining", rec.Code, rec.Body.String())
	}
}

func TestMetricsCountsRootRequests(t *testing.T) {
	s := NewServer("0.1.0", nil)
	h := s.Handler()

	get(t, h, "/")

	rec := get(t, h, "/metrics")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /metrics status = %d", rec.Code)
	}
	body, _ := ioutil.ReadAll(rec.Body)
	found := false
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "http_requests_total{") &&
			strings.Contains(line, `handler="root"`) &&
			strings.Contains(line, `code="200"`) &&
			strings.Contains(line, `method="get"`) {
			found = true
		}
	}
	if !found {
		t.Fatalf("no http_requests_total sample for handler=\"root\" in:\n%s", body)
	}
}

func TestUnknownPathReturns404(t *testing.T) {
	s := NewServer("0.1.0", nil)
	rec := get(t, s.Handler(), "/does-not-exist")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}
