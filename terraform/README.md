# terraform

Eight stacks, one state bucket, one apply order. The same AWS account as
`godough`; the coexistence rules are in `docs/plan.md` §7.0.

## Order

| # | Stack | Depends on | Notes |
|---|---|---|---|
| 1 | `bootstrap` | — | **human, once**; local state; creates the bucket and reads the existing OIDC provider |
| 2 | `network` | bootstrap | VPC `10.20.0.0/16`, subnets, NAT, flow logs, node and bastion SGs |
| 3 | `alerts` | bootstrap | SNS topic and budget |
| 4 | `data` | network | RDS per env, parameter group, RDS SG |
| 5 | `cluster` | network | EKS, nodes, addons, IRSA, bastion |
| 6 | `registry` | bootstrap | ECR images, per-app push role |
| 7 | `edge` | cluster | LBC, ACM wildcard, Cloudflare, ALB logs, WAF |
| 8 | `argocd` | cluster, edge | Argo CD, pinned chart and values |

`data` and `cluster` can be applied in either order; they are independent.

## State

`bootstrap` keeps local state — it creates the bucket, so it cannot store its own
state there. Every other stack has a partial S3 backend:

```
terraform init -backend-config=../backend.hcl
```

Create `terraform/backend.hcl` from `backend.hcl.example` after the bootstrap
apply. It is gitignored: the bucket name contains the account id.

Before the bucket exists — or in CI — validate without a backend:

```
terraform init -backend=false
terraform validate
```

`plan` needs the backend, so it is the PR evidence only after the bootstrap has
been applied once.

## Same account

- Do not create a second GitHub OIDC provider, GuardDuty detector or CloudTrail
  trail. `bootstrap` reads the provider; the other two are inherited.
- Every resource is named `foundry-*`.
- The VPC is `10.20.0.0/16`; do not peer to godough's `10.42.0.0/16`.

## Not here

No application code, charts, Argo tree or environment values. Those are
`charts/`, `argocd/`, `environments/`.
