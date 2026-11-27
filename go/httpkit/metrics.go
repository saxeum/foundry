package httpkit

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics is the app's Prometheus surface. The names are the app contract's:
// http_requests_total and http_request_duration_seconds, labelled by method,
// route and status. Route is the registered pattern, never the raw path, so
// cardinality is bounded.
type Metrics struct {
	registry *prometheus.Registry
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
}

// NewMetrics builds a registry with the Go and process collectors plus the two
// contract metrics. Each app process has its own registry; nothing here uses
// the global default.
func NewMetrics() *Metrics {
	registry := prometheus.NewRegistry()
	registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	requests := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "HTTP requests by method, route and status.",
	}, []string{"method", "route", "status"})

	duration := prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency by method and route.",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "route"})

	registry.MustRegister(requests, duration)

	return &Metrics{registry: registry, requests: requests, duration: duration}
}

// Handler serves the registry in the Prometheus text format. Point the
// ServiceMonitor's /metrics path at it.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{})
}

// Middleware records one sample per completed request. It sits outside the
// handler and inside the request id and access-log layers.
func (m *Metrics) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &responseRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)

		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}

		status := rec.statusOrOK()
		m.requests.WithLabelValues(r.Method, route, strconv.Itoa(status)).Inc()
		m.duration.WithLabelValues(r.Method, route).Observe(time.Since(start).Seconds())
	})
}
