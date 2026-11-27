#!/usr/bin/env bash
#
# Static validation of the Argo tree. It is not a sync: it proves the registry,
# the AppProjects and the ApplicationSet agree with each other, and that the
# safety properties (namespace scoping, PSA, no prune) are present. The real
# render is `argocd app diff` after #12.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v yq >/dev/null || fail "yq is required"
command -v python3 >/dev/null || fail "python3 is required"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Plain YAML under argocd/ parses. The ApplicationSet is a Go template, so it is
# rendered with one sample app first; the raw file is not valid YAML by design.
while IFS= read -r file; do
  yq eval '.' "$file" >/dev/null || fail "parse $file"
done < <(find argocd -name '*.yaml' -type f | sort)

appset=argocd/clusters/staging/appset.yaml
rendered="$tmp/appset.yaml"

python3 - "$appset" "$rendered" <<'PY'
import sys

src = open(sys.argv[1]).read()
# Take the web branch: the fixture app has a UI, and both chart sources must
# parse. Control actions are removed; expressions are replaced with a sample.
for key, value in {
    ".name": "app1",
    ".env": "dev",
    ".tier": "internal",
    ".repo": "https://github.com/saxeum/app1.git",
    ".revision": "main",
    ".namespace": "app1",
    ".chartVersion": "0.1.0",
    ".host": "app1.foonix.net",
}.items():
    src = src.replace("{{ " + key + " }}", value)
open(sys.argv[2], "w").write(src)
PY

yq eval '.' "$rendered" >/dev/null || fail "rendered ApplicationSet is not valid YAML"

# The raw file still uses the parameters the fixture replaced.
for expr in '{{ .name }}' '{{ .env }}' '{{ .tier }}' '{{ .repo }}' '{{ .revision }}' '{{ .namespace }}' '{{ .chartVersion }}' '{{ .host }}'; do
  grep -qF "$expr" "$appset" || fail "ApplicationSet does not use $expr"
done

# The root is the app-of-apps seed and recurses into the cluster directory.
root=argocd/root/application.yaml
[ "$(yq -r '.spec.source.path' "$root")" = "argocd/clusters/staging" ] || fail "root path"
[ "$(yq -r '.spec.source.directory.recurse' "$root")" = "true" ] || fail "root recurse"
[ "$(yq -r '.spec.destination.namespace' "$root")" = "argocd" ] || fail "root destination"

# The platform addon project is the only one with cluster-scoped powers, and it
# is applied before the monitoring Application.
platform=argocd/clusters/staging/projects/platform.yaml
[ -f "$platform" ] || fail "missing $platform"
[ "$(yq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$platform")" = "-3" ] \
  || fail "platform AppProject is not wave -3"
yq -e '.spec.sourceRepos[] | select(. == "https://prometheus-community.github.io/helm-charts")' "$platform" >/dev/null \
  || fail "platform AppProject does not allow the monitoring chart repo"
yq -e '.spec.sourceRepos[] | select(. == "https://github.com/saxeum/foundry.git")' "$platform" >/dev/null \
  || fail "platform AppProject does not allow the foundry values repo"
yq -e '.spec.destinations[] | select(.namespace == "monitoring")' "$platform" >/dev/null \
  || fail "platform AppProject does not scope monitoring"
yq -e '.spec.destinations[] | select(.namespace == "kube-system")' "$platform" >/dev/null \
  || fail "platform AppProject does not allow the control-plane Services"
yq -e '.spec.clusterResourceWhitelist[] | select(.kind == "CustomResourceDefinition")' "$platform" >/dev/null \
  || fail "platform AppProject does not allow CRDs"
yq -e '.spec.clusterResourceWhitelist[] | select(.kind == "ClusterRole")' "$platform" >/dev/null \
  || fail "platform AppProject does not allow ClusterRoles"
yq -e '.spec.clusterResourceWhitelist[] | select(.kind == "Namespace")' "$platform" >/dev/null \
  || fail "platform AppProject cannot create the monitoring namespace"

# Monitoring is an Application, not a Terraform helm_release: chart from the
# upstream repo, values from main, wave -2 so the app ApplicationSet waits for
# its CRDs.
monitoring=argocd/clusters/staging/addons/monitoring.yaml
[ -f "$monitoring" ] || fail "missing $monitoring"
[ "$(yq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$monitoring")" = "-2" ] \
  || fail "monitoring Application is not wave -2"
[ "$(yq -r '.spec.project' "$monitoring")" = "platform" ] || fail "monitoring is not in the platform project"
[ "$(yq -r '.spec.destination.namespace' "$monitoring")" = "monitoring" ] \
  || fail "monitoring destination is not the monitoring namespace"
yq -e '.spec.sources[] | select(.chart == "kube-prometheus-stack") | .targetRevision == "94.2.0"' "$monitoring" >/dev/null \
  || fail "monitoring chart is not pinned"
yq -e '.spec.sources[] | select(.chart == "kube-prometheus-stack") | .helm.valueFiles[] | select(. == "$values/argocd/addons/monitoring/values-staging.yaml")' "$monitoring" >/dev/null \
  || fail "monitoring Application does not read its values file"
yq -e '.spec.sources[] | select(.ref == "values") | .targetRevision == "main"' "$monitoring" >/dev/null \
  || fail "monitoring values ref is not main"
yq -e '.spec.sources[] | select(.ref == "values") | has("path") | not' "$monitoring" >/dev/null \
  || fail "monitoring values ref must not have a path"
yq -e '.spec.syncPolicy.syncOptions[] | select(. == "CreateNamespace=true")' "$monitoring" >/dev/null \
  || fail "monitoring does not create its namespace"
yq -e '.spec.syncPolicy.syncOptions[] | select(. == "ServerSideApply=true")' "$monitoring" >/dev/null \
  || fail "monitoring does not use server-side apply for the CRDs"
[ "$(yq -r '.spec.syncPolicy.automated.prune' "$monitoring")" = "false" ] \
  || fail "monitoring prunes stateful resources"
[ -f argocd/addons/monitoring/values-staging.yaml ] \
  || fail "missing monitoring values"
[ "$(yq -r '.prometheus.prometheusSpec.retention' argocd/addons/monitoring/values-staging.yaml)" = "15d" ] \
  || fail "prometheus retention is not set"
[ "$(yq -r '.grafana.enabled' argocd/addons/monitoring/values-staging.yaml)" = "false" ] \
  || fail "grafana is enabled without an auth story"

# One registry file and one AppProject per app, and they agree.
for registry in argocd/apps/*.yaml; do
  name=$(yq -r '.name' "$registry")
  repo=$(yq -r '.repo' "$registry")
  revision=$(yq -r '.revision' "$registry")
  namespace=$(yq -r '.namespace' "$registry")
  tier=$(yq -r '.tier' "$registry")
  chart_version=$(yq -r '.chartVersion' "$registry")
  host=$(yq -r '.host' "$registry")

  [ -n "$name" ] && [ "$name" != "null" ] || fail "$registry has no name"
  [ -n "$repo" ] && [ "$repo" != "null" ] || fail "$registry has no repo"
  [ -n "$revision" ] && [ "$revision" != "null" ] || fail "$registry has no revision"
  [ -n "$namespace" ] && [ "$namespace" != "null" ] || fail "$registry has no namespace"
  [ -n "$tier" ] && [ "$tier" != "null" ] || fail "$registry has no tier"
  [ -n "$chart_version" ] && [ "$chart_version" != "null" ] || fail "$registry has no chartVersion"
  [ -n "$host" ] && [ "$host" != "null" ] || fail "$registry has no host"
  web=$(yq -r '.web' "$registry")
  [ "$web" = "true" ] || [ "$web" = "false" ] || fail "$registry has no web boolean"

  [ -f "profiles/${tier}/values.yaml" ] || fail "missing profiles/${tier}/values.yaml for $name"

  project="argocd/clusters/staging/projects/${name}.yaml"
  [ -f "$project" ] || fail "missing $project"

  yq -e '.spec.sourceRepos[] | select(. == "https://github.com/saxeum/foundry.git")' "$project" >/dev/null \
    || fail "$project does not allow the foundry source"
  yq -e ".spec.sourceRepos[] | select(. == \"$repo\")" "$project" >/dev/null \
    || fail "$project does not allow $repo"
  yq -e ".spec.destinations[0].namespace == \"${namespace}-*\"" "$project" >/dev/null \
    || fail "$project does not scope ${namespace}-*"
  [ "$(yq -r '.spec.clusterResourceWhitelist | length' "$project")" = "0" ] \
    || fail "$project allows cluster-scoped resources"
  [ "$(yq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$project")" = "-1" ] \
    || fail "$project is not applied before the ApplicationSet"
done

# The ApplicationSet, rendered with the sample app.
[ "$(yq -r '.spec.goTemplate' "$rendered")" = "true" ] || fail "appset goTemplate"
[ "$(yq -r '.spec.generators[0].matrix.generators[0].git.files[0].path' "$rendered")" = "argocd/apps/*.yaml" ] \
  || fail "appset git files path"
[ "$(yq -r '.spec.generators[0].matrix.generators[1].list.elements | length' "$rendered")" -ge 1 ] \
  || fail "appset has no environments"
[ "$(yq -r '.spec.template.spec.project' "$rendered")" = "app1" ] || fail "appset project is not per app"
[ "$(yq -r '.spec.template.spec.destination.namespace' "$rendered")" = "app1-dev" ] \
  || fail "appset namespace is not per app and env"

for chart in charts/app-api charts/app-web; do
  yq -e ".spec.template.spec.sources[] | select(.path == \"$chart\")" "$rendered" >/dev/null \
    || fail "appset has no source for $chart"
done

for ref in app foundry; do
  yq -e ".spec.template.spec.sources[] | select(.ref == \"$ref\")" "$rendered" >/dev/null \
    || fail "appset has no $ref ref"
done

# The app ref follows the registry revision; the foundry ref is platform
# configuration and must not be pinned to the chart tag, which predates the
# profile and environment files.
yq -e '.spec.template.spec.sources[] | select(.ref == "app") | .targetRevision == "main"' "$rendered" >/dev/null \
  || fail "app ref is not the registry revision"
yq -e '.spec.template.spec.sources[] | select(.ref == "foundry") | .targetRevision == "main"' "$rendered" >/dev/null \
  || fail "foundry ref is pinned to the chart tag; platform values live on main"
yq -e '.spec.template.spec.sources[] | select(.ref == "foundry") | has("path") | not' "$rendered" >/dev/null \
  || fail "foundry ref must be a value source, not a path"

[ -n "$(yq -r '.spec.templatePatch // ""' "$rendered")" ] \
  || fail "appset has no templatePatch to drop the web source"
yq -r '.spec.templatePatch' "$rendered" | grep -q '/spec/sources/3' \
  || fail "templatePatch does not remove the web source by index"

for value_file in \
  '$app/deploy/api/values.yaml' \
  '$app/deploy/api/values-dev.yaml' \
  '$app/deploy/web/values.yaml' \
  '$app/deploy/web/values-dev.yaml' \
  '$foundry/profiles/internal/values.yaml' \
  '$foundry/environments/dev/values.yaml'
do
  yq -e ".spec.template.spec.sources[].helm.valueFiles[]? | select(. == \"$value_file\")" "$rendered" >/dev/null \
    || fail "appset is missing valueFile $value_file"
done

yq -e '.spec.template.spec.sources[] | select(.path == "charts/app-api") | .targetRevision == "v0.1.0"' "$rendered" >/dev/null \
  || fail "api chart is not pinned to the release tag"
yq -e '.spec.template.spec.sources[] | select(.path == "charts/app-web") | .targetRevision == "v0.1.0"' "$rendered" >/dev/null \
  || fail "web chart is not pinned to the release tag"

yq -e '.spec.template.spec.sources[] | select(.path == "charts/app-api") | .helm.parameters[] | select(.name == "migrations.ownerSecret.name") | .value == "app1-owner"' "$rendered" >/dev/null \
  || fail "api source does not pass the owner secret"
yq -e '.spec.template.spec.sources[] | select(.path == "charts/app-api") | .helm.parameters[] | select(.name == "caSecret.name") | .value == "foundry-rds-ca"' "$rendered" >/dev/null \
  || fail "api source does not pass the CA secret"

yq -e '.spec.template.spec.syncPolicy.syncOptions[] | select(. == "CreateNamespace=true")' "$rendered" >/dev/null \
  || fail "appset does not create namespaces"
[ "$(yq -r '.spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce"]' "$rendered")" = "restricted" ] \
  || fail "appset does not enforce restricted PSA"
[ "$(yq -r '.spec.template.spec.syncPolicy.automated.prune' "$rendered")" = "false" ] \
  || fail "appset prunes workloads"
[ "$(yq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$rendered")" = "0" ] \
  || fail "appset has no sync wave"

# Environment and profile files parse and carry the keys the chart expects.
for file in environments/*/values.yaml profiles/*/values.yaml; do
  yq eval '.' "$file" >/dev/null || fail "parse $file"
done

for env in environments/*/values.yaml; do
  [ -n "$(yq -r '.environment // ""' "$env")" ] || fail "$env has no environment"
done

for profile in profiles/*/values.yaml; do
  [ -n "$(yq -r '.tier // ""' "$profile")" ] || fail "$profile has no tier"
done

# The real overlay: app values, then the profile, then the environment, exactly
# as the ApplicationSet orders them. This is what proves precedence and that the
# environment files fit both charts' schemas.
if command -v helm >/dev/null; then
  cat >"$tmp/api-values.yaml" <<'YAML'
app:
  name: app1
image:
  repository: example/app1-api
  digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
platform:
  chartVersion: "0.1.0"
YAML

  cat >"$tmp/web-values.yaml" <<'YAML'
app:
  name: app1
image:
  repository: example/app1-web
  digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
platform:
  chartVersion: "0.1.0"
YAML

  for env in dev staging; do
    helm template app1-api charts/app-api --kube-version 1.37.0 \
      -f "$tmp/api-values.yaml" \
      -f profiles/internal/values.yaml \
      -f "environments/$env/values.yaml" \
      --set migrations.ownerSecret.name=app1-owner \
      --set caSecret.name=foundry-rds-ca >"$tmp/api-$env.yaml" \
      || fail "api overlay $env does not render"

    api_replicas=$(yq -r 'select(.kind == "Deployment") | .spec.replicas' "$tmp/api-$env.yaml")
    if [ "$env" = dev ]; then
      [ "$api_replicas" = "1" ] || fail "dev api replicas is $api_replicas, want 1"
      if grep -q 'kind: PodDisruptionBudget' "$tmp/api-$env.yaml"; then
        fail "dev api rendered a PDB"
      fi
    else
      [ "$api_replicas" = "2" ] || fail "staging api replicas is $api_replicas, want 2"
      grep -q 'kind: PodDisruptionBudget' "$tmp/api-$env.yaml" || fail "staging api has no PDB"
    fi
    grep -q 'kind: Job' "$tmp/api-$env.yaml" || fail "$env api has no migration Job"

    helm template app1-web charts/app-web --kube-version 1.37.0 \
      -f "$tmp/web-values.yaml" \
      -f profiles/internal/values.yaml \
      -f "environments/$env/values.yaml" >"$tmp/web-$env.yaml" \
      || fail "web overlay $env does not render"

    web_replicas=$(yq -r 'select(.kind == "Deployment") | .spec.replicas' "$tmp/web-$env.yaml")
    if [ "$env" = dev ]; then
      [ "$web_replicas" = "1" ] || fail "dev web replicas is $web_replicas, want 1"
    else
      [ "$web_replicas" = "2" ] || fail "staging web replicas is $web_replicas, want 2"
      grep -q 'kind: PodDisruptionBudget' "$tmp/web-$env.yaml" || fail "staging web has no PDB"
    fi
    if grep -q 'kind: Job' "$tmp/web-$env.yaml"; then
      fail "$env web rendered a migration Job"
    fi
  done
else
  echo "helm not found: skipping overlay render"
fi

echo "argocd ok"
