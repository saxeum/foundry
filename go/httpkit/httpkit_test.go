package httpkit

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRecovererAnswersJSON500AndKeepsServing(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, nil))

	mux := http.NewServeMux()
	mux.HandleFunc("GET /boom", func(http.ResponseWriter, *http.Request) { panic("kaboom") })
	mux.HandleFunc("GET /fine", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })
	handler := Recoverer(logger, mux)

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/boom", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got)
	}
	if body := rec.Body.String(); !strings.Contains(body, "internal server error") {
		t.Errorf("body = %q, want the generic 5xx body", body)
	}
	if !strings.Contains(logs.String(), "panic recovered") {
		t.Errorf("log = %q, want a panic line", logs.String())
	}

	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/fine", nil))
	if rec.Code != http.StatusOK || rec.Body.String() != "ok" {
		t.Fatalf("after a panic: status = %d body = %q, want 200 ok", rec.Code, rec.Body.String())
	}
}

func TestRecovererLetsAbortHandlerThrough(t *testing.T) {
	handler := Recoverer(slog.New(slog.DiscardHandler), http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic(http.ErrAbortHandler)
	}))

	defer func() {
		if recovered := recover(); recovered != http.ErrAbortHandler {
			t.Fatalf("recovered = %v, want ErrAbortHandler to propagate", recovered)
		}
	}()
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))
}

func TestRequestDeadlineReachesTheHandler(t *testing.T) {
	handler := RequestDeadline(10*time.Millisecond, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
		if !errors.Is(r.Context().Err(), context.DeadlineExceeded) {
			t.Errorf("ctx.Err() = %v, want DeadlineExceeded", r.Context().Err())
		}
		w.WriteHeader(http.StatusGatewayTimeout)
	}))

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusGatewayTimeout {
		t.Fatalf("status = %d, want 504", rec.Code)
	}
}

func TestRequestDeadlineRespectsAnEarlierCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	handler := RequestDeadline(time.Minute, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !errors.Is(r.Context().Err(), context.Canceled) {
			t.Errorf("ctx.Err() = %v, want Canceled", r.Context().Err())
		}
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodGet, "/", nil).WithContext(ctx)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rec.Code)
	}
}

func TestRequestIDPreservesASafeIncomingID(t *testing.T) {
	handler := WithRequestID(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := RequestIDFromContext(r.Context()); got != "abc-123_def.ghi:jkl" {
			t.Errorf("context id = %q", got)
		}
	}))

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("X-Request-ID", "abc-123_def.ghi:jkl")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if got := rec.Header().Get("X-Request-ID"); got != "abc-123_def.ghi:jkl" {
		t.Errorf("response id = %q, want the incoming value", got)
	}
}

func TestRequestIDGeneratesForMissingOrUnsafeValues(t *testing.T) {
	for _, incoming := range []string{"", "bad space", "quote\"", strings.Repeat("a", 129)} {
		t.Run(incoming, func(t *testing.T) {
			var got string
			handler := WithRequestID(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
				got = RequestIDFromContext(r.Context())
			}))
			req := httptest.NewRequest(http.MethodGet, "/", nil)
			if incoming != "" {
				req.Header.Set("X-Request-ID", incoming)
			}
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)

			if got == "" || got == incoming {
				t.Fatalf("generated id = %q, incoming = %q", got, incoming)
			}
			if strings.ContainsAny(got, " \"") {
				t.Errorf("generated id %q contains an unsafe character", got)
			}
		})
	}
}

func TestAccessLogRecordsOneLine(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, nil))

	mux := http.NewServeMux()
	mux.HandleFunc("GET /thing", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte("hello"))
	})
	handler := WithRequestID(AccessLog(logger, mux))

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/thing", nil))

	line := logs.String()
	for _, want := range []string{"msg=request", "method=GET", "route=\"GET /thing\"", "status=201", "bytes=5", "request_id="} {
		if !strings.Contains(line, want) {
			t.Errorf("log = %q, missing %q", line, want)
		}
	}
	if strings.Count(strings.TrimSpace(line), "\n") != 0 {
		t.Errorf("log has more than one line: %q", line)
	}
}

func TestAccessLogLevelFollowsTheStatus(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug}))

	handler := AccessLog(logger, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))

	if !strings.Contains(logs.String(), "level=ERROR") {
		t.Errorf("log = %q, want ERROR for a 5xx", logs.String())
	}
}

func TestNoStoreSetsTheHeader(t *testing.T) {
	rec := httptest.NewRecorder()
	NoStore(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Errorf("Cache-Control = %q, want no-store", got)
	}
}

func TestBodyGuards(t *testing.T) {
	t.Run("json passes", func(t *testing.T) {
		rec := httptest.NewRecorder()
		BodyGuards(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusNoContent)
		})).ServeHTTP(rec, requestWithBody("application/json", `{}`))
		if rec.Code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204", rec.Code)
		}
	})

	t.Run("json with charset passes", func(t *testing.T) {
		rec := httptest.NewRecorder()
		BodyGuards(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusNoContent)
		})).ServeHTTP(rec, requestWithBody("application/json; charset=utf-8", `{}`))
		if rec.Code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204", rec.Code)
		}
	})

	t.Run("text/plain is 415", func(t *testing.T) {
		rec := httptest.NewRecorder()
		BodyGuards(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			t.Fatal("handler ran for a non-JSON body")
		})).ServeHTTP(rec, requestWithBody("text/plain", "hello"))
		if rec.Code != http.StatusUnsupportedMediaType {
			t.Fatalf("status = %d, want 415", rec.Code)
		}
	})

	t.Run("oversize is detected by the reader", func(t *testing.T) {
		body := strings.Repeat("x", MaxBodyBytes+1)
		var tooLarge bool
		BodyGuards(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, err := io.Copy(io.Discard, r.Body)
			tooLarge = IsBodyTooLarge(err)
			w.WriteHeader(http.StatusNoContent)
		})).ServeHTTP(httptest.NewRecorder(), requestWithBody("application/json", body))
		if !tooLarge {
			t.Fatal("reading past the limit did not return MaxBytesError")
		}
	})
}

func requestWithBody(contentType, body string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))
	req.Header.Set("Content-Type", contentType)
	return req
}

func TestProbes(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)

	rec := httptest.NewRecorder()
	Healthz(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK || rec.Body.String() != "ok\n" {
		t.Fatalf("healthz = %d %q", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	Readyz(func(context.Context) error { return nil }, logger).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rec.Code != http.StatusOK || rec.Body.String() != "ok\n" {
		t.Fatalf("readyz = %d %q", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	Readyz(func(context.Context) error { return errors.New("database down") }, logger).
		ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz failure = %d, want 503", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
}

func TestMetricsRecordsTheContractNames(t *testing.T) {
	metrics := NewMetrics()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /thing", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.Handle("GET /metrics", metrics.Handler())
	handler := metrics.Middleware(mux)

	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/thing", nil))

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := rec.Body.String()

	for _, want := range []string{"http_requests_total", "http_request_duration_seconds"} {
		if !strings.Contains(body, want) {
			t.Errorf("/metrics missing %q", want)
		}
	}
	if !strings.Contains(body, `route="GET /thing"`) {
		t.Errorf("/metrics did not label the registered route: %s", body)
	}
}
