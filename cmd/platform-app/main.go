// Command platform-app serves /, /health and /metrics and drains on SIGTERM.
package main

import (
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/Alexsovich5/kubernetes-platform/pkg/app"
)

// version is set at build time with -ldflags "-X main.version=<v>".
var version = "dev"

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	addr := getenv("LISTEN_ADDR", ":8080")
	configDir := getenv("CONFIG_DIR", "/app/config")
	drainSeconds, err := strconv.Atoi(getenv("DRAIN_SECONDS", "5"))
	if err != nil || drainSeconds < 0 {
		log.Fatalf("invalid DRAIN_SECONDS %q", os.Getenv("DRAIN_SECONDS"))
	}

	cfg, err := app.LoadConfig(configDir)
	if err != nil {
		log.Fatalf("loading config from %s: %v", configDir, err)
	}

	srv := app.NewServer(version, cfg)

	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM)
	go app.RunDrain(srv, ch, time.Duration(drainSeconds)*time.Second, os.Exit)

	log.Printf("platform-app %s listening on %s (config %s, drain %ds)", version, addr, configDir, drainSeconds)
	log.Fatal(app.NewHTTPServer(addr, srv.Handler()).ListenAndServe())
}
