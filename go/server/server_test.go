package server

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/saxeum/foundry/go/httpkit"
)

// Every limit is a constant with a name, so this test is what stops one of them
// being quietly dropped back to Go's default of "no limit".
func TestNewNamesEveryLimit(t *testing.T) {
	srv := New(":0", http.NotFoundHandler(), slog.New(slog.DiscardHandler))

	if srv.ReadHeaderTimeout <= 0 {
		t.Error("ReadHeaderTimeout is not set")
	}
	if srv.ReadTimeout <= 0 {
		t.Error("ReadTimeout is not set: a slow body would hold the connection forever")
	}
	if srv.WriteTimeout <= 0 {
		t.Error("WriteTimeout is not set")
	}
	if srv.IdleTimeout <= 0 {
		t.Error("IdleTimeout is not set")
	}
	if srv.MaxHeaderBytes <= 0 {
		t.Error("MaxHeaderBytes is not set")
	}
	if srv.ErrorLog == nil {
		t.Error("ErrorLog is nil: Go's server errors would bypass the application's logger")
	}

	// The relationship that matters. If the connection is cut before the
	// handler's own deadline, the handler never gets to say why it gave up.
	if srv.WriteTimeout <= httpkit.RequestTimeout {
		t.Errorf("WriteTimeout %v does not exceed RequestTimeout %v", srv.WriteTimeout, httpkit.RequestTimeout)
	}
	if srv.WriteTimeout < DefaultGrace {
		t.Errorf("WriteTimeout %v is shorter than DefaultGrace %v, so a draining request can be cut", srv.WriteTimeout, DefaultGrace)
	}
}

// TestServeLetsAnInFlightRequestFinish is the half of the lifecycle the deploy
// depends on: Shutdown drains rather than cuts.
func TestServeLetsAnInFlightRequestFinish(t *testing.T) {
	entered := make(chan struct{})
	srv := New(":0", http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		close(entered)
		time.Sleep(300 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("finished"))
	}), slog.New(slog.DiscardHandler))

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	served := make(chan error, 1)
	go func() { served <- Serve(ctx, srv, listener, time.Second, slog.New(slog.DiscardHandler)) }()

	response := make(chan string, 1)
	go func() {
		resp, err := http.Get("http://" + listener.Addr().String() + "/")
		if err != nil {
			response <- "error: " + err.Error()
			return
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		response <- string(body)
	}()

	// Cancel only once the handler is actually running, or there is nothing to
	// drain and the test proves nothing.
	<-entered
	cancel()

	select {
	case body := <-response:
		if body != "finished" {
			t.Errorf("in-flight request got %q, want it to run to completion", body)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the in-flight request did not complete during the drain")
	}

	select {
	case err := <-served:
		if err != nil {
			t.Errorf("Serve returned %v, want nil after a clean drain", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Serve did not return after Shutdown")
	}
}
