// Package server owns the process lifecycle: the HTTP server with every limit
// named, and the drain on shutdown. It knows nothing about a domain.
package server

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/saxeum/foundry/go/httpkit"
)

const (
	readHeaderTimeout = 5 * time.Second
	readTimeout       = 10 * time.Second
	idleTimeout       = 60 * time.Second
	maxHeaderBytes    = 1 << 20

	// A request may run for httpkit.RequestTimeout, so anything that waits for
	// one has to outlast it: the time allowed to write the response, and the
	// time a drain waits before closing connections.
	responseOverhead = 5 * time.Second
	writeTimeout     = httpkit.RequestTimeout + responseOverhead

	// DefaultGrace is the drain budget. The pod's terminationGracePeriodSeconds
	// must exceed it plus any preStop sleep.
	DefaultGrace = httpkit.RequestTimeout + responseOverhead
)

// New builds the server with every limit named.
//
// It is separate from Run so the limits can be asserted without a socket, and
// so that "which timeout is this" is answered by a constant rather than by a
// literal inside a struct.
func New(addr string, handler http.Handler, log *slog.Logger) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		MaxHeaderBytes:    maxHeaderBytes,
		// Everything Go's server wants to say — TLS handshakes, handler errors,
		// panics that escaped a handler — goes through the application's logger
		// instead of the standard library's default one.
		ErrorLog: slog.NewLogLogger(log.Handler(), slog.LevelError),
	}
}

// Run binds the configured address and serves until ctx is cancelled, then
// drains. It returns the error that stopped it, or nil after a clean shutdown.
//
// Binding before serving means a taken port is an error the caller sees, not a
// failure inside a goroutine racing the rest of startup.
func Run(ctx context.Context, srv *http.Server, grace time.Duration, log *slog.Logger) error {
	listener, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", srv.Addr, err)
	}

	return Serve(ctx, srv, listener, grace, log)
}

// Serve serves an already-bound listener until ctx is cancelled, then drains.
//
// Split from Run so a test can bind port 0, learn the address, and cancel the
// context — with the listen call buried inside Run there was nothing to drive.
func Serve(ctx context.Context, srv *http.Server, listener net.Listener, grace time.Duration, log *slog.Logger) error {
	serveErr := make(chan error, 1)
	go func() {
		err := srv.Serve(listener)
		if errors.Is(err, http.ErrServerClosed) {
			log.Info("stopped serving new connections")
			return
		}
		serveErr <- fmt.Errorf("serve: %w", err)
	}()

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}

	drain(srv, grace, log)
	return nil
}

// drain stops accepting connections and waits up to grace for the ones already
// running.
//
// Running out of grace is not a failure of the process and must not be reported
// as one. A request that took eleven seconds is a slow request, not a crash, and
// returning an error here makes `kubectl rollout status` report a failed rollout
// for a pod that did what it was told. The process's job is to leave a trace
// saying it was not graceful.
func drain(srv *http.Server, grace time.Duration, log *slog.Logger) {
	ctx, release := context.WithTimeout(context.Background(), grace)
	defer release()

	err := srv.Shutdown(ctx)
	if err == nil {
		log.Info("graceful shutdown complete")
		return
	}

	// Requests are still running. Close the connections so they stop, rather
	// than letting the caller's pool Close pull the database out from under
	// handlers that are mid-query. Shutdown drains; Close stops.
	srv.Close()
	log.Warn("shutdown grace expired with requests in flight; connections closed",
		"err", err, "grace", grace)
}
