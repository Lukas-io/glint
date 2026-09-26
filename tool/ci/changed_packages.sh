#!/usr/bin/env bash
set -euo pipefail
base="$1"
all=$(cd packages && ls -d */ | tr -d / | sort)
if [ -z "$base" ] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  picked="$all"
else
  changed=$(git diff --name-only "$base" HEAD)
  if echo "$changed" | grep -qvE '^(packages/|fixtures/|[^/]+\.md$)' || echo "$changed" | grep -q '^packages/glint_core/'; then
    picked="$all"
  else
    picked=$(echo "$changed" | sed -n 's#^packages/\([^/]*\)/.*#\1#p' | sort -u)
  fi
fi
bridge=false
if echo "$picked" | grep -qx glint_mcp; then bridge=true; fi
json=$(echo "$picked" | awk 'NF{printf "%s\"%s\"", (n++ ? "," : ""), $0} END{}')
echo "packages=[$json]"
echo "bridge=$bridge"
