# foundry

The platform: Terraform, one generic Helm chart, the Argo CD tree, the runtime
Go module, the app template and the operational baseline. `app1` is the
reference application built on it. `godough` is the application the platform was
extracted from; it is frozen and nothing here imports it.

**Status:** plan approved 2026-11-28. P1 (Terraform) in progress. Same AWS
account as `godough`; see [`docs/plan.md`](docs/plan.md) §7.0 for the coexistence
rules.

Start here: [`docs/plan.md`](docs/plan.md).

## The shape

```
foundry  (platform)          app1  (product)
  terraform/                   cmd/ internal/ spec/ ui/
  charts/app-api, app-web      migrations/
  argocd/                      deploy/values*.yaml
  environments/                .github/workflows/
  profiles/                    Dockerfile, Makefile
  templates/app/
  go/            (module)
```

Two repos, three read-only links between them:

1. the chart, consumed by a version (git tag; OCI if the repo is private);
2. an ECR repository and an OIDC push role, one per app;
3. an Argo CD Application that reads the app repo's `deploy/values*.yaml`.

The app team owns its repository, tests, CI and image digest. The platform owns
the envelope: identity, data, edge, network, probes, alarms and the promotion
gate.

## Repos

| repo | role | state |
|---|---|---|
| `foundry` | platform | this repository |
| `app1` | reference snippet app, instantiated from `templates/app` | not created yet |
| `godough` | legacy implementation, source material | frozen |

## Rules

- One app per repo. One platform. No shared working tree.
- The platform is not a library the app edits; it is a version the app consumes.
- Every phase ends with a PR, evidence in a comment, and a human merge.
  The author does not verify; the verifier does not merge.
- A decision is corrected in this repository, not in a comment about it.

## License

MIT — see [`LICENSE`](LICENSE).
