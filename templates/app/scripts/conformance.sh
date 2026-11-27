#!/usr/bin/env bash
#
# The same render Argo does, against the chart release the app declares. If the
# platform's contract changes, this fails in the app's CI before a deploy.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${APP:-__APP_NAME__}"
version="${CHART_VERSION:-0.1.0}"

command -v helm >/dev/null || { echo "helm is required"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The chart is a release; the environment and profile values are platform
# configuration and are read from main, which is what the ApplicationSet does.
curl -fsSL "https://github.com/saxeum/foundry/archive/refs/tags/v${version}.tar.gz" -o "$tmp/chart.tgz"
tar -xzf "$tmp/chart.tgz" -C "$tmp"
chart_root="$tmp/foundry-${version}"
[ -d "$chart_root" ] || { echo "chart tarball had no foundry-${version} directory"; exit 1; }

curl -fsSL "https://github.com/saxeum/foundry/archive/refs/heads/main.tar.gz" -o "$tmp/platform.tgz"
tar -xzf "$tmp/platform.tgz" -C "$tmp"
platform_root="$tmp/foundry-main"
[ -d "$platform_root" ] || { echo "platform tarball had no foundry-main directory"; exit 1; }

args=(
  --kube-version 1.37.0
  -f deploy/api/values.yaml
  -f deploy/api/values-dev.yaml
  -f "$platform_root/profiles/internal/values.yaml"
  -f "$platform_root/environments/dev/values.yaml"
  --set app.name="${app}"
  --set image.repository="example.com/${app}-api"
  --set migrations.ownerSecret.name="${app}-owner"
  --set caSecret.name=foundry-rds-ca
)

helm template "$app" "$chart_root/charts/app-api" "${args[@]}" > "$tmp/rendered.yaml"

grep -q 'kind: Deployment' "$tmp/rendered.yaml" || { echo "no Deployment rendered"; exit 1; }
grep -q 'kind: Service' "$tmp/rendered.yaml" || { echo "no Service rendered"; exit 1; }
grep -q 'kind: Job' "$tmp/rendered.yaml" || { echo "no migration Job rendered"; exit 1; }
grep -q 'kind: NetworkPolicy' "$tmp/rendered.yaml" || { echo "no NetworkPolicy rendered"; exit 1; }
grep -q '@sha256:' "$tmp/rendered.yaml" || { echo "image is not a digest"; exit 1; }

# The chart schema is a gate only if it can reject. An app-owned key the schema
# does not define must fail the render.
if helm template "$app" "$chart_root/charts/app-api" "${args[@]}" --set app.notAKey=no >/dev/null 2>&1; then
  echo "the chart schema accepted an unknown app key; the gate is gone" >&2
  exit 1
fi

echo "conformance ok: ${app} at chart v${version}"
