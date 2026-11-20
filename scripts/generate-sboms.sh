#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Generate full downloadable SBOMs and a tiny signed digest manifest.
set -euo pipefail

: "${IMAGE:?IMAGE is required}"
: "${DIGEST:?DIGEST is required}"
: "${SYFT_BIN:?SYFT_BIN is required}"

mkdir -p sboms
for arch in amd64 arm64; do
  source="registry:${IMAGE}@${DIGEST}"
  full="sboms/${arch}.spdx.json"

  # No file-size limit: preserve the complete package and file inventory.
  "$SYFT_BIN" "$source" --platform "linux/$arch" \
    -o "spdx-json=$full"
  test -s "$full"
  echo "linux/$arch full SPDX SBOM: $(wc -c < "$full") bytes"
done

# actions/attest limits its predicate to 16 MiB, regardless of SBOM format.
# Sign the full SBOM files as subjects and separately bind their SHA-256
# digests to the OCI image through this small custom predicate.
amd64_file=sboms/amd64.spdx.json
arm64_file=sboms/arm64.spdx.json
amd64_sha=$(sha256sum "$amd64_file" | cut -d ' ' -f1)
arm64_sha=$(sha256sum "$arm64_file" | cut -d ' ' -f1)
amd64_bytes=$(wc -c < "$amd64_file")
arm64_bytes=$(wc -c < "$arm64_file")

jq -n \
  --arg amd64_hash "$amd64_sha" --arg arm64_hash "$arm64_sha" \
  --argjson amd64_size "$amd64_bytes" --argjson arm64_size "$arm64_bytes" \
  '{schemaVersion: 1, format: "SPDX JSON", digestAlgorithm: "sha256",
    sboms: [
      {platform: "linux/amd64", path: "sboms/amd64.spdx.json", sha256: $amd64_hash, sizeBytes: $amd64_size},
      {platform: "linux/arm64", path: "sboms/arm64.spdx.json", sha256: $arm64_hash, sizeBytes: $arm64_size}
    ]}' > sboms/sbom-digests.json

test -s sboms/sbom-digests.json
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '%s\n' '- Full amd64/arm64 SPDX SBOMs retained; full-file provenance and image-bound SHA-256 digest manifest are attested.' >> "$GITHUB_STEP_SUMMARY"
fi
