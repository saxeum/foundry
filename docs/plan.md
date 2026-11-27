# foundry — platform plan

**Status:** draft 0.1 · 2026-11-27
**Owner:** saxeum
**Repos:** `foundry` (this), `app1` (reference app), `godough` (legacy, frozen)

This file states the plan and the decisions. Evidence for a phase — the command
output and the SHA it ran against — belongs in the PR or comment that closed it,
not here. When a decision changes, change it here; do not leave a comment saying
so.

`godough` is the application the platform was extracted from. It is frozen at its
current HEAD and nothing in `foundry` imports, vendors or submodules it. Files
are copied in, reviewed and adapted; history is not shared.

---

## 0. What foundry is

foundry is the platform: the Terraform, one generic Helm chart set, the Argo CD
tree, the runtime Go module, the app template and the operational baseline.
`app1` is the reference application built on it.

The supported profile is deliberately narrow:

> A Go HTTP API, Postgres, OIDC sign-in, an optional static SPA, one region, one
> cluster. Anything outside that is a new decision, not a configuration flag.

The platform's promise, stated as four tests:

1. **Same image, every tier.** Only the envelope changes between `poc`,
   `internal` and `external`.
2. **The app team owns its repo.** Its tests, its CI, its image digest, and
   promotion to dev and staging.
3. **A fix reaches every app as a version bump**, not a re-copy: chart by tag,
   Go code by module, infra by platform PR.
4. **A new app is a template instantiation**, not a rename of a hundred files.
   The measure is hours and files to first green e2e.

---

## 1. Scope and non-goals

| Capability | Now | Trigger to add |
|---|---|---|
| Go API + Postgres + OIDC + static SPA | supported | — |
| One region, one cluster, dev + staging | supported | first external customer → prod account |
| PoC / internal / external tiers | profiles, same image | — |
| Metrics, logs, alarms per app | baseline (P7) | — |
| Multi-region, active-active | no | contractual RTO < 1h |
| Service mesh, mTLS between pods | no | > 5 services or a compliance requirement |
| Polyglot runtimes | no | a real app that cannot be Go |
| Event bus / async workloads | no | first async use case |
| Multi-tenant organisations | no (per-user ownership only) | first team/org customer |
| Scale-to-zero | no | a PoC tier that must cost ~$0 |
| On-call rotation for PoC | no | external tier |

**Non-goals are part of the product.** A platform that says "we do CRUD +
Postgres + OIDC + one region" is usable; one that says "we do anything" is not.

---

## 2. Repos and the three links

```
        foundry (platform)                         app1 (product)
  terraform/ · charts/ · argocd/              cmd/ · internal/ · spec/
  environments/ · profiles/                   ui/ · migrations/
  templates/app/ · go/                        deploy/values*.yaml
  docs/app-contract.md                        .github/workflows/
              │                                        │
              │  1. chart, by tag  ◄───────────────────┤ conformance render
              │  2. ECR repo + OIDC push role ◄────────┤ CI push
              │  3. Argo reads app repo ───────────────►│ deploy/values*.yaml
              ▼                                        ▼
                     cluster: dev, staging (namespaces <app>-<env>)
```

| # | Link | Direction | Credential | If it breaks |
|---|---|---|---|---|
| 1 | chart at `vX.Y.Z` | app reads foundry | none — `foundry` is public | app CI conformance fails, deploy stops |
| 2 | ECR repo + push role | app writes ECR | GitHub OIDC, scoped per app | image publish fails |
| 3 | Argo reads app values | platform reads app | Argo repo credential (deploy key or GitHub App) | app stops syncing |

There is no fourth link. The app never holds cluster credentials, Terraform
credentials or platform secrets.

---

## 3. Naming and conventions

| Thing | Convention | Example |
|---|---|---|
| Platform repo | `foundry` | `~/soper/foundry`, `github.com/saxeum/foundry` |
| App repos | the product name | `app1`, `godough` |
| Go module | `github.com/saxeum/foundry/go` (nested, tag `go/vX.Y.Z`) | — |
| Chart release | platform semver tag `vX.Y.Z` | `v0.1.0` |
| Chart names | generic | `app-api`, `app-web` |
| Namespaces | `<app>-<env>` | `app1-dev`, `app1-staging` |
| Argo Application | `<app>-<env>` | `app1-staging` |
| AppProject | `<app>` | `app1` |
| ECR images | `<app>-api`, `<app>-web` | `app1-api` |
| ECR chart repo | `foundry-charts` (only if private) | — |
| AWS resources | `foundry-<env>-<component>` | `foundry-staging-rds` |
| Account-global | `foundry-<thing>` | `foundry-alerts`, `foundry-terraform-state-<account>`, `foundry-alb-logs-<account>` |
| App DB | `<app>`; roles `<app>_owner`, `<app>_app` | `app1`, `app1_app` |
| DNS | `<app>.<zone>` | `app1.foonix.net` |
| Terraform state | `s3://foundry-terraform-state-<account>/<stack>/terraform.tfstate` | — |

Lowercase, hyphens in DNS and AWS, underscores in Postgres. No resource is named
after a person. No `latest` tag anywhere a digest can be pinned.

---

## 4. The contract

### 4.1 Registry: one file per app

`argocd/apps/<app>.yaml`. One file per app, not a list, because Argo's git file
generator yields one parameter map per file. Adding an app is one new file and a
platform PR.

```yaml
# argocd/apps/app1.yaml
name: app1
repo: https://github.com/saxeum/app1.git
revision: main
namespace: app1
chart: app-api
chartVersion: "0.1.0"          # platform release tag; the upgrade pin
tier: internal                 # poc | internal | external
environments: [dev, staging]
imageRepository: 000000000000.dkr.ecr.ap-southeast-2.amazonaws.com/app1-api
database: app1
owners: [saxeum]
```

### 4.2 App values: two keys only

`app1/deploy/values.yaml` and `app1/deploy/values-<env>.yaml` may contain only
`platform`, `image` and `app`. Envelope keys are rejected — the chart schema
validates the merged result and the env values are applied last, so a rogue key
cannot win; the app CI also checks the key set.

```yaml
# deploy/values.yaml
platform:
  chartVersion: "0.1.0"        # must equal argocd/apps/app1.yaml
app:
  metrics:
    enabled: true
  env:
    FEATURE_EXAMPLE: "on"
  secretRefs:
    - name: app1-api
      keys: [DATABASE_URL]
```

```yaml
# deploy/values-dev.yaml — the only file CI writes
image:
  digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
```

### 4.3 Environment values: the envelope

`environments/<env>/values.yaml` is platform-owned. It sets replicas, resources,
ingress, WAF, PDB, NetworkPolicy, alarm thresholds, log level and probes.

`profiles/<tier>/values.yaml` overlays a tier on top. Precedence, lowest to
highest:

```
chart defaults
  < app/deploy/values.yaml
  < app/deploy/values-<env>.yaml
  < profiles/<tier>/values.yaml
  < environments/<env>/values.yaml        # platform always wins
```

Argo applies `valueFiles` in order and the last wins. This is an assumption to
verify in P3, not a guess to ship.

### 4.4 Runtime contract

Every app implements this, or it is not an app:

| Surface | Contract |
|---|---|
| `GET /healthz` | 200 when the process is alive. Never touches the database. |
| `GET /readyz` | 200 only when the app can serve; touches the database. |
| `GET /metrics` | Prometheus text; required from day one. |
| `PORT` / `SNIPPET_ADDR` | the chart passes one listen address |
| `DATABASE_URL` | from a Secret, `sslmode=verify-full` |
| `TRUSTED_ORIGINS` | platform-injected from the environment's host; the app does not set it |
| logs | one JSON line per request: `request_id`, `method`, `route`, `status`, `duration`, `bytes` |
| shutdown | drain on SIGTERM; no request cut before `terminationGracePeriodSeconds` |

The full document is `docs/app-contract.md`, written in P2 before the first app.

### 4.5 Versioning

| Artefact | Scheme | Breaking change |
|---|---|---|
| Platform release (`vX.Y.Z`) | semver, one tag covers both charts | major: values schema or template contract |
| Go module (`go/vX.Y.Z`) | semver | major: exported API |
| Runtime contract | versioned in `docs/app-contract.md` | major: a required endpoint or env var |
| App values | chart schema | schema version bump |

Upgrades are pulled, never pushed: Renovate in the app repo bumps
`platform.chartVersion` and `foundry/go`; an app can lag without breaking.

---

## 5. Platform repo layout

```
foundry/
├── README.md
├── LICENSE
├── Makefile                     # terraform, chart, argocd, onboard
├── terraform/
│   ├── bootstrap/               # state bucket; creates or reads the GitHub OIDC provider
│   ├── alerts/                  # SNS, budget
│   ├── account/                 # GuardDuty, CloudTrail + KMS + bucket
│   ├── network/                 # VPC, subnets, single NAT, flow logs
│   ├── data/                    # RDS per env, param group, SG, subnet group
│   ├── cluster/                 # EKS, addons, IRSA, bastion, log shipping
│   ├── registry/                # ECR images + charts, per-app push role
│   ├── edge/                    # LBC, ACM wildcard, Cloudflare, ALB logs, WAF
│   └── argocd/                  # Argo install, pinned chart + values
├── charts/
│   ├── app-api/
│   └── app-web/
├── argocd/
│   ├── root/application.yaml
│   ├── apps/<app>.yaml          # the registry, one file per app
│   ├── apps/appset.yaml         # matrix(apps, environments)
│   └── projects/<app>.yaml      # AppProject per app
├── environments/
│   ├── dev/values.yaml
│   └── staging/values.yaml
├── profiles/
│   ├── poc/values.yaml
│   ├── internal/values.yaml
│   └── external/values.yaml
├── go/                          # github.com/saxeum/foundry/go
├── templates/app/               # the golden path
├── policies/                    # conftest, kubeconform, chart unit tests
├── scripts/                     # onboard-app, new-app, skew-check
└── docs/
    ├── plan.md                  # this file
    ├── app-contract.md
    ├── onboarding.md
    └── runbooks/
```

---

## 6. App repo layout

```
app1/
├── go.mod                       # requires github.com/saxeum/foundry/go
├── cmd/web/                     # config -> lifecycle -> routes
├── cmd/migrate/                 # embedded migrations
├── internal/domain/snippet/
├── internal/service/
├── internal/repository/postgres/
├── internal/transport/httpapi/
├── spec/openapi.yaml
├── migrations/*.sql
├── ui/
├── Dockerfile                   # /app-api and /app-migrate, distroless, nonroot
├── Makefile                     # test, lint, codegen-check, build, e2e
├── deploy/
│   ├── values.yaml
│   ├── values-dev.yaml
│   └── values-staging.yaml
├── .github/workflows/
│   ├── ci.yml
│   └── promote.yml
└── docs/
```

What is **not** in the app repo: Terraform, charts, Argo, cluster access, the RDS
CA bundle, the database bootstrap, the owner credential.

---

## 7. Terraform

### 7.0 Same account, no dependency on the old platform

foundry runs in the **existing** AWS account. The account is not empty: the
godough teardown is incomplete, and at 2026-11-28 the API still reports five
godough-named resources. The rule is that foundry depends on **neither their
presence nor their absence**; it creates what it needs.

| Resource | Present | Foundry response |
|---|---|---|
| GitHub OIDC provider | yes | `manage_oidc_provider = false` for the first apply, or delete it and use the default |
| VPC `10.42.0.0/16` (`godough-staging`) | yes | left alone; foundry uses `10.20.0.0/16` |
| ECR `godough-api`, `godough-web` | yes | left alone; foundry uses `app1-*` |
| `godough-terraform-state-<account>`, `alias/godough-terraform-state` | yes | left alone; foundry has its own bucket and key |
| EKS, RDS, ALB, GuardDuty, CloudTrail, SNS | no | foundry creates its own |
| Budgets `My Zero-Spend Budget`, `triage-dev-monthly` | yes (not godough's) | left alone; foundry adds `foundry-monthly` |

Rules:

- **The OIDC provider is the one collision.** AWS allows one per URL per
  account. `terraform/bootstrap` has `manage_oidc_provider`: true creates,
  false reads. A fresh account uses true; this account uses false until the
  survivor is deleted.
- **Foundry owns its detection.** `terraform/account` creates GuardDuty and a
  multi-region CloudTrail, because the account no longer has them. If a detector
  or trail exists when it is applied, import it or skip the stack with a
  recorded decision; do not create a second.
- **Residue is left alone.** Foundry does not delete, adopt or peer to
  `godough-*` resources. The VPCs do not overlap and the names do not collide.
- **Every foundry resource is `foundry-*`.**
- **The blast radius is the account.** One administrator role reaches
  everything. Acceptable for dev and staging; prod gets its own account.

The incremental cost is roughly **$180/month**: EKS control plane ~$73, NAT
~$37, ALB ~$16, two small RDS instances ~$30, nodes ~$30. The `foundry-monthly`
budget is the ceiling.

Trigger to revisit: the last godough-named resource is deleted (then this
section is only history), or prod exists (then the account boundary is real).

### 7.1 Stacks and state

One state bucket per platform, one key per stack, `use_lockfile = true`. The
bootstrap stack keeps local state — the bucket it creates cannot hold its own
lock — and that one local state is the single non-durable artefact, documented
in `terraform/bootstrap/README.md`.

| Stack | Owns | Depends on |
|---|---|---|
| `bootstrap` | state bucket; creates or reads the GitHub OIDC provider (7.0) | — |
| `alerts` | SNS topic, budget | bootstrap |
| `account` | GuardDuty, CloudTrail + KMS + bucket | bootstrap |
| `network` | VPC, subnets, NAT, flow logs | bootstrap |
| `data` | RDS per env, parameter group, SG | network |
| `cluster` | EKS, node group, addons, IRSA, bastion, log shipping | network |
| `registry` | ECR images + charts, per-app push role | bootstrap |
| `edge` | LBC, ACM `*.zone`, Cloudflare, ALB logs, WAF | cluster |
| `argocd` | Argo CD, pinned chart + values | cluster, edge |

### 7.2 Environments

`dev` and `staging` are provisioned. `prod` is **not** provisioned until there is
a real external customer; its profile exists so the first prod is a decision
about an account, not a redesign. Trigger: first external tier app.

One cluster (`foundry-staging`, independent of any earlier cluster), one VPC, one RDS instance per environment, one database per app. Isolation between apps is namespace + NetworkPolicy + AppProject, not an account. This is a deliberate staging-scale choice; prod will be its own account.

### 7.3 Data: per-app roles, no master DSN

`scripts/onboard-app.sh <app>` is run once by the platform, over the SSM tunnel,
with the master credential read from Secrets Manager. It is idempotent and:

1. creates database `<app>`;
2. creates `<app>_owner` (DDL) and `<app>_app` (DML), neither superuser;
3. grants `<app>_app` on the schema and default privileges;
4. writes `foundry/<env>/<app>/owner` and `foundry/<env>/<app>/app` to Secrets Manager.

The master credential never reaches the cluster. The owner DSN reaches it only
through External Secrets, scoped to the app's database, with rotation enabled.
This is the fix for godough's long-lived master DSN (SEC-TODO D2), not a port of it.

### 7.4 Registry

One ECR repo per image (`<app>-api`, `<app>-web`), immutable tags, scan on push,
lifecycle: untagged 7 days, keep 20 tagged. A per-app IAM role trusting
`repo:saxeum/<app>:ref:refs/heads/main`, scoped to `ecr:PutImage`,
`InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`,
`BatchCheckLayerAvailability` on `<app>-*` only. The role ARN is set on the app
repo as `vars.AWS_PUSH_ROLE_ARN`.

### 7.5 Edge

One ALB for all apps, `group.name: foundry`, `group.order` per app from the
registry. One wildcard ACM certificate for `*.<zone>` — not one per app, which
would make every onboarding a DNS validation wait. TLS 1.2/1.3 policy. ALB
access logs to S3 with a lifecycle rule. WAF regional ACL shared by all apps, in
**count** mode for dev and staging; the external tier is where it moves to block
after the logs have been read.

### 7.6 Argo CD

Installed by Terraform once, then left alone. Pinned chart, values in
`deploy/argocd/install`. The root Application is applied once by a human; the
app-of-apps handles the rest.

### 7.7 Detection, alerts and the budget

`account` owns the account-level record: GuardDuty and a multi-region
management-events trail with validation, KMS encryption and a one-year S3
lifecycle. Nothing else owns these now, so foundry creates them.

`alerts` owns the signal path: `foundry-alerts` (SNS, the destination for
Alertmanager and CloudWatch alarms), a `foundry-monthly` budget with actual and
forecast notifications, and the subscription from OQ-4. Security Hub and Config
stay deferred until there is a compliance requirement.

### 7.8 Onboarding an app

Documented in `docs/onboarding.md`, ten steps: create the repo from the template;
set `AWS_PUSH_ROLE_ARN` and `ECR_REGISTRY`; run `scripts/onboard-app.sh`; add
`argocd/apps/<app>.yaml` and `argocd/projects/<app>.yaml`; add the Argo repo
credential; merge; push the first image; open the dev digest PR; verify the
smoke; open the staging promotion PR.

---

## 8. The chart

Two charts, generic, no app names in them.

### 8.1 Rules

- `values.schema.json` is the contract. `additionalProperties: false`; `app.*`
  and `image.*` are the only app-writable objects.
- Every container: nonroot, `seccompProfile: RuntimeDefault`,
  `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, capabilities
  dropped.
- `image.digest` is required; a tag alone fails the template. Same guard as
  godough, kept.
- `automountServiceAccountToken: false` unless the app declares an IRSA role.
- The chart refuses to render an `external` tier with fewer than two replicas or
  without a PDB.

### 8.2 Templates

| Template | Enforces |
|---|---|
| `deployment.yaml` | security context, probes, resources, topology spread, grace period |
| `service.yaml` | one port, named |
| `ingress.yaml` | shared ALB group, order, TLS policy, health check path |
| `pdb.yaml` | `minAvailable: 1` when replicas > 1 |
| `networkpolicy.yaml` | default deny; DNS, DB, ingress from the VPC CIDR |
| `serviceaccount.yaml` | no automount by default |
| `externalsecret.yaml` | app-declared `secretRefs` only |
| `servicemonitor.yaml` | scrape `/metrics` on the named port |
| `prometheusrule.yaml` | 5xx ratio, p99, restarts, unavailable replicas |
| `migrate-job.yaml` | Argo PreSync hook, same digest, owner Secret, no retries |
| `namespace` bits | PSA `restricted` label is set by platform, asserted by policy |

### 8.3 The migrate Job

PreSync, `backoffLimit: 0`, `activeDeadlineSeconds`, the **same digest** as the
Deployment, the owner DSN only. A failed migration fails the sync and the
Deployment is never updated against a schema the code does not expect. Argo maps
Helm pre-upgrade hooks to PreSync; P3 verifies the ordering rather than assuming
it.

### 8.4 Tiers

| | poc | internal | external |
|---|---|---|---|
| replicas | 1 | 2 | 2+ |
| PDB | no | yes | yes |
| WAF | no | no | block |
| alarms | none | 5xx, restarts | 5xx, p99, restarts, DB, ALB |
| SLO | none | 99.5% | 99.9%, p99 < 500 ms |
| on-call | no | business hours | 24/7 |
| backup | PITR 7d | PITR 7d | PITR 30d + restore drill |

The image is identical in all three. That is the test.

---

## 9. Argo CD

### 9.1 Tree

```
root Application
  └── appset (ApplicationSet, matrix: argocd/apps/*.yaml × environments)
        └── <app>-<env> Application (multi-source)
              ├── chart: foundry @ v<chartVersion>, path charts/app-api
              ├── values: app repo deploy/values.yaml, values-<env>.yaml
              ├── values: foundry profiles/<tier>, environments/<env>
              └── destination: namespace <app>-<env>
```

### 9.2 AppProject per app

```yaml
spec:
  sourceRepos:
    - https://github.com/saxeum/foundry.git
    - https://github.com/saxeum/<app>.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: "<app>-*"
  clusterResourceWhitelist: []
```

An app cannot deploy into another app's namespace or create cluster-scoped
objects. This is the multi-tenancy boundary; it is not optional.

### 9.3 Sync

`automated: {selfHeal: true, prune: false}` for workloads, `prune: true` for the
root's definitions. Prune stays off where a bad values key would delete an
Ingress; the deliberate act is `make argocd-prune APP=…`, which says so. Retry
limit 5 with backoff.

### 9.4 Skew check

`scripts/skew-check.sh` asserts, for every registry entry, that the app's
declared `platform.chartVersion` equals the registry pin. Run nightly and on
every platform PR. A mismatch is a failed build, not a surprise rollout.

---

## 10. Promotion

```
merge to app1/main
  → CI: test, e2e, conformance, build, push by SHA
  → CI: open PR changing only deploy/values-dev.yaml
  → ruleset auto-merges that path when checks are green
  → Argo syncs app1-dev

manual promote workflow
  → PR changing only deploy/values-staging.yaml
  → human review and merge
  → Argo syncs app1-staging

prod (later)
  → digest pinned in argocd/apps/<app>.yaml
  → platform PR, human merge
```

**The one automation exception.** A digest bump may be auto-merged, and only
when: the PR touches exactly `deploy/values-dev.yaml`, every required check has
passed, and the diff is a single `image.digest` line. No agent merges code; no
automation writes to `main` in any other way. Humans merge staging and prod
promotions.

---

## 11. CI/CD

### 11.1 App CI (`ci.yml`)

| Job | Runs on | Does |
|---|---|---|
| `lint` | every PR | gofmt, staticcheck, oxlint |
| `test` | every PR | Postgres service, `go test -race`, coverage |
| `ui` | every PR | Vitest, Vite build |
| `codegen` | every PR | regenerate, fail on drift |
| `e2e` | every PR | compose stack, `scripts/e2e.sh` |
| `conformance` | every PR | `helm template` at the pinned chart tag + kubeconform + conftest + key-set check + skew check |
| `publish` | `main` | OIDC → ECR, build/push by SHA, capture digest |
| `dev-digest` | `main` | open the single-line `values-dev.yaml` PR |
| `promote` | manual | open the `values-staging.yaml` PR |

The app CI holds no cluster credential and no Terraform credential. The only AWS
permission is ECR push to `<app>-*`.

### 11.2 Platform CI

| Job | Does |
|---|---|
| `terraform` | `fmt -check`, `validate` per stack, `tflint`, Trivy config |
| `charts` | `helm lint`, `helm unittest`, `helm template` against every registry entry |
| `policy` | conftest: digest, nonroot, probes, no `:latest`, PSA |
| `argocd` | `kubeconform` on rendered manifests, `make check-argocd` |
| `release` | on tag: nothing to publish if the chart is consumed from git; OCI push if private |
| `skew` | nightly: registry vs app pins |
| `smoke` | post-merge: `argocd-verify`, probes, one authenticated read |

### 11.3 Conformance render

This is the job that makes the split safe. It runs the **same** render Argo will,
so a platform contract change fails in the app's CI before merge:

```bash
curl -fsSL "https://github.com/saxeum/foundry/archive/refs/tags/v${CHART_VERSION}.tar.gz" -o foundry.tgz
tar -xzf foundry.tgz
helm template app1 "./foundry-${CHART_VERSION}/charts/app-api" \
  -f deploy/values.yaml \
  -f "deploy/values-${ENV:-dev}.yaml" \
  -f "./foundry-${CHART_VERSION}/profiles/${TIER}/values.yaml" \
  -f "./foundry-${CHART_VERSION}/environments/${ENV:-dev}/values.yaml" \
  --set image.repository="example/${APP}-api" \
  --set image.digest="sha256:0000000000000000000000000000000000000000000000000000000000000000" \
  | kubeconform -strict -summary
```

### 11.4 Identity

- App push role: OIDC trust on `repo:saxeum/<app>:ref:refs/heads/main`, ECR
  scoped to `<app>-*`.
- Platform role: OIDC trust on `repo:saxeum/foundry:ref:refs/heads/main`, ECR
  chart push (if private), Terraform state bucket, and the account's stacks.
- Argo: one read-only deploy key or GitHub App per app repo, held in one place.
- No static AWS key in either repo, ever.

### 11.5 Branch rules and the invariant

App `main`: `lint`, `test`, `e2e`, `conformance` required; one approval; stale
approvals dismissed on push; up to date before merge; the dev-digest path
exempted from review but not from checks.

Platform `main`: `terraform`, `charts`, `policy` required; one approval; the same
up-to-date rule.

Author never verifies; verifier never merges; the human merges. The evidence for
"this works" is a comment with the SHA and the command output, not a claim in the
description.

---

## 12. Identity, secrets, data

- **External Secrets Operator** + AWS Secrets Manager. A `ClusterSecretStore`
  with IRSA, one permission set for the platform, per-app secret paths under
  `foundry/<env>/<app>/`.
- The app declares `secretRefs`; it never holds a secret value.
- **No master database credential in the cluster.** Per-app owner and app roles
  only; rotation enabled; the owner secret exists for the migration window and is
  the only long-lived privileged object, recorded as an accepted risk with a
  trigger to move to a short-lived credential.
- **Deletion protection** on RDS and the ALB; final snapshot enabled; PITR 7 days
  for dev/staging, 30 for external. Restore is a runbook with a drill, not a
  checkbox.
- **Retention**: sessions 7 days absolute, expired rows swept by a CronJob;
  snippet expiry enforced in the service from day one (#12 in godough was
  deferred; it is a contract here); account deletion and data export are
  requirements for the external tier.

---

## 13. Observability

Chosen stack, recorded as a decision (DR-008):

- **Metrics**: kube-prometheus-stack — Prometheus, Alertmanager, Grafana,
  kube-state-metrics, node-exporter. Portable, standard, one install.
- **App metrics**: `/metrics` + `ServiceMonitor` from the chart.
- **Logs**: Fluent Bit DaemonSet → CloudWatch Logs, 30-day retention. The app
  already writes one JSON line per request; the platform makes it durable.
- **Alerts**: `PrometheusRule` per app (5xx ratio, p99, restarts, unavailable
  replicas) plus RDS and ALB CloudWatch alarms. Alertmanager → SNS.
- **SLO**: external 99.9% availability and p99 < 500 ms; internal 99.5%; poc
  none. The number is in `environments/<env>/values.yaml`, so it is a policy, not
  a paragraph.
- **Runbooks**: one page per alarm, linked from the rule's annotation.

Rejected, with reasons: CloudWatch Container Insights + EMF (not portable, no
PromQL), Amazon Managed Prometheus/Grafana (~$90/month for a staging platform),
Loki (another stateful service for no present user).

Node sizing note: kube-prometheus-stack is 1–2 GB of the node; the node group is
sized for the platform, not just the app. A `t3.small` is not enough.

---

## 14. Migration from godough

| godough | foundry / app1 | How |
|---|---|---|
| `internal/config`, lifecycle, request ID, access log, recoverer, deadline, probes, migrate runner | `foundry/go` | copy, remove domain references, add metrics |
| `internal/{domain,service,repository,transport}`, `spec`, `ui`, `migrations` | `app1` | copy, change module path, add `/metrics`, add expiry filtering |
| `deploy/charts/api`, `ui` | `charts/app-api`, `app-web` | rewrite as generic; envelope in schema |
| `deploy/charts/*/values-staging.yaml` | split: envelope → `environments/`, image → app `deploy/` | rewrite |
| `deploy/argocd/*` | `argocd/*` | rewrite: registry per file, matrix, AppProjects |
| `infra/terraform/*` | `terraform/*` | copy, parameterize, split `app` into `edge` + `argocd`, add budgets/logs/metrics |
| `db/bootstrap.sql` | `scripts/onboard-app.sh` | rewrite: per-app DB + roles, no master DSN in the cluster |
| `scripts/e2e.sh` | `templates/app/scripts/e2e.sh` | copy |
| `nginx/lb.conf` | app-local `compose` only | stays in the app |
| `docs/{TODO,SEC-TODO,security-review}.md` | platform docs | rewrite; godough's copies are historical |
| `godough` itself | untouched | frozen |

What is deliberately **not** carried over: the count-mode WAF default (the
external tier blocks), the long-lived owner DSN, the single replica, the
`godough_*` names, the stale backlog docs, the 471 snippet references.

---

## 15. Phases and acceptance

Each phase is one branch in this repo, one PR, one verifier, one human merge.
Commands are run at the end of the phase; the expected result is described
outside the block.

### P0 — scaffold (this commit)

`README.md`, `LICENSE`, `.gitignore`, `docs/plan.md`, `git init -b main`.

```
find . -maxdepth 2 -type f | sort
```

Expect only the four files above and this plan.

### P1 — Terraform

Copy and adapt godough's stacks into `terraform/`: `bootstrap`, `account`,
`alerts`, `network`, `data`, `cluster`, `registry`, `edge`, `argocd`. State
bucket first; every other stack reads it. The same-account preflight comes
before any apply.

```
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text
aws cloudtrail describe-trails --query 'trailList[].Name' --output text
aws guardduty list-detectors --query 'DetectorIds' --output text
aws ec2 describe-vpcs --query 'Vpcs[].CidrBlock' --output text
aws eks list-clusters --query 'clusters' --output text
```

Expect the provider (or none, on a fresh account), no trail and no detector
unless a partial teardown left one, no `10.20.0.0/16`, and no `foundry-*`
cluster. A missing provider is fine; a second one is not. A second trail or
detector is a stop, not a retry.

```
terraform -chdir=terraform/network init -backend=false
terraform -chdir=terraform/network validate
```

Expect `Success! The configuration is valid.` Repeat per stack. A plan needs
credentials and the backend, and is the PR's evidence.

### P2 — charts

`charts/app-api`, `charts/app-web`, schema, migrate Job, PDB, NetworkPolicy,
ServiceMonitor, ExternalSecret, PrometheusRule. `docs/app-contract.md` written
before any app exists.

```
helm lint charts/app-api charts/app-web
helm unittest charts/app-api charts/app-web
```

Expect no failures. A render against a dummy app goes into the PR as output.

### P3 — Argo

Root, ApplicationSet, per-app AppProject, environments, profiles. Verify the
value precedence and the PreSync ordering; do not assume either.

```
make check-argocd
```

Expect a rendered diff for `app1-dev` and `app1-staging`, and a PreSync hook
before the Deployment in the sync result.

### P4 — platform-go

Extract config, lifecycle, httpkit (request ID, access log, recoverer, deadline,
no-store, body guards), probes, metrics and the migrate runner. A nested module,
tagged `go/v0.1.0`.

```
cd ../godough-copy && go test ./...
```

Expect the same green suite as `godough`, with imports swapped and the domain
untouched.

### P5 — template

`templates/app` plus `scripts/new-app.sh`. Includes CI, values, Dockerfile,
`/metrics`, the conformance job, and the single-line dev digest workflow.

```
./scripts/new-app.sh demo
cd ../demo && make test
```

Expect a new repo that compiles, passes unit tests, and renders against the
pinned chart with no edits beyond the app name.

### P6 — app1

Instantiate `~/soper/app1` from the template; copy the snippet domain from
`godough`; onboarding script; first image; dev sync; staging promotion.

```
make test
make e2e
make argocd-verify
```

Expect green tests, green e2e, Synced/Healthy for `app1-dev` and `app1-staging`.
Record in this file: **hours and files to instantiate** — the platform's real
benchmark.

### P7 — observability

Metrics, logs, alarms, SLO, runbooks. Prove an alarm can fire.

```
promtool check rules charts/app-api/templates/prometheusrule.yaml
```

Expect no rule errors, and a named alarm firing on a forced 5xx in the PR
evidence.

### P8 — hardening and onboarding

Per-app DB roles and ESO end to end; NetworkPolicy and PSA enforced; WAF block
for the external tier; budgets; restore drill; `docs/onboarding.md` run against
a second app.

```
conftest test --policy policies rendered/
```

Expect zero violations, and one deliberate failure recorded to prove the gate
can fail.

---

## 16. Decisions

| ID | Decision | Reason | Alternative rejected |
|---|---|---|---|
| DR-001 | Two repos + three links | App team owns its CI; platform owns the envelope | monorepo (one merge queue, one credential) |
| DR-002 | Chart owned by the platform, consumed by tag | Fixes reach every app; no fork | app-owned chart (drift) |
| DR-003 | App values limited to `image`, `app`, `platform` | Envelope cannot be overridden silently | free-form values (review cannot catch it) |
| DR-004 | Dev digest auto-merged on one path; staging/prod human | Velocity without weakening review | bot push to `main` (bypasses review) |
| DR-005 | `foundry/go` nested module | Security fixes propagate; two repos stay two | copy the code (drift) |
| DR-006 | ESO + per-app roles; no master DSN in cluster | Rotation, least privilege | master DSN in a Secret (godough D2) |
| DR-007 | Tiers as value overlays, same image | The platform's promise is testable | separate images (unverifiable) |
| DR-008 | kube-prometheus-stack + Fluent Bit + SNS | Portable, standard, one install | CloudWatch EMF (lock-in), AMP/AMG (cost) |
| DR-009 | One namespace per app per env; AppProject per app | The only real tenancy boundary | one namespace (no isolation) |
| DR-010 | dev+staging one account/cluster; prod deferred | No mechanism without a user | three accounts today (cost, no customer) |
| DR-011 | Chart consumed from the git tag (public repo) | No chart registry, no token refresh | OCI in ECR + CronJob (more moving parts) |
| DR-012 | WAF count in dev/staging, block in external | Read the logs before blocking | block everywhere (launch risk) |
| DR-013 | Same AWS account; foundry creates its own detection; OIDC provider is `manage_oidc_provider` (true creates, false reads) | No new account yet; the old account-global controls are gone | a second provider or trail (fails), a new account (cost, no customer) |
| DR-014 | Foundry VPC `10.20.0.0/16`, no peering | No overlap with the `10.42.0.0/16` residue | shared VPC (couples the platforms) |
| DR-015 | `account` owns GuardDuty/CloudTrail; `alerts` owns SNS/budget | Detection is no longer inherited; split by lifecycle | one stack (a trail change risks the bucket and key) |

---

## 17. Risks

| Risk | Mitigation | Trigger to revisit |
|---|---|---|
| Argo value precedence differs from the assumption | P3 verifies with a rendered diff | before app1 |
| Chart/values drift between repos | nightly skew check + app conformance | first mismatch |
| `platform-go` becomes a second product | only generic code; no domain; semver | an app needs a domain type in it |
| kube-prometheus-stack does not fit a small node | size the node group; measure | P7 memory headroom < 30% |
| Shared RDS is a noisy neighbour | per-env instance, per-app DB; measure | one app's load affects another |
| EKS control plane cost for PoC | profiles do not reduce the control plane; a cheap lane is a separate decision | first PoC that cannot pay $160/mo |
| Public foundry repo discloses topology | no secrets, no state, scrub account IDs from examples | a customer objects |
| Owner DSN is still long-lived | scoped per app, rotated, recorded | ESO CSI short-lived credentials |
| Migration Job and Argo hook ordering | PreSync verification in P3 | a schema/code mismatch in staging |
| Shared account with godough residue | prefixed names, separate VPC and cluster; prod in its own account | prod provisioning |
| OIDC provider already exists | `manage_oidc_provider=false`; the runbook preflight says which mode | first apply |
| A partial teardown leaves a detector or trail | `account` imports it or is skipped with a recorded decision | P1 preflight |
| Godough residue is deleted mid-flight | foundry never references it; only the OIDC mode changes | last godough resource |

---

## 18. Resolved questions

Resolved 2026-11-28. OQ-5 is a standing trigger, not a question.

| # | Question | Answer |
|---|---|---|
| OQ-1 | Is `foundry` public? | **public.** Chart consumed from the git tag; account IDs scrubbed; no secrets or state in the repo. |
| OQ-2 | New AWS account, or the existing one? | **existing account**, which still has godough residue. Foundry is independent of it; the OIDC provider is the one shared object. See 7.0. |
| OQ-3 | Zone | **`<app>.foonix.net`**, one wildcard certificate. |
| OQ-4 | Alert destination | **SNS → email** first; Slack when there is an on-call. |
| OQ-6 | Chart delivery if private | moot — the repo is public. OCI in ECR if that changes. |
| OQ-7 | Node instance type | **`t3.medium` × 2**, amd64. |

OQ-5, the prod trigger, is the first external-tier customer with data. Until
then `prod` is a profile, not an account.

---

## 19. Out of scope

Multi-region, active-active, service mesh, mTLS, event bus, async workers,
polyglot runtimes, multi-tenant orgs, self-service app creation without a
platform PR, a web UI for the registry, cost dashboards per app, and an on-call
rotation. Each has a trigger above; none is a configuration flag today.

---

## 20. Definition of done, for every phase

A phase is done when all five are true:

1. The branch is named for the phase and cut from `main`.
2. The acceptance command was run and its output is in the PR comment, with the
   SHA it ran against.
3. The docs this phase changed are the ones a reader will open.
4. A verifier who is not the author re-ran the acceptance command.
5. The human merged it. The author did not.
