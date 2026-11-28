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

appset=argocd/clusters/staging/appset.yaml

# Plain YAML under argocd/ parses, the ApplicationSet included: it is a Go
# template, but every action sits inside a quoted scalar or a block scalar, so
# the raw file is valid YAML and root can apply it.
while IFS= read -r file; do
  yq eval '.' "$file" >/dev/null || fail "parse $file"
done < <(find argocd -name '*.yaml' -type f | sort)

rendered="$tmp/appset.yaml"
patch_tpl="$tmp/patch.tpl"
patch_api="$tmp/patch-api-only.yaml"
patch_web="$tmp/patch-web.yaml"

# Render with the pin the registry actually declares, so the assertions below
# follow a chart release instead of a literal that has to be edited twice.
chart_version=$(yq -r '.chartVersion' argocd/apps/app1.yaml)
[ -n "$chart_version" ] && [ "$chart_version" != "null" ] || fail "registry has no chartVersion"
foundry_tag="v${chart_version}"

# Substitute the fixture parameters. The controller marshals the template and
# templates that text, so substitution is the same render for scalar values.
python3 - "$appset" "$rendered" "$chart_version" <<'PYEOF'
import sys

src = open(sys.argv[1]).read()
for key, value in {
    ".name": "app1",
    ".env": "dev",
    ".tier": "internal",
    ".repo": "https://github.com/saxeum/app1.git",
    ".revision": "main",
    ".namespace": "app1",
    ".chartVersion": sys.argv[3],
    ".host": "app1.foonix.net",
}.items():
    src = src.replace("{{ " + key + " }}", value)
open(sys.argv[2], "w").write(src)
PYEOF

yq eval '.' "$rendered" >/dev/null || fail "rendered ApplicationSet is not valid YAML"

# The raw file still uses the parameters the fixture replaced.
for expr in '{{ .name }}' '{{ .env }}' '{{ .tier }}' '{{ .repo }}' '{{ .revision }}' '{{ .namespace }}' '{{ .chartVersion }}' '{{ .host }}'; do
  grep -qF "$expr" "$appset" || fail "ApplicationSet does not use $expr"
done

# templatePatch is a merge patch: Argo renders it, unmarshals the result into an
# Application, and merges. A JSON-6902 array is rejected outright, and a merge
# patch replaces an array rather than removing one element, so an API-only app
# restates the three sources it keeps. The renderer below understands exactly
# the two actions asserted here; any other action fails instead of being ignored.
yq -r '.spec.templatePatch' "$rendered" > "$patch_tpl"
grep -qF '{{- if not .web }}' "$patch_tpl" || fail "templatePatch has no '{{- if not .web }}' guard"
grep -qF '{{- end }}' "$patch_tpl" || fail "templatePatch has no '{{- end }}'"

python3 - "$patch_tpl" "$patch_api" "$patch_web" <<'PYEOF'
import sys

src = open(sys.argv[1]).read()
rendered = {}
for web in (True, False):
    keep, out = [], []
    for line in src.splitlines(keepends=True):
        action = line.strip()
        if action == "{{- if not .web }}":
            keep.append(not web)
            continue
        if action == "{{- end }}":
            keep.pop()
            continue
        if all(keep):
            out.append(line)
    rendered[web] = "".join(out)
open(sys.argv[2], "w").write(rendered[False])
open(sys.argv[3], "w").write(rendered[True])
PYEOF

[ -z "$(tr -d '[:space:]' < "$patch_web")" ] || fail "templatePatch is not empty for a web app"
yq -e 'has("spec") and ((keys | length) == 1)' "$patch_api" >/dev/null \
  || fail "templatePatch patches more than spec"
yq -e '.spec | keys | join(",") == "sources"' "$patch_api" >/dev/null \
  || fail "templatePatch patches more than spec.sources"
api_sources=$(yq -r '.spec.sources | length' "$patch_api")
[ "$api_sources" = "3" ] || fail "the api-only patch has $api_sources sources, want 3"
if yq -e '.spec.sources[] | select(.path == "charts/app-web")' "$patch_api" >/dev/null 2>&1; then
  fail "the api-only patch still has the web source"
fi
# The patch restates the template's first three sources; the two must not drift.
diff <(yq -o=json '.spec.template.spec.sources | .[0:3]' "$rendered") \
     <(yq -o=json '.spec.sources' "$patch_api") >/dev/null \
  || fail "templatePatch sources differ from the template's first three"

# A web app keeps all four template sources: app, foundry, api, web.
web_sources=$(yq -r '.spec.template.spec.sources | length' "$rendered")
[ "$web_sources" = "4" ] || fail "the template has $web_sources sources, want 4"
yq -e '.spec.template.spec.sources[] | select(.path == "charts/app-web")' "$rendered" >/dev/null \
  || fail "the template has no web source"

# The gate #39 was missing. foundry values from main plus charts from the tag
# is exactly what Argo refuses to generate.
for repo in $(yq -r '.spec.template.spec.sources[].repoURL' "$rendered" | sort -u); do
  revisions=$(yq -r ".spec.template.spec.sources[] | select(.repoURL == \"$repo\") | .targetRevision" "$rendered" | sort -u | sed '/^$/d')
  count=$(printf '%s\n' "$revisions" | wc -l | tr -d ' ')
  [ "$count" = "1" ] || fail "$repo is read at $count revisions; Argo CD allows one"
done

for chart in charts/app-api charts/app-web; do
  yq -e ".spec.template.spec.sources[] | select(.path == \"$chart\")" "$rendered" >/dev/null \
    || fail "appset has no source for $chart"
done

for ref in app foundry; do
  yq -e ".spec.template.spec.sources[] | select(.ref == \"$ref\")" "$rendered" >/dev/null \
    || fail "appset has no $ref ref"
done

# The app ref follows the registry revision. The foundry ref carries the
# profile and environment values and must be the same release tag as the chart
# sources: Argo rejects one repository read at two revisions.
yq -e '.spec.template.spec.sources[] | select(.ref == "app") | .targetRevision == "main"' "$rendered" >/dev/null \
  || fail "app ref is not the registry revision"
yq -e ".spec.template.spec.sources[] | select(.ref == \"foundry\") | .targetRevision == \"$foundry_tag\"" "$rendered" >/dev/null \
  || fail "foundry ref is not the chart release tag"
yq -e '.spec.template.spec.sources[] | select(.ref == "foundry") | has("path") | not' "$rendered" >/dev/null \
  || fail "foundry ref must be a value source, not a path"

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

yq -e ".spec.template.spec.sources[] | select(.path == \"charts/app-api\") | .targetRevision == \"$foundry_tag\"" "$rendered" >/dev/null \
  || fail "api chart is not pinned to the release tag"
yq -e ".spec.template.spec.sources[] | select(.path == \"charts/app-web\") | .targetRevision == \"$foundry_tag\"" "$rendered" >/dev/null \
  || fail "web chart is not pinned to the release tag"

yq -e '.spec.template.spec.sources[] | select(.path == "charts/app-api") | .helm.parameters[] | select(.name == "migrations.ownerSecret.name") | .value == "app1-owner"' "$rendered" >/dev/null \
  || fail "api source does not pass the owner secret"
yq -e '.spec.template.spec.sources[] | select(.path == "charts/app-api") | .helm.parameters[] | select(.name == "caSecret.name") | .value == "foundry-rds-ca"' "$rendered" >/dev/null \
  || fail "api source does not pass the CA secret"

# An Application may not create its Namespace: that is cluster-scoped, and the
# app project whitelists nothing cluster-scoped. The namespace and its PSA
# labels come from onboarding, which runs before the registry entry exists.
yq -e '([.spec.template.spec.syncPolicy.syncOptions // [] | .[] | select(. == "CreateNamespace=true")] | length) == 0' "$rendered" >/dev/null \
  || fail "appset asks Argo to create a Namespace, which the app project forbids"
[ -z "$(yq -r '.spec.template.spec.syncPolicy.managedNamespaceMetadata // ""' "$rendered")" ] \
  || fail "appset manages namespace metadata, which the app project forbids"
for label in enforce audit warn; do
  grep -qF "pod-security.kubernetes.io/${label}=restricted" scripts/onboard-app.sh \
    || fail "onboard-app.sh does not set ${label}=restricted on the namespace"
done
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

[ "$(yq -r '.serviceMonitor.enabled' environments/staging/values.yaml)" = "true" ] \
  || fail "staging does not scrape app ServiceMonitors"
[ "$(yq -r '.prometheusRule.enabled' environments/staging/values.yaml)" = "true" ] \
  || fail "staging does not apply app PrometheusRules"

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
  chartVersion: "0.3.0"
YAML

  cat >"$tmp/web-values.yaml" <<'YAML'
app:
  name: app1
image:
  repository: example/app1-web
  digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
platform:
  chartVersion: "0.3.0"
YAML

  for env in dev staging; do
    # The ApplicationSet passes the host as a parameter, so the render does too:
    # a staging overlay with ingress on needs it, and rendering without it would
    # test a configuration that never ships.
    helm template app1-api charts/app-api --kube-version 1.37.0 \
      -f "$tmp/api-values.yaml" \
      -f profiles/internal/values.yaml \
      -f "environments/$env/values.yaml" \
      --set ingress.host=app1.foonix.net \
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
      -f "environments/$env/values.yaml" \
      --set ingress.host=app1.foonix.net >"$tmp/web-$env.yaml" \
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
