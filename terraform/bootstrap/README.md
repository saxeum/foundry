# terraform/bootstrap

The one stack that is applied by hand, once, and the only one whose state is
local. It creates the S3 bucket every other stack stores its state in; a bucket
cannot hold the state of the stack that creates it.

It also **reads** the existing GitHub Actions OIDC provider and outputs its ARN.
It never creates one. AWS allows one provider per URL per account, and this
account already has one from `godough`; a second apply would fail with
`EntityAlreadyExists`, which is the correct outcome and the reason this is a data
source rather than a resource.

It does not create GuardDuty or CloudTrail. Those are account-global and already
owned by `godough`'s `security` stack. See `docs/plan.md` §7.0.

## Apply

Run from this directory, as a human, once:

```
terraform init
terraform plan
terraform apply
```

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
