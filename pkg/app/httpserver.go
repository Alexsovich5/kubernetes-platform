package app

import (
	"net/http"
	"time"
)

// Limits for the platform-app HTTP server. Without them a client that sends
// its request slowly, or never reads the response, holds a connection and a
// goroutine indefinitely.
const (
	ReadTimeout    = 10 * time.Second
	WriteTimeout   = 10 * time.Second
	MaxHeaderBytes = 64 << 10
)

// NewHTTPServer returns an http.Server for addr and h with read and write
// timeouts and a header size limit set.
func NewHTTPServer(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:           addr,
		Handler:        h,
		ReadTimeout:    ReadTimeout,
		WriteTimeout:   WriteTimeout,
		MaxHeaderBytes: MaxHeaderBytes,
	}
}
