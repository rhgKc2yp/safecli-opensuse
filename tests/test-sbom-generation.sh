#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify oversized full SBOMs can be digested without trimming their content.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
script="$PWD/scripts/generate-sboms.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# Mock large Syft output without fetching images or needing registry credentials.
cat > "$test_dir/syft" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
target=''
platform=''
for arg in "$@"; do
  case "$arg" in
    spdx-json=*) target=${arg#spdx-json=} ;;
    linux/amd64|linux/arm64) platform=$arg ;;
    --select-catalogers=*) echo 'Full SBOM must not filter catalogers.' >&2; exit 1 ;;
  esac
done
[[ -n "$target" ]]
[[ -n "$platform" ]]
{
  printf '{"spdxVersion":"SPDX-2.3","packages":[{"name":"%s"}],"payload":"' "$platform"
  head -c 17000000 /dev/zero | tr '\0' x
  printf '"}\n'
} > "$target"
MOCK
chmod +x "$test_dir/syft"

mkdir -p "$test_dir/oversized"
(
  cd "$test_dir/oversized"
  IMAGE=ghcr.io/example/test DIGEST=sha256:abc SYFT_BIN="$test_dir/syft" \
    GITHUB_STEP_SUMMARY="$test_dir/summary" bash "$script"

  # Both complete files are bigger than GitHub's 16 MiB predicate limit.
  [[ $(wc -c < sboms/amd64.spdx.json) -gt 16777216 ]]
  [[ $(wc -c < sboms/arm64.spdx.json) -gt 16777216 ]]
  [[ $(wc -c < sboms/sbom-digests.json) -lt 4096 ]]
  for arch in amd64 arm64; do
    expected_hash=$(sha256sum "sboms/$arch.spdx.json" | cut -d ' ' -f1)
    actual_hash=$(jq -r --arg arch "linux/$arch" '.sboms[] | select(.platform == $arch) | .sha256' sboms/sbom-digests.json)
    [[ "$actual_hash" == "$expected_hash" ]]
    actual_size=$(jq -r --arg arch "linux/$arch" '.sboms[] | select(.platform == $arch) | .sizeBytes' sboms/sbom-digests.json)
    [[ "$actual_size" == "$(wc -c < "sboms/$arch.spdx.json")" ]]
  done
  grep -Fq 'full-file provenance and image-bound SHA-256' "$test_dir/summary"
)

echo 'Oversized SBOM digest-manifest generation checks passed.'
