# App contract — foundry v1

What an application must implement to run on foundry, and what the platform
promises in return. If the app does this and nothing else, the chart, the edge,
the alarms and the promotion flow work.

The contract is enforced by `charts/app-api`, `charts/app-web` and the
conformance render in the app's CI. When this document and a chart disagree, the
chart is wrong.

## 1. Image

- One image for the API, carrying two binaries: `/app-api` and `/app-migrate`.
- Distroless or equivalent: no shell, no package manager, no writable root
  filesystem. The chart runs it as nonroot with `seccompProfile:
  RuntimeDefault`, `allowPrivilegeEscalation: false` and all capabilities
  dropped.
- Stateless. No local disk, no in-memory session that another replica needs.
- A `sha256` digest. A tag is rejected by the chart; the promotion flow writes a
  digest and nothing else.
- The web image, if the app has a UI, serves static files on port `8080` and has
  no API logic.

## 2. Endpoints

| Path | Port | Contract |
|---|---|---|
| `GET /healthz` | `PORT` | `200` when the process is alive. **Never** touches the database or another dependency. A dependency outage must not restart the process. |
| `GET /readyz` | `PORT` | `200` only when the app can serve real traffic. Touches the database with a short timeout. `503` otherwise. |
| `GET /metrics` | `PORT` | Prometheus text. Required from day one. |

Probes are unauthenticated and must not be rate-limited. They are reached by the
kubelet and the ALB target group, never by the public ingress.

## 3. Environment

The chart sets these; the app reads them and fails fast if a required one is
missing.

| Variable | Source | Meaning |
|---|---|---|
| `PORT` | chart | listen port, `4000` for the API |
| `LOG_LEVEL` | environment values | `debug`, `info`, `warn`, `error` |
| `LOG_FORMAT` | environment values | `json` (containers), `text` (local only) |
| `TRUSTED_ORIGINS` | chart, from the ingress host | exact origins allowed to make cookie-authenticated writes |
| `APP_NAME` | chart | the app name from the registry |
| `APP_ENV` | chart | `dev`, `staging`, or the environment name |
| `DATABASE_URL` | Secret | the application role's DSN, `sslmode=verify-full` |
| `DATABASE_URL_OWNER` | Secret, migrate container only | the owner DSN; never mounted into the serving container |

The app owns its own feature flags and any other `app.env` entries. It must not
invent a second way to receive configuration.

## 4. Secrets

- Declared by name in `app.secrets`; never in values, never in the repository.
- Rendered as `valueFrom.secretKeyRef`, so the value does not appear in the pod
  spec.
- The database CA is mounted from `caSecret` at `/certs/global-bundle.pem`; the
  DSN points at it.
- A secret must never be logged. Request logs carry `request_id`, not headers or
  bodies.

## 5. Migrations

- `/app-migrate` is embedded in the same image as `/app-api`, so the schema and
  the binary cannot be different versions.
- It reads `DATABASE_URL_OWNER`, is forward-only, records a checksum per applied
  file, and takes an advisory lock so two runners cannot race.
- It runs as an Argo PreSync hook, before the Deployment is updated. A failed
  migration fails the sync; the old pods keep serving the old schema.
- There are no down migrations. A reversal is a new forward migration.

## 6. Lifecycle

- On `SIGTERM`: stop accepting new work, finish in-flight requests, then exit.
- The chart sets `terminationGracePeriodSeconds`; the ALB target group's
  deregistration delay is 15 seconds, so it stops sending before the grace
  period ends. There is no `preStop` shell — the image is distroless — so the
  app's own `SIGTERM` handling is the drain.
- Readiness must go `503` as soon as the app stops accepting work.
- No request is cut before the grace period; a request that outlives it is a
  slow request, not a crash.

## 7. Logs

One JSON object per line on stdout. Every request line carries:

```json
{"level":"INFO","time":"...","msg":"request","request_id":"...","method":"GET","route":"GET /api/snippet","status":200,"duration":1234567,"bytes":512}
```

- `X-Request-ID` is preserved when it is safe and generated otherwise; it is
  echoed on the response and on the 5xx line.
- No secrets, cookies, authorization headers or request bodies.
- Log level comes from `LOG_LEVEL`; a `debug` line must cost nothing at `info`.

## 8. Metrics

Prometheus names the chart's alarms read. Expose them on `/metrics`:

| Metric | Type | Labels |
|---|---|---|
| `http_requests_total` | counter | `method`, `route`, `status` |
| `http_request_duration_seconds` | histogram | `method`, `route` |

`route` is the registered pattern (`GET /api/snippet/{id}`), not the raw path, so
cardinality is bounded. The app must not label by user, session, id or title.

The chart defines alarms on a 5xx ratio, p99 latency, restart count and
unavailable replicas. They are off until the observability stack installs their
CRDs (P7); the environment values turn them on.

## 9. Data and behaviour

- Every row belongs to the session's user. Another user's id is `404`, not
  `403`.
- Lists are paginated with a bounded default. An unbounded list is an OOM in a
  chart with a memory limit.
- Input is validated in the service, not only in the transport. Every rejected
  field is reported at once with its JSON name.
- Expiry is enforced in the query, not only displayed.

## 10. What the platform supplies

- Namespace `<app>-<env>`, NetworkPolicy, Pod Security Admission `restricted`.
- Ingress on the shared ALB, TLS, WAF in count mode, access logs.
- External Secrets, the RDS CA, the per-app database and roles.
- Migration hook, PDB, ServiceMonitor, PrometheusRule.
- Deploy and promotion: dev digest auto-merged on one path, staging by human PR,
  prod pinned in the registry.

## 11. What the app repo supplies

- `deploy/api/values.yaml` + `deploy/api/values-<env>.yaml`, and the same under
  `deploy/web/`, containing only `platform`, `image` and `app`.
- The Dockerfile, the OpenAPI spec and the generated client, the UI.
- Tests: unit, integration against Postgres, and e2e through the LB.
- The conformance render in CI, against the chart version it declares.

## 12. Versioning

This document is the contract's version. A breaking change — a required endpoint,
variable or metric — is a major platform release and an entry in the upgrade
notes. Adding an optional value is a minor release.
