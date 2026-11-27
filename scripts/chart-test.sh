#!/usr/bin/env bash
#
# Contract tests for the generic charts. No plugin: helm template plus
# assertions, so the same commands run on a laptop and in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

charts=(charts/app-api charts/app-web)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

for chart in "${charts[@]}"; do
  name=$(basename "$chart")
  values="$chart/tests/ci-values.yaml"
  out="$tmp/$name.yaml"

  echo "== $name =="

  helm lint "$chart" --kube-version 1.37.0 -f "$values" >/dev/null || fail "$name lint"

  helm template app1 "$chart" --kube-version 1.37.0 -f "$values" >"$out" || fail "$name template"

  for pattern in \
    'kind: Deployment' \
    'kind: Service' \
    'kind: ServiceAccount' \
    'kind: Ingress' \
    'kind: NetworkPolicy' \
    'runAsNonRoot: true' \
    'readOnlyRootFilesystem: true' \
    'allowPrivilegeEscalation: false' \
    'automountServiceAccountToken: false' \
    'livenessProbe:' \
    'readinessProbe:'
  do
    grep -q -- "$pattern" "$out" || fail "$name missing: $pattern"
  done

  grep -q '@sha256:' "$out" || fail "$name image is not a digest"
  if grep -q ':latest' "$out"; then
    fail "$name rendered a :latest tag"
  fi

  if [ "$name" = "app-api" ]; then
    for pattern in \
      'kind: Job' \
      'kind: PodDisruptionBudget' \
      'kind: ServiceMonitor' \
      'kind: PrometheusRule' \
      'kind: ExternalSecret' \
      'DATABASE_URL_OWNER'
    do
      grep -q -- "$pattern" "$out" || fail "$name missing: $pattern"
    done
  else
    grep -q 'kind: PodDisruptionBudget' "$out" || fail "$name missing: PodDisruptionBudget"
    if grep -q 'kind: ServiceMonitor' "$out"; then
      fail "$name rendered a ServiceMonitor"
    fi
    if grep -q 'kind: Job' "$out"; then
      fail "$name rendered a migration Job"
    fi
  fi

  # The digest guard and the tier guard are only useful if they can fail.
  if helm template app1 "$chart" --kube-version 1.37.0 -f "$values" --set-string image.digest= >/dev/null 2>&1; then
    fail "$name rendered without a digest"
  fi

  if helm template app1 "$chart" --kube-version 1.37.0 -f "$values" \
    --set tier=external --set replicaCount=1 --set pdb.enabled=false >/dev/null 2>&1; then
    fail "$name rendered external with one replica and no PDB"
  fi

  if helm template app1 "$chart" --kube-version 1.37.0 -f "$values" \
    --set tier=external --set replicaCount=2 --set pdb.enabled=false >/dev/null 2>&1; then
    fail "$name rendered external without a PDB"
  fi

  echo "ok"
done

echo "charts ok"
