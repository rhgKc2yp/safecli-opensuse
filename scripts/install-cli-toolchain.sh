#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Shared openSUSE Tumbleweed CLI toolchain for strict, usb and nested images.
# Additional arguments are profile-specific RPM packages.
set -euo pipefail

packages=(
  # Essential shells, downloads and Git transport.
  bash
  nano
  fish
  ca-certificates
  curl
  wget
  openssl
  git
  openssh-clients

  # Standard UNIX tools, archives and text processing.
  coreutils
  findutils
  diffutils
  grep
  sed
  gawk
  which
  file
  less
  procps
  util-linux
  tar
  gzip
  bzip2
  xz
  zstd
  zip
  unzip
  patch
  jq
  ripgrep

  # Tumbleweed splits Node 26, npm 26 and Corepack 24 into RPM packages.
  # npm26 ships the matching npm 11; no separate pnpm/Yarn installation.
  nodejs26
  npm26
  nodejs26-devel
  corepack24

  # Default Python 3 providers, pip, virtualenv, pipx and uv.
  # The unversioned `python` link is added below if the RPMs omit it.
  python3
  python3-pip
  python3-devel
  python3-virtualenv
  python3-pipx
  python3-uv

  # Rust and Go compilers / package managers.
  rust
  cargo
  go

  # Minimal native-build prerequisites for Node/Python/Rust dependencies.
  gcc
  gcc-c++
  make
  cmake
  pkgconf-pkg-config
  libopenssl-devel
  libffi-devel
  zlib-devel
)

# The requested shells:fish OBS repository currently publishes Tumbleweed
# x86_64 packages, but not aarch64. On arm64 retain Tumbleweed's stock fish;
# never install an x86_64 RPM or change the image's supported architectures.
fish_arch=$(rpm --eval '%{_arch}')
case "$fish_arch" in
  x86_64)
    zypper --non-interactive addrepo \
      'https://download.opensuse.org/repositories/shells:fish/openSUSE_Tumbleweed/shells:fish.repo'
    # Noninteractive builders must import the OBS repository's signing key.
    # Zypper still verifies signed repository metadata and RPM signatures.
    zypper --non-interactive --gpg-auto-import-keys refresh
    ;;
  aarch64)
    zypper --non-interactive refresh
    ;;
  *) echo "Unsupported architecture for safecli fish: $fish_arch" >&2; exit 1 ;;
esac

# Tumbleweed is a rolling release: update to the latest tested snapshot with
# `dup`, not `up` or Fedora's DNF. Keep weak dependencies out of the toolchain.
# The OBS repo stays configured so later zypper updates can upgrade x86_64 fish.
zypper --non-interactive dup --no-recommends
zypper --non-interactive install --no-recommends "${packages[@]}" "$@"

zypper --non-interactive clean --all

# Match Fedora's `python` -> `python3` CLI without installing a foreign RPM.
if ! command -v python >/dev/null 2>&1; then
  mkdir -p /usr/local/bin
  ln -s /usr/bin/python3 /usr/local/bin/python
fi

# Fail image builds if an RPM stops exposing a required CLI.
for binary in fish nano node npm npx corepack python python3 pip3 virtualenv pipx uv rustc cargo go; do
  command -v "$binary" >/dev/null || {
    echo "Missing expected executable after RPM installation: $binary" >&2
    exit 1
  }
done

[[ $(readlink -f "$(command -v python)") == "$(readlink -f "$(command -v python3)")" ]] || {
  echo 'Expected python to resolve to the same Python 3 interpreter as python3.' >&2
  exit 1
}

[[ $(node --version) == v26.* ]] || { echo 'Expected Node.js 26.' >&2; exit 1; }
[[ $(npm --version) == 11.* ]] || { echo 'Expected openSUSE npm 11.' >&2; exit 1; }
fish_output=$(fish --version)
[[ $fish_output == 'fish, version '* ]] || {
  echo 'Expected the openSUSE-packaged fish shell.' >&2
  exit 1
}
fish_version=${fish_output#fish, version }
[[ $fish_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Unexpected fish version: $fish_output" >&2
  exit 1
}
if [[ $fish_arch == x86_64 ]]; then
  # A missing/empty OBS repo must not silently fall back to old stock fish.
  [[ $(printf '%s\n%s\n' 4.9.3 "$fish_version" | sort -V | head -n 1) == 4.9.3 ]] || {
    echo "Expected OBS fish 4.9.3 or newer on x86_64; got $fish_version." >&2
    exit 1
  }
fi
