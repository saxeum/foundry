#!/usr/bin/env bash
#
# Copy templates/app to a sibling directory and replace the name placeholders.
# The platform repo stays the source of the template; the new app is its own
# repository from the first commit.
set -euo pipefail

name="${1:-}"
if [[ ! "$name" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
  echo "usage: $0 <name>" >&2
  echo "name must be lowercase letters, digits and hyphens, starting with a letter" >&2
  exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
dest="$root/../$name"

if [ -e "$dest" ]; then
  echo "$dest already exists" >&2
  exit 1
fi

cp -a "$root/templates/app" "$dest"

# Replace only text files. The generated Go, the SQL and the image are already
# independent of the name.
while IFS= read -r file; do
  sed -i "s|__APP_NAME__|$name|g" "$file"
done < <(grep -rlI '__APP_NAME__' "$dest")

if command -v git >/dev/null; then
  (cd "$dest" && git init -q -b main && git add -A && \
    git -c user.name=foundry -c user.email=foundry@example.com commit -q -m "Initial app from the foundry template")
fi

echo "created $dest"
echo
echo "next:"
echo "  1. set image.repository in $name/deploy/api/values.yaml"
echo "  2. create the ECR repos and push role, and run scripts/onboard-app.sh"
echo "  3. add argocd/apps/$name.yaml and argocd/clusters/staging/projects/$name.yaml"
echo "  4. cd $dest && make test && make conformance"
