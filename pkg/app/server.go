package app

import (
	"encoding/json"
	"net/http"
	"os"
	"sync/atomic"

	"github.com/prometheus/client_golang/prometheus"
)

// DefaultMessage is returned by / when the config has no "message" key.
const DefaultMessage = "hello"

// Server holds the state behind the platform-app HTTP endpoints.
type Server struct {
	Version, Hostname string
	Config            map[string]string
	draining          int32
}

// NewServer returns a Server for the given version and config, with
// Hostname taken from the operating system.
func NewServer(version string, cfg map[string]string) *Server {
	host, _ := os.Hostname()
	if cfg == nil {
		cfg = map[string]string{}
	}
	return &Server{Version: version, Hostname: host, Config: cfg}
}

// Handler serves /, /health and /metrics. The / and /health handlers are
// wrapped with prometheus.InstrumentHandler under the names "root" and
// "health"; any other path returns 404.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/", prometheus.InstrumentHandlerFunc("root", s.root))
	mux.Handle("/health", prometheus.InstrumentHandlerFunc("health", s.health))
	mux.Handle("/metrics", prometheus.Handler())
	return mux
}

// StartDrain makes /health return 503 from now on.
func (s *Server) StartDrain() {
	atomic.StoreInt32(&s.draining, 1)
}

// Draining reports whether StartDrain has been called.
func (s *Server) Draining() bool {
	return atomic.LoadInt32(&s.draining) == 1
}

func (s *Server) root(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	msg := s.Config["message"]
	if msg == "" {
		msg = DefaultMessage
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"hostname": s.Hostname,
		"version":  s.Version,
		"message":  msg,
	})
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if s.Draining() {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte("draining\n"))
		return
	}
	w.Write([]byte("ok\n"))
}
