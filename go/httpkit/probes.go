package httpkit

import (
	"context"
	"log/slog"
	"net/http"
	"time"
)

// Healthz says the process is alive. It must not touch the database: a database
// blip is not a reason to restart the container.
func Healthz(w http.ResponseWriter, _ *http.Request) {
	_, _ = w.Write([]byte("ok\n"))
}

// Readyz says the server can serve real traffic, so it does touch the database.
// The ready function is the app's; the shape, timeout and response are the
// platform's.
func Readyz(ready func(ctx context.Context) error, log *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), time.Second)
		defer cancel()

		if err := ready(ctx); err != nil {
			log.Error("readiness check failed",
				"request_id", RequestIDFromContext(r.Context()),
				"err", err,
			)
			WriteJSON(w, http.StatusServiceUnavailable, ErrorBody(http.StatusServiceUnavailable))
			return
		}

		_, _ = w.Write([]byte("ok\n"))
	}
}
