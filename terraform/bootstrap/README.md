# terraform/bootstrap

The one stack that is applied by hand, once, and the only one whose state is
local. It creates the S3 bucket every other stack stores its state in; a bucket
cannot hold the state of the stack that creates it.

It also owns the GitHub Actions OIDC provider, in one of two modes:

- `manage_oidc_provider = true` (default): create it. Correct for a fresh
  account.
- `manage_oidc_provider = false`: read the one the account already has. Correct
  when another platform ran here, because AWS allows one provider per URL and a
  second create fails with `EntityAlreadyExists`.

Check which case you are in before applying; the command is in
`docs/runbooks/bootstrap-platform.md`. On this account the provider was deleted
with the godough teardown on 2026-11-28, so the default (`true`) is correct. Use
`false` only when the preflight finds one.

It does not create GuardDuty or CloudTrail. Those are in `terraform/account`, a
separate stack so its state can be replaced without touching the bucket and the
key.

## Apply

Run from this directory, as a human, once:

```
terraform init
terraform plan
terraform apply
```

For an account that already has the provider, add
`-var manage_oidc_provider=false` to the plan and apply.

Expected: `foundry-terraform-state-<account>` exists, versioned, SSE-KMS, public
access blocked, TLS-only; the outputs include `github_oidc_provider_arn`.

If the provider is missing, the plan stops at the data source. Create it once
(the existing bootstrap or `aws iam create-open-id-connect-provider`), then
re-run. Do not add a resource here to work around it.

## State

`terraform.tfstate` is local and gitignored. It is the only non-durable state in
the repository; if it is lost, the bucket and key are recoverable by import. The
bucket itself is what makes every other stack durable.

## What this stack does not do

- No VPC, cluster, database, registry or edge. Those are separate stacks.
- No second OIDC provider, GuardDuty detector or CloudTrail trail.
- No resource named `godough-*`.
