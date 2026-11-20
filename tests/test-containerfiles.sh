#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify all three profiles use the same openSUSE CLI package set.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

toolchain=scripts/install-cli-toolchain.sh
bash -n "$toolchain"

for profile in strict usb nested; do
  file="Containerfile.$profile"
  [[ -f "$file" ]]
  grep -Fqx 'FROM docker.io/opensuse/tumbleweed:latest' "$file"
  grep -Fq 'COPY scripts/install-cli-toolchain.sh /tmp/install-cli-toolchain.sh' "$file"
  grep -Fq 'RUN bash /tmp/install-cli-toolchain.sh' "$file"
  grep -Fq 'SHELL=/usr/bin/fish' "$file"
  grep -Fq 'NPM_CONFIG_PREFIX=/work/.npm-global' "$file"
  grep -Fq 'CARGO_HOME=/work/.cargo' "$file"
  grep -Fq 'GOPATH=/work/go' "$file"
  grep -Fq 'GOBIN=/work/go/bin' "$file"
  grep -Fq '/work/.npm-global/bin:/work/.local/bin:/work/.cargo/bin:/work/go/bin' "$file"
  grep -Fqx 'CMD ["/usr/bin/fish"]' "$file"
  if grep -Eq 'apt-get|DEBIAN_FRONTEND|debian:|fedora:|dnf' "$file"; then
    echo "Unexpected non-openSUSE instructions in $file" >&2
    exit 1
  fi
done

for rpm in \
  bash nano fish nodejs26 npm26 nodejs26-devel corepack24 python3 python3-pip \
  python3-devel python3-virtualenv python3-pipx python3-uv rust cargo go curl wget unzip \
  gcc gcc-c++ make pkgconf-pkg-config libopenssl-devel procps; do
  grep -Fqx "  $rpm" "$toolchain"
done

for rpm in nodejs nodejs24 nodejs-npm nodejs-devel nodejs26-bin nodejs26-npm-bin \
           nodejs-corepack python-unversioned-command golang procps-ng; do
  if grep -Fqx "  $rpm" "$toolchain"; then
    echo "Unexpected package for Tumbleweed: $rpm" >&2
    exit 1
  fi
done
grep -Fq 'zypper --non-interactive dup --no-recommends' "$toolchain"
grep -Fq 'zypper --non-interactive addrepo' "$toolchain"
grep -Fq 'https://download.opensuse.org/repositories/shells:fish/openSUSE_Tumbleweed/shells:fish.repo' "$toolchain"
grep -Fq 'zypper --non-interactive --gpg-auto-import-keys refresh' "$toolchain"
grep -Fq 'fish_arch=$(rpm --eval' "$toolchain"
grep -Fq 'Expected OBS fish 4.9.3 or newer' "$toolchain"
grep -Fq 'zypper --non-interactive install --no-recommends "${packages[@]}" "$@"' "$toolchain"
grep -Fq 'ln -s /usr/bin/python3 /usr/local/bin/python' "$toolchain"
if grep -Fq 'zypper --non-interactive patch-check' "$toolchain"; then
  echo 'Tumbleweed does not provide the patch metadata needed for this gate.' >&2
  exit 1
fi
if grep -Eq 'npm install --global|npm@12' "$toolchain"; then
  echo 'npm must remain openSUSE-packaged; do not bootstrap from npm registry.' >&2
  exit 1
fi

for excluded_rpm in gh ruby ruby-devel rubygems rubygem-bundler php-cli perl lua \
                    java-25-openjdk-headless clang git-lfs; do
  if grep -Fqx "  $excluded_rpm" "$toolchain"; then
    echo "Nonessential RPM unexpectedly included: $excluded_rpm" >&2
    exit 1
  fi
done

# openSUSE Corepack ships pnpm and yarn shims; don't overwrite them.
if grep -Eq '^[[:space:]]+pnpm[[:space:]]*$' "$toolchain"; then
  echo 'Do not install pnpm alongside corepack24.' >&2
  exit 1
fi

grep -Fqx '!scripts/install-cli-toolchain.sh' .dockerignore
grep -Fq 'usbutils' Containerfile.usb
grep -Fq 'libusb-1_0-0' Containerfile.usb
grep -Fq 'libusb-1_0-devel' Containerfile.usb
grep -Fq 'bubblewrap' Containerfile.nested
grep -Fqx '  util-linux' "$toolchain"

echo 'All Tumbleweed CLI toolchain and Containerfile checks passed.'
