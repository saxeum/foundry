# Runbook — bring up a foundry platform from scratch

**Use when** the account is empty, or foundry is being rebuilt after a teardown.
**Time** two to three hours, most of it waiting for EKS and RDS.
**Authority** the bootstrap apply is the human's, once. Everything after it is
Terraform or Argo, and no step is run by an agent on `main`.
**Evidence** every apply's summary goes in the issue or PR comment with the SHA
it ran against. "It came up" without output is not evidence.

The stack order and the same-account rules are in `docs/plan.md` §7.

---

## 0. What you need

| Thing | Detail |
|---|---|
| AWS account | administrator via SSO; the account id is not in this repository |
| Region | `ap-southeast-2` |
| GitHub org | `saxeum`, with permission to create repos and set Actions variables |
| Cloudflare | API token with `Zone:Read` and `DNS:Edit` on the one zone |
| Domain | a zone in Cloudflare; foundry serves `<app>.<zone>` |
| Alert email | the SNS subscription from `terraform/alerts` |
| Tools | `terraform >= 1.17`, AWS CLI v2, `kubectl`, `helm`, `argocd`, `gh`, `jq`, `session-manager-plugin` |

`terraform/backend.hcl` does not exist yet. It is created in step 4 from the
bootstrap output, and it is gitignored because the bucket name contains the
account id.

---

## 1. Preflight

Read-only. Run from the repository root with the target account selected.

```
aws sts get-caller-identity --query 'Account' --output text
```

The account id is the one you expect.

```
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text
```

Record the answer. It decides `manage_oidc_provider` in step 3: one provider for
`token.actions.githubusercontent.com` means `false`; none means `true`.

```
aws cloudtrail describe-trails --query 'trailList[].Name' --output text
```

Empty is a clean account. A trail is residue: `terraform/account` must import it
or the stack must be skipped with a recorded decision.

```
aws guardduty list-detectors --query 'DetectorIds' --output text
```

Empty is a clean account. A detector is residue, same rule as the trail.

```
aws ec2 describe-vpcs --query 'Vpcs[].CidrBlock' --output text
```

No `10.20.0.0/16`. Another platform's CIDR is fine; foundry does not peer to it.

```
aws eks list-clusters --query 'clusters' --output text
```

No `foundry-*` cluster. This is the one name that must be free.

```
aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" --query 'Budgets[].BudgetName' --output text
```

Note what exists. Foundry adds `foundry-monthly`; it does not adopt the others.

---

## 2. Clone and pin the names

```
git clone https://github.com/saxeum/foundry.git
```

```
cd foundry
```

```
export AWS_REGION=ap-southeast-2
```

The names are fixed by `docs/plan.md` §3: cluster `foundry-staging`, VPC
`10.20.0.0/16`, state bucket `foundry-terraform-state-<account>`, alert topic
`foundry-alerts`, database `app1`, images `app1-api` and `app1-web`.

---

## 3. Bootstrap — the human's one apply

This creates the state bucket and either creates or reads the GitHub OIDC
provider. It is the only stack with local state.

```
cd terraform/bootstrap
```

```
terraform init
```

```
terraform plan
```

Read the plan before applying. A fresh account shows one
`aws_iam_openid_connect_provider` and the bucket. An account that already has the
provider must be planned with `-var manage_oidc_provider=false`; without it the
apply fails with `EntityAlreadyExists`, which is the intended guard, not a bug.

```
terraform apply
```

If the provider already existed:

```
terraform apply -var manage_oidc_provider=false
```

Capture the two values the rest of the platform needs:

```
terraform output -raw state_bucket
```

```
terraform output -raw github_oidc_provider_arn
```

Write both into the issue. They are the only hand-carried values.

```
cd ../..
```

---

## 4. Point every other stack at the bucket

```
cp terraform/backend.hcl.example terraform/backend.hcl
```

Edit `terraform/backend.hcl`: set `bucket` to the `state_bucket` output and leave
`region = "ap-southeast-2"`. It is gitignored.

Initialise each stack with the backend. This is the step that makes `plan`
possible; before it, only `validate` works.

```
terraform -chdir=terraform/network init -backend-config=../backend.hcl
```

```
terraform -chdir=terraform/account init -backend-config=../backend.hcl
```

```
terraform -chdir=terraform/alerts init -backend-config=../backend.hcl
```

```
terraform -chdir=terraform/registry init -backend-config=../backend.hcl
```

```
terraform -chdir=terraform/data init -backend-config=../backend.hcl
```

```
terraform -chdir=terraform/cluster init -backend-config=../backend.hcl
```

```
terraform -chdir=terraform/edge init -backend-config=../backend.hcl
```

```
terraform -chdir=terraform/argocd init -backend-config=../backend.hcl
```

---

## 5. Network

Creates the VPC, two public and two private subnets, the single NAT, flow logs,
and the node and bastion security groups.

```
terraform -chdir=terraform/network plan
```

```
terraform -chdir=terraform/network apply
```

Expected: `Apply complete` with the VPC, 4 subnets, IGW, NAT, EIP, 2 route
tables, 2 security groups, flow log and its IAM role. The VPC is
`10.20.0.0/16`; a plan that wants to change an existing `godough-*` VPC is wrong.

---

## 6. Account detection

Creates GuardDuty and a multi-region management-events trail with its KMS key and
S3 bucket. This is what the account no longer has after the godough teardown.

```
terraform -chdir=terraform/account plan
```

```
terraform -chdir=terraform/account apply
```

If a detector or trail already exists, stop. Import it rather than creating a
second:

```
terraform -chdir=terraform/account import aws_guardduty_detector.this <detector-id>
```

```
terraform -chdir=terraform/account import aws_cloudtrail.management <trail-name>
```

Importing a trail with an `advanced_event_selector` the configuration does not
model deletes that selector on the next apply. Check the trail first; if it has
one, add it to the configuration exactly as it is before importing.

---

## 7. Alerts and budget

```
terraform -chdir=terraform/alerts plan -var alert_email=<you@example.com>
```

```
terraform -chdir=terraform/alerts apply -var alert_email=<you@example.com>
```

Expected: `foundry-alerts`, the email subscription (confirm it), and
`foundry-monthly` at `$250`. An apply without `alert_email` creates a topic with
no subscriber, which is valid and wrong for production.

---

## 8. Registry

Creates the ECR repositories (`app1-api`, `app1-web`) and the per-app GitHub
OIDC push role. The role is what the app repo's `AWS_PUSH_ROLE_ARN` points at.

```
terraform -chdir=terraform/registry plan
```

```
terraform -chdir=terraform/registry apply
```

The registry needs the app list. P1 ships the stack with `app1`; adding an app is
a platform PR that adds its repositories and role, then an onboarding step.

---

## 9. Data

Creates RDS for `dev` and `staging`, the parameter group with `rds.force_ssl`,
and the RDS security group that accepts 5432 only from the node and bastion
groups.

```
terraform -chdir=terraform/data plan
```

```
terraform -chdir=terraform/data apply
```

Expected: two instances, `foundry-dev` and `foundry-staging`, both private,
encrypted, `deletion_protection = true`, seven-day PITR. The first apply takes
about ten minutes.

Per-app databases and roles are not created here. That is
`scripts/onboard-app.sh`, run once per app over the SSM tunnel, in step 16.

---

## 10. Cluster

Creates the private EKS API, the managed node group (`t3.medium` x2), the
addons, IRSA and the SSM bastion.

```
terraform -chdir=terraform/cluster plan
```

```
terraform -chdir=terraform/cluster apply
```

Expected: `foundry-staging`, endpoint private, secrets envelope-encrypted,
`t3.medium` nodes in the private subnets, and a `t4g.nano` bastion in public-1
with no inbound rules. The apply takes about fifteen minutes.

The cluster output is needed even before the tunnel: `cluster_endpoint` and
`bastion_instance_id` are what step 13 forwards.

---

## 11. Edge

Creates the AWS Load Balancer Controller, the wildcard ACM certificate for the
zone, the Cloudflare validation records, the ALB log bucket and the WAF ACL.

The ALB does not exist until an Ingress is synced, so the first apply uses an
empty `alb_hostname` and the DNS record is created after step 14.

```
terraform -chdir=terraform/edge plan -var domain=app1.foonix.net -var cloudflare_zone=foonix.net
```

```
terraform -chdir=terraform/edge apply -var domain=app1.foonix.net -var cloudflare_zone=foonix.net
```

Expected: certificate `ISSUED` after the Cloudflare validation record, the LBC
running in `kube-system`, the WAF ACL in count mode, and the ALB log bucket with
a lifecycle rule.

`CLOUDFLARE_API_TOKEN` must be in the environment; it is not in the repository.

---

## 12. Argo CD

Installs Argo CD once, pinned by chart version. After this the cluster is a
GitOps cluster.

```
terraform -chdir=terraform/argocd plan
```

```
terraform -chdir=terraform/argocd apply
```

Expected: `argocd` namespace, the pinned chart, no public ingress.

---

## 13. Reach the private API

The EKS endpoint is private. The only path is an SSM port forward through the
bastion. Leave the first command running in its own terminal.

```
aws ssm start-session --region "$AWS_REGION" --target "$(terraform -chdir=terraform/cluster output -raw bastion_instance_id)" --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host="$(terraform -chdir=terraform/cluster output -raw cluster_endpoint | sed 's|https://||')",portNumber="443",localPortNumber="6443"
```

In a second terminal, write a kubeconfig and point its server at the tunnel. The
`--tls-server-name` is what keeps certificate verification working through
`127.0.0.1`.

```
aws eks update-kubeconfig --region "$AWS_REGION" --name foundry-staging --alias foundry-staging --kubeconfig ~/.kube/foundry
```

```
kubectl config set-cluster "$(kubectl config view --kubeconfig ~/.kube/foundry -o jsonpath='{.contexts[?(@.name=="foundry-staging")].context.cluster}')" --kubeconfig ~/.kube/foundry --server=https://127.0.0.1:6443 --tls-server-name="$(terraform -chdir=terraform/cluster output -raw cluster_endpoint | sed 's|https://||')"
```

```
kubectl get nodes --kubeconfig ~/.kube/foundry
```

Expected: two `Ready` nodes. If it hangs, the tunnel is not running or the
bastion security group has no route to the endpoint.

Later P1 targets wrap the two commands as `make eks-tunnel` and
`make eks-kubeconfig`.

---

## 14. Seed Argo and create the ALB

```
kubectl apply -f argocd/root --kubeconfig ~/.kube/foundry
```

```
kubectl -n argocd get applications --kubeconfig ~/.kube/foundry
```

Expected: `root` Synced/Healthy, then the ApplicationSet creates `app1-dev` and
`app1-staging` once the registry has an app.

The first Ingress sync creates the ALB. Read its name:

```
kubectl -n app1-staging get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' --kubeconfig ~/.kube/foundry
```

Set it on the edge stack and apply again, so the Cloudflare record points at the
ALB rather than at nothing:

```
terraform -chdir=terraform/edge apply -var domain=app1.foonix.net -var cloudflare_zone=foonix.net -var alb_hostname=<alb-hostname>
```

---

## 15. First deploy of the app

The app repo is `app1`, created from `templates/app`. The onboarding procedure is
`docs/onboarding.md`; the short form:

1. Create `saxeum/app1` from the template.
2. Set `AWS_PUSH_ROLE_ARN` and `ECR_REGISTRY` on the app repo from the registry
   outputs.
3. Run `scripts/onboard-app.sh app1` for each environment, over the tunnel.
4. Add `argocd/apps/app1.yaml` and `argocd/projects/app1.yaml`; merge.
5. Push the first image. The dev digest PR opens; it auto-merges on the one path.
6. Open the staging promotion PR; a human merges it.

No cluster credential is ever set on the app repo.

---

## 16. Verify

```
argocd app list
```

Expected: `app1-dev` and `app1-staging` Synced/Healthy.

```
curl -fsS "https://app1.foonix.net/healthz"
```

`ok`

```
curl -fsS "https://app1.foonix.net/readyz"
```

`ok`

```
curl -sSI "https://app1.foonix.net/" | grep -i strict-transport-security
```

A `strict-transport-security` header. If it is missing, the edge policy is not
applied and the platform is not done.

```
gh run list --repo saxeum/app1 --limit 3
```

The last push is green, including the conformance render.

---

## 17. Teardown

Reverse order, and never in one `terraform destroy -target`. Deletion protection
is on by design; turn it off deliberately.

1. Remove the Argo Applications and the root, then destroy `argocd`.
2. Destroy `edge`; if the ALB or certificate is protected, disable it first.
3. Destroy `cluster`; the node group first, then the control plane.
4. Destroy `data`. Set `deletion_protection = false` and
   `skip_final_snapshot = false` in a branch first, apply, take the snapshot,
   then destroy.
5. Destroy `registry`.
6. Destroy `network`.
7. Leave `account` until the audit retention is no longer needed. The CloudTrail
   bucket is versioned and `force_destroy = false`; destroying it requires
   emptying every version, which is a deliberate act.
8. Destroy `alerts`.
9. Destroy `bootstrap` last. Its state is local; the bucket it created is the
   only thing that must outlive every other stack until they are gone.

Do not delete `godough-*` residue from foundry. It is not foundry's.

---

## 18. If the account is not empty

The same procedure, with three changes:

| Situation | Change |
|---|---|
| OIDC provider exists | `-var manage_oidc_provider=false` on the bootstrap plan and apply |
| GuardDuty detector or CloudTrail exists | import in `terraform/account`, or skip that stack with a recorded decision; never create a second |
| A `10.20.0.0/16` VPC exists | stop; pick another CIDR, do not adopt or peer it |

At 2026-11-28 the godough teardown completed: the OIDC provider, the
`10.42.0.0/16` VPC, the ECR repositories and the S3 buckets are gone. Two
godough KMS keys remain in `PendingDeletion` until 2026-12-28 and cannot be
used. The preflight in step 1 is still the authority on the day you run it: a
teardown can be mid-flight, and the account belongs to more than one project.

---

## 19. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `EntityAlreadyExists` on the OIDC provider | one provider per URL per account | set `manage_oidc_provider=false`, or import |
| `BucketAlreadyOwnedByYou` | the state bucket name is taken | destroy the old bucket or change `project` |
| `Backend initialization required` on `plan` | `backend.hcl` missing or wrong | step 4 |
| Plan wants to change a `godough-*` resource | wrong account or wrong state | stop; the stacks are independent |
| `kubectl` hangs on the tunnel | endpoint is private and the forward died | restart step 13; check the bastion SG |
| Certificate `PENDING_VALIDATION` | Cloudflare record not created or proxied | DNS only, `proxied = false` |
| App Ingress no hostname | LBC not running or subnet tags missing | `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| Argo `ComparisonError` on values | chart tag or app values do not match the registry pin | the skew check output names the two versions |

---

## 20. What done looks like

- `terraform output` from bootstrap, and every stack's apply summary, in the
  issue with the SHA.
- `argocd app list` Synced/Healthy for `app1-dev` and `app1-staging`.
- `/healthz`, `/readyz` and one authenticated read through the ALB.
- The HSTS/CSP headers present; the WAF in count mode; the alerts topic
  subscribed.
- One alarm fired on purpose, and the runbook that answers it named.
- The next app onboarded from `docs/onboarding.md` without editing the platform.
