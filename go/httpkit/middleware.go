// Package httpkit is the request path shared by every foundry app: request ids,
// access logs, panic recovery, request deadlines, cache headers, body guards and
// the two probes. It owns HTTP mechanics and nothing about a domain.
package httpkit

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strconv"
	"time"
)

// RequestTimeout bounds one request end to end, from the moment the router hands
// it over to the moment the handler returns.
//
// It must exceed the database statement timeout (postgres.StatementTimeout, 5s)
// so a slow query surfaces as a database error that names the cause. If the
// request deadline fired first, every slow query would look identical and the
// log would say only "deadline exceeded".
const RequestTimeout = 15 * time.Second

// Request ids are how a report from a user becomes a line in the log. The header
// is accepted when it is safe and generated otherwise, so an upstream proxy's id
// survives and a random client cannot inject one.
const (
	requestIDHeader    = "X-Request-ID"
	maxRequestIDLength = 128
)

type requestIDKey struct{}

// RequestIDFromContext returns the id the middleware assigned, or "".
func RequestIDFromContext(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey{}).(string)
	return id
}

// WithRequestID preserves a safe incoming id and generates one otherwise. It
// echoes the id on the response so a client can quote it.
func WithRequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get(requestIDHeader)
		if !validRequestID(id) {
			id = newRequestID()
		}

		w.Header().Set(requestIDHeader, id)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), requestIDKey{}, id)))
	})
}

func validRequestID(id string) bool {
	if len(id) == 0 || len(id) > maxRequestIDLength {
		return false
	}
	for _, c := range id {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '-', c == '_', c == '.', c == ':':
		default:
			return false
		}
	}
	return true
}

func newRequestID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand failing is a broken host, not a reason to drop the
		// request. A timestamp still gives the log line an identity.
		return strconv.FormatInt(time.Now().UnixNano(), 10)
	}
	return hex.EncodeToString(b[:])
}

// responseRecorder is the smallest wrapper that can report a status and a byte
// count. Unwrap keeps ResponseController's Flush and deadline paths working.
type responseRecorder struct {
	http.ResponseWriter
	status  int
	written bool
	bytes   int
}

func (r *responseRecorder) WriteHeader(status int) {
	if r.written {
		return
	}
	r.status = status
	r.written = true
	r.ResponseWriter.WriteHeader(status)
}

func (r *responseRecorder) Write(p []byte) (int, error) {
	if !r.written {
		r.WriteHeader(http.StatusOK)
	}
	n, err := r.ResponseWriter.Write(p)
	r.bytes += n
	return n, err
}

func (r *responseRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

func (r *responseRecorder) statusOrOK() int {
	if r.status == 0 {
		return http.StatusOK
	}
	return r.status
}

// AccessLog emits exactly one line per completed request. It sits outside the
// recoverer, so a panic that became a 500 is logged with the status the client
// received.
func AccessLog(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &responseRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)

		route := r.Pattern
		if route == "" {
			route = r.URL.Path
		}

		attrs := []any{
			"request_id", RequestIDFromContext(r.Context()),
			"method", r.Method,
			"route", route,
			"status", rec.statusOrOK(),
			"duration", time.Since(start),
			"bytes", rec.bytes,
		}
		if rec.statusOrOK() >= http.StatusInternalServerError {
			log.Error("request", attrs...)
			return
		}
		log.Info("request", attrs...)
	})
}

// Recoverer turns a panic into the platform's 500 and keeps the process
// serving. Without it, a panic is caught by net/http, which closes the
// connection with no body and writes to http.Server.ErrorLog — a different
// stream in a different format.
func Recoverer(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			recovered := recover()
			if recovered == nil {
				return
			}

			// ErrAbortHandler is how a handler asks for the connection to be
			// aborted, and net/http handles it itself.
			if recovered == http.ErrAbortHandler {
				panic(recovered)
			}

			log.Error("panic recovered",
				"request_id", RequestIDFromContext(r.Context()),
				"panic", recovered,
				"stack", string(debug.Stack()),
				"method", r.Method,
				"uri", r.URL.RequestURI(),
			)
			WriteJSON(w, http.StatusInternalServerError, ErrorBody(http.StatusInternalServerError))
		}()

		next.ServeHTTP(w, r)
	})
}

// RequestDeadline puts a deadline on the request context, so a handler blocked
// on the database is cancelled by the server rather than by the client leaving.
//
// It is the context, not http.TimeoutHandler: pgx watches the context and stops
// the query, whereas a timeout handler answers the client and leaves the query
// running.
func RequestDeadline(timeout time.Duration, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), timeout)
		defer cancel()

		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// NoStore marks every response this server writes as uncacheable. The bodies are
// one user's data and the probes are meaningless to cache, so there is one rule
// rather than a path test.
func NoStore(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}
