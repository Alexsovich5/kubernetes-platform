package app

import (
	"net/http"
	"testing"
)

func TestNewHTTPServerSetsAddressHandlerAndTimeouts(t *testing.T) {
	h := http.NotFoundHandler()
	srv := NewHTTPServer(":8080", h)

	if srv.Addr != ":8080" {
		t.Errorf("Addr = %q, want :8080", srv.Addr)
	}
	if srv.Handler == nil {
		t.Error("Handler is nil")
	}
	// Without timeouts a client that never finishes its request holds a
	// connection and a goroutine forever.
	if srv.ReadTimeout != ReadTimeout || ReadTimeout <= 0 {
		t.Errorf("ReadTimeout = %v, want %v (> 0)", srv.ReadTimeout, ReadTimeout)
	}
	if srv.WriteTimeout != WriteTimeout || WriteTimeout <= 0 {
		t.Errorf("WriteTimeout = %v, want %v (> 0)", srv.WriteTimeout, WriteTimeout)
	}
	if srv.MaxHeaderBytes != MaxHeaderBytes || MaxHeaderBytes <= 0 {
		t.Errorf("MaxHeaderBytes = %d, want %d (> 0)", srv.MaxHeaderBytes, MaxHeaderBytes)
	}
}
