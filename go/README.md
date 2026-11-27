# foundry/go

The runtime module every foundry app imports. It is the part of the request path
that is identical across apps: configuration, the HTTP shell, probes, metrics,
the database pool and the migration runner. There are no domain types here.

```
github.com/saxeum/foundry/go
```

## Packages

| Package | What it owns |
|---|---|
| `config` | environment → `Config`, validated at startup; the one logger constructor |
| `httpkit` | request id, access log, panic recovery, request deadline, `no-store`, body guards, client IP, `/healthz`, `/readyz`, `/metrics` |
| `migrate` | discovery, checksums, advisory lock, per-file transaction, `-status`-style report |
| `postgres` | the pool, with `statement_timeout` and `lock_timeout` on every connection |
| `server` | the HTTP server with every timeout named, and the drain on shutdown |

## Wiring

```go
cfg, err := config.FromEnv()
if err != nil {
	log.Fatal(err)
}
log := cfg.Logger(os.Stdout)

pool, err := postgres.NewPool(ctx, cfg.DatabaseURL)
if err != nil {
	log.Fatal(err)
}
defer pool.Close()

metrics := httpkit.NewMetrics()

mux := http.NewServeMux()
mux.Handle("GET /healthz", http.HandlerFunc(httpkit.Healthz))
mux.Handle("GET /readyz", httpkit.Readyz(pool.Ping, log))
mux.Handle("GET /metrics", metrics.Handler())
mux.Handle("/api/", apiHandler)

handler := httpkit.WithRequestID(
	httpkit.AccessLog(log,
		httpkit.Recoverer(log,
			httpkit.RequestDeadline(httpkit.RequestTimeout,
				httpkit.NoStore(metrics.Middleware(mux))))))

srv := server.New(cfg.Addr, handler, log)
if err := server.Run(ctx, srv, server.DefaultGrace); err != nil {
	log.Error("fatal", "err", err)
	os.Exit(1)
}
```

`httpkit.BodyGuards` wraps the API mux, not the probes: a probe has no body and
must answer 405/404 before a media-type check sees it.

## Metrics

`httpkit.Metrics` registers exactly the names in `docs/app-contract.md`:

- `http_requests_total{method,route,status}`
- `http_request_duration_seconds{method,route}`

`route` is `r.Pattern` (`GET /api/snippet/{id}`) or `unmatched`, never the raw
path or an id. That is what bounds cardinality.

## Testing

```
make platform-go-lint
```

```
make platform-go-test
```

Both run from the repository root. The module's database migration tests run
when `TEST_DATABASE_URL_OWNER` is set; they skip under `-short`, which is what CI
runs.

## Versioning

A nested module is tagged `go/vX.Y.Z`. An app requires
`github.com/saxeum/foundry/go vX.Y.Z` and bumps it like any dependency; a
breaking change to an exported identifier is a major version.

## Not here

Sessions, ownership, HTTP handlers, OpenAPI generation and the domain. Those are
the app's, and the template in `templates/app` is where they start.
