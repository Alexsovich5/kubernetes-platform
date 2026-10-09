package app

import (
	"os"
	"time"
)

// RunDrain blocks until one signal arrives on sigs, then makes /health fail
// via StartDrain, waits d so load balancers stop routing to this instance,
// and calls exit(0).
func RunDrain(s *Server, sigs <-chan os.Signal, d time.Duration, exit func(int)) {
	<-sigs
	s.StartDrain()
	time.Sleep(d)
	exit(0)
}
