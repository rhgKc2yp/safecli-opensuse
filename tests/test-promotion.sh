#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Mock promotion rules. No Docker/GHCR access needed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == buildx && "$2" == imagetools && "$3" == create ]] || exit 9
printf '%s\n' "$@" > "$MOCK_ARGS"
prev=''
for a in "$@"; do
  if [[ "$prev" == --metadata-file ]]; then
    printf '{"containerimage.descriptor":{"digest":"%s"}}\n' "$DIGEST" > "$a"
  fi
  prev="$a"
done
MOCK
chmod +x "$tmp/bin/docker"
cat > "$tmp/bin/jq" <<'MOCK'
#!/usr/bin/env bash
sed -n 's/.*"digest":"\([^"]*\)".*/\1/p' "$3"
MOCK
chmod +x "$tmp/bin/jq"
export PATH="$tmp/bin:$PATH" MOCK_ARGS="$tmp/args"
export IMAGE=ghcr.io/example/repo-strict
export DIGEST="sha256:$(printf 'f%.0s' {1..64})"
export GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2
export GITHUB_REF=refs/heads/main
bash scripts/promote-image.sh >/dev/null
grep -Fqx 'ghcr.io/example/repo-strict:latest' "$MOCK_ARGS"
grep -Fqx 'ghcr.io/example/repo-strict:build-123-2' "$MOCK_ARGS"
if grep -Fq ':v1.2.3' "$MOCK_ARGS"; then exit 1; fi
export GITHUB_REF=refs/tags/v1.2.3
bash scripts/promote-image.sh >/dev/null
grep -Fqx 'ghcr.io/example/repo-strict:v1.2.3' "$MOCK_ARGS"
if grep -Fq ':latest' "$MOCK_ARGS"; then exit 1; fi
export GITHUB_REF=refs/heads/untrusted
if bash scripts/promote-image.sh >/dev/null 2>&1; then exit 1; fi
export GITHUB_REF=refs/heads/main DIGEST=bad
if bash scripts/promote-image.sh >/dev/null 2>&1; then exit 1; fi

echo 'Promotion rules validated with mock Docker.'
