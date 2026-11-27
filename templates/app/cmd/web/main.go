// Command web is the app's HTTP server. It wires config, the pool, the
// generated contract, the platform middleware and the process lifecycle.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/saxeum/__APP_NAME__/internal/api"
	"github.com/saxeum/foundry/go/config"
	"github.com/saxeum/foundry/go/httpkit"
	"github.com/saxeum/foundry/go/postgres"
	"github.com/saxeum/foundry/go/server"
)

// bootTimeout bounds how long startup may spend reaching the database. A DSN
// that points at a host which drops packets would otherwise block for the
// operating system's TCP timeout, with the pod neither started nor crashed.
const bootTimeout = 10 * time.Second

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cfg, err := config.FromEnv()
	if err != nil {
		slog.New(slog.NewTextHandler(os.Stderr, nil)).Error("fatal", "err", err)
		os.Exit(1)
	}
	log := cfg.Logger(os.Stdout)

	if err := run(ctx, cfg, log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, cfg config.Config, log *slog.Logger) error {
	bootCtx, bootDone := context.WithTimeout(ctx, bootTimeout)
	pool, err := postgres.NewPool(bootCtx, cfg.DatabaseURL)
	if err != nil {
		bootDone()
		return err
	}
	if err := pool.Ping(bootCtx); err != nil {
		bootDone()
		pool.Close()
		return err
	}
	bootDone()
	defer pool.Close()

	metrics := httpkit.NewMetrics()

	strict := api.NewStrictHandlerWithOptions(api.New(), nil, api.StrictHTTPServerOptions{
		RequestErrorHandlerFunc: func(w http.ResponseWriter, _ *http.Request, _ error) {
			httpkit.WriteJSON(w, http.StatusBadRequest, httpkit.ErrorBody(http.StatusBadRequest))
		},
		ResponseErrorHandlerFunc: func(w http.ResponseWriter, _ *http.Request, _ error) {
			httpkit.WriteJSON(w, http.StatusInternalServerError, httpkit.ErrorBody(http.StatusInternalServerError))
		},
	})
	apiHandler := api.HandlerWithOptions(strict, api.StdHTTPServerOptions{})

	mux := http.NewServeMux()
	mux.Handle("GET /healthz", http.HandlerFunc(httpkit.Healthz))
	mux.Handle("GET /readyz", httpkit.Readyz(pool.Ping, log))
	mux.Handle("GET /metrics", metrics.Handler())
	// The body guards wrap the API, not the probes: a probe has no body and must
	// answer routing before a media-type check sees it.
	mux.Handle("/api/", httpkit.BodyGuards(apiHandler))

	handler := httpkit.WithRequestID(
		httpkit.AccessLog(log,
			httpkit.Recoverer(log,
				httpkit.RequestDeadline(httpkit.RequestTimeout,
					httpkit.NoStore(metrics.Middleware(mux))))))

	log.Info("starting server", "addr", cfg.Addr, "environment", cfg.Environment)
	return server.Run(ctx, server.New(cfg.Addr, handler, log), server.DefaultGrace, log)
}
