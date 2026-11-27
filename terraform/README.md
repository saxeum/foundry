# terraform

Nine stacks, one state bucket, one apply order. The existing AWS account, with
no dependency on the godough residue; the rules are in `docs/plan.md` §7.0.

## Order

| # | Stack | Depends on | Notes |
|---|---|---|---|
| 1 | `bootstrap` | — | **human, once**; local state; creates the bucket and creates or reads the OIDC provider |
| 2 | `network` | bootstrap | VPC `10.20.0.0/16`, subnets, NAT, flow logs, node and bastion SGs |
| 3 | `account` | bootstrap | GuardDuty, CloudTrail, KMS, log bucket |
| 4 | `alerts` | bootstrap | SNS topic and budget |
| 5 | `data` | network | RDS per env, parameter group, RDS SG |
| 6 | `cluster` | network | EKS, nodes, addons, IRSA, bastion |
| 7 | `registry` | bootstrap | ECR images, per-app push role |
| 8 | `edge` | cluster | LBC, ACM wildcard, Cloudflare, ALB logs, WAF |
| 9 | `argocd` | cluster, edge | Argo CD, pinned chart and values |

`account` and `alerts` are independent of `network`. `data` and `cluster` can be
applied in either order.

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

- The OIDC provider is the one shared object: `bootstrap` creates it on a fresh
  account and reads it where one exists (`manage_oidc_provider`).
- `account` owns GuardDuty and CloudTrail. If a partial teardown left a detector
  or trail, import it or skip the stack with a recorded decision; never create a
  second.
- Every resource is named `foundry-*`.
- The VPC is `10.20.0.0/16`; do not peer to the `10.42.0.0/16` residue.

## Not here

No application code, charts, Argo tree or environment values. Those are
`charts/`, `argocd/`, `environments/`.
