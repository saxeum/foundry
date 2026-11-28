#!/usr/bin/env bash
#
# Onboard one app into one environment:
#   - database <app> and roles <app>_owner / <app>_app on that env's RDS;
#   - Secrets in <app>-<env>: <app>-api, <app>-owner, foundry-rds-ca.
#
# Run the RDS tunnel first, in its own terminal:
#   make rds-tunnel ENV=staging
# Then:
#   make onboard-app APP=app1 ENV=staging
#
# This is a human-run onboarding step, like the cluster bootstrap. It is
# idempotent: re-running rotates the two per-app passwords and updates the
# Secrets.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-}"
env="${2:-staging}"
ca="${CA_BUNDLE:-global-bundle.pem}"

if [[ ! "$app" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
  echo "usage: $0 <app> [dev|staging]" >&2
  exit 1
fi
if [[ ! "$env" =~ ^(dev|staging)$ ]]; then
  echo "environment must be dev or staging" >&2
  exit 1
fi

for cmd in psql jq aws kubectl openssl pg_isready; do
  command -v "$cmd" >/dev/null || { echo "$cmd is required" >&2; exit 1; }
done

pg_isready -h 127.0.0.1 -p 15432 -q \
  || { echo "nothing is listening on 15432: run 'make rds-tunnel ENV=$env' in another terminal" >&2; exit 1; }

if [ ! -f "$ca" ]; then
  echo "downloading the RDS CA bundle to $ca"
  curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o "$ca"
  chmod 600 "$ca"
fi

db="${app//-/_}"
owner_role="${db}_owner"
app_role="${db}_app"
namespace="${app}-${env}"

endpoint=$(terraform -chdir=terraform/data output -json db_endpoints | jq -r --arg e "$env" '.[$e]')
master_arn=$(terraform -chdir=terraform/data output -json master_user_secret_arns | jq -r --arg e "$env" '.[$e]')

[ "$endpoint" != "null" ] && [ "$master_arn" != "null" ] \
  || { echo "no RDS endpoint or master secret for env $env" >&2; exit 1; }

master_json=$(aws secretsmanager get-secret-value --secret-id "$master_arn" --query SecretString --output text)
master_user=$(printf '%s' "$master_json" | jq -r .username)
master_pw=$(printf '%s' "$master_json" | jq -r .password)

owner_pw=$(openssl rand -hex 24)
app_pw=$(openssl rand -hex 24)

master_dsn="host=$endpoint hostaddr=127.0.0.1 port=15432 dbname=postgres user=$master_user sslmode=verify-full sslrootcert=$ca"

PGPASSWORD="$master_pw" psql "$master_dsn" -q -v ON_ERROR_STOP=1 \
  -v app_db="$db" \
  -v owner_role="$owner_role" \
  -v app_role="$app_role" \
  -v owner_pw="$owner_pw" \
  -v app_pw="$app_pw" \
  -f scripts/onboard-app.sql >/dev/null

owner_dsn="host=$endpoint hostaddr=127.0.0.1 port=15432 dbname=$db user=$owner_role sslmode=verify-full sslrootcert=$ca"

PGPASSWORD="$owner_pw" psql "$owner_dsn" -q -v ON_ERROR_STOP=1 \
  -v app_db="$db" \
  -v app_role="$app_role" \
  -f scripts/onboard-app-grants.sql >/dev/null

api_dsn="postgres://${app_role}:${app_pw}@${endpoint}:5432/${db}?sslmode=verify-full&sslrootcert=/certs/global-bundle.pem"
owner_secret_dsn="postgres://${owner_role}:${owner_pw}@${endpoint}:5432/${db}?sslmode=verify-full&sslrootcert=/certs/global-bundle.pem"

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "$namespace" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted --overwrite >/dev/null

kubectl -n "$namespace" create secret generic "${app}-api" \
  --from-literal=DATABASE_URL="$api_dsn" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$namespace" create secret generic "${app}-owner" \
  --from-literal=DATABASE_URL_OWNER="$owner_secret_dsn" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$namespace" create secret generic foundry-rds-ca \
  --from-file=global-bundle.pem="$ca" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "onboarded ${app}/${env}: database ${db}, roles ${owner_role}/${app_role}, secrets in ${namespace}"
