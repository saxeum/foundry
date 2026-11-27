# __APP_NAME__

An app from the foundry template. `scripts/new-app.sh` in the platform repo
copied this directory and replaced `__APP_NAME__`; the rest is yours.

## First steps

1. Set `image.repository` in `deploy/api/values.yaml` to the app's ECR
   repository.
2. Create the app with the platform: ECR repositories and the OIDC push role
   (`terraform/registry`), the database and roles (`scripts/onboard-app.sh`),
   and the Argo registry entry + AppProject.
3. Set `AWS_PUSH_ROLE_ARN` and `ECR_REGISTRY` as repository variables.
4. Push to `main`. The workflow tests, renders against the chart release,
   publishes by SHA, and opens the dev digest PR.

## Local

```
make test
```

```
make conformance
```

`conformance` needs Helm and fetches the foundry chart at the version in
`deploy/api/values.yaml`. In the platform repo, run it as
`make conformance APP=demo`; in an instantiated app the name is filled in. It renders the same values Argo will, so a platform
contract change fails here before a deploy.

```
make build
```

```
make image
```

## Layout

| Path | |
|---|---|
| `spec/openapi.yaml` | the wire contract; `make codegen` rewrites `internal/api/openapi.gen.go` |
| `internal/api/` | the strict handler and its tests |
| `cmd/web/` | config → pool → generated contract → platform middleware → server |
| `cmd/migrate/` | the embedded migration runner; `/app-migrate` in the image |
| `migrations/` | forward-only SQL, checksummed by the runner |
| `deploy/api/` | app values only: `platform`, `image`, `app` |

The image is distroless and nonroot. `/healthz`, `/readyz` and `/metrics` come
from `foundry/go/httpkit`; the migration Job comes from the chart.

This template has no SPA, so the platform registry entry for it sets
`web: false`. An app with a UI adds `deploy/web/` and the web chart source is
the same pattern.
