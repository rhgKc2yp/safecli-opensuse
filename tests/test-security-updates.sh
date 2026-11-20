#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Static regression checks for the security-update path and publishing cadence.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

for profile in strict usb nested; do
  file="Containerfile.$profile"
  grep -Fqx 'FROM docker.io/opensuse/tumbleweed:latest' "$file"
  grep -Fq 'COPY scripts/install-cli-toolchain.sh /tmp/install-cli-toolchain.sh' "$file"
done
grep -Fq 'zypper --non-interactive refresh' scripts/install-cli-toolchain.sh
grep -Fq 'zypper --non-interactive addrepo' scripts/install-cli-toolchain.sh
grep -Fq 'zypper --non-interactive --gpg-auto-import-keys refresh' scripts/install-cli-toolchain.sh
grep -Fq 'zypper --non-interactive dup --no-recommends' scripts/install-cli-toolchain.sh
grep -Fq 'zypper --non-interactive install --no-recommends "${packages[@]}" "$@"' scripts/install-cli-toolchain.sh
grep -Fq 'zypper --non-interactive patch-check' scripts/install-cli-toolchain.sh
grep -Fq 'zypper --non-interactive clean --all' scripts/install-cli-toolchain.sh

wf=.github/workflows/publish-ghcr.yml
grep -Fq -- "- cron: '23 4 */3 * *'" "$wf"
grep -Fq 'pull: true' "$wf"
grep -Fq 'no-cache: true' "$wf"
grep -Fq 'uses: actions/checkout@v7' "$wf"
grep -Fq 'uses: actions/upload-artifact@v7' "$wf"
grep -Fq 'uses: actions/download-artifact@v8' "$wf"
grep -Fq 'uses: actions/attest@v4' "$wf"
grep -Fq 'sbom: true' "$wf"
grep -Fq 'run: bash scripts/generate-sboms.sh' "$wf"
grep -Fq 'subject-path: |' "$wf"
grep -Fq 'predicate-path: sboms/sbom-digests.json' "$wf"
grep -Fq 'predicate-type: https://github.com/' "$wf"
if grep -Fq 'sbom-path:' "$wf"; then
  echo 'Do not pass oversized full SBOMs as predicates.' >&2
  exit 1
fi
grep -Fq -- '--platform "linux/$arch"' scripts/generate-sboms.sh
grep -Fq 'sha256sum "$amd64_file"' scripts/generate-sboms.sh
grep -Fq 'sha256sum "$arm64_file"' scripts/generate-sboms.sh
grep -Fq 'cosign sign --yes' "$wf"
grep -Fq 'bash scripts/promote-image.sh' "$wf"

# Prevent accidental reintroduction of Fedora or a pinned stale snapshot.
if grep -ERq '^FROM .*fedora:|^FROM .*tumbleweed:[0-9]+' Containerfile.*; then
  echo 'ERROR: Base images must track openSUSE Tumbleweed latest.' >&2
  exit 1
fi

# Verify the root license text and separate treatment of upstream software.
grep -Fq 'MIT License' LICENSE
grep -Fq 'Copyright (c) 2026' LICENSE
grep -Fq 'upstream' THIRD_PARTY_NOTICES.md

echo 'Tumbleweed rolling updates and four supply-chain safeguard checks passed.'
