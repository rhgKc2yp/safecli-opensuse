#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Promote an already scanned, attested and signed image manifest list.
# Only the calling workflow determines whether all security gates passed.
set -euo pipefail

: "${IMAGE:?IMAGE is required}"
: "${DIGEST:?DIGEST is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"
: "${GITHUB_REF:?GITHUB_REF is required}"

[[ "$IMAGE" =~ ^ghcr\.io/[a-z0-9._/-]+$ ]] || { echo 'Invalid GHCR image name' >&2; exit 2; }
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'Invalid digest' >&2; exit 2; }
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]] || {
  echo 'Invalid GitHub run identifiers' >&2; exit 2;
}

tags=(--tag "${IMAGE}:build-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}")
if [[ "$GITHUB_REF" == refs/heads/main ]]; then
  tags+=(--tag "${IMAGE}:latest")
elif [[ "$GITHUB_REF" == refs/tags/v* ]]; then
  version=${GITHUB_REF#refs/tags/}
  [[ "$version" =~ ^v[0-9][0-9A-Za-z_.-]*$ ]] || {
    echo "Unsupported release tag: $version" >&2; exit 2;
  }
  tags+=(--tag "${IMAGE}:${version}")
else
  echo "Ref is not a publishable main branch or v* tag: $GITHUB_REF" >&2
  exit 2
fi

# For a single multi-platform image index, imagetools creates a carbon copy.
# Check the result to avoid silently promoting a modified digest.
metadata=$(mktemp --suffix=.json)
trap 'rm -f "$metadata"' EXIT
docker buildx imagetools create \
  "${tags[@]}" \
  --metadata-file "$metadata" \
  "${IMAGE}@${DIGEST}"
new_digest=$(jq -er '."containerimage.descriptor".digest' "$metadata")
[[ "$new_digest" == "$DIGEST" ]] || {
  echo "Digest mismatch after promotion: built=$DIGEST promoted=$new_digest" >&2
  exit 1
}
echo "Published verified image: ${IMAGE}@${DIGEST}"
