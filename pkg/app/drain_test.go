package app

import (
	"net/http"
	"os"
	"syscall"
	"testing"
	"time"
)

func TestRunDrainFailsHealthThenExitsZero(t *testing.T) {
	s := NewServer("0.1.0", nil)
	h := s.Handler()
	sigs := make(chan os.Signal, 1)
	exited := make(chan int, 1)

	go RunDrain(s, sigs, 0, func(code int) { exited <- code })

	if rec := get(t, h, "/health"); rec.Code != http.StatusOK {
		t.Fatalf("before signal: /health = %d, want 200", rec.Code)
	}

	sigs <- syscall.SIGTERM

	select {
	case code := <-exited:
		if code != 0 {
			t.Fatalf("exit code = %d, want 0", code)
		}
	case <-time.After(time.Second):
		t.Fatal("exit was not called within 1s of SIGTERM")
	}

	if rec := get(t, h, "/health"); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("after signal: /health = %d, want 503", rec.Code)
	}
}

func TestRunDrainWaitsBeforeExiting(t *testing.T) {
	s := NewServer("0.1.0", nil)
	sigs := make(chan os.Signal, 1)
	exited := make(chan int, 1)

	go RunDrain(s, sigs, 200*time.Millisecond, func(code int) { exited <- code })
	sigs <- syscall.SIGTERM

	select {
	case <-exited:
		t.Fatal("exit called before the drain period elapsed")
	case <-time.After(50 * time.Millisecond):
	}
	if rec := get(t, s.Handler(), "/health"); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("during drain: /health = %d, want 503", rec.Code)
	}
	select {
	case <-exited:
	case <-time.After(time.Second):
		t.Fatal("exit was not called after the drain period")
	}
}
