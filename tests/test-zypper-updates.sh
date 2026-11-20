#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify Tumbleweed update/patch checks fail closed without needing Zypper or a network.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
installer="$PWD/scripts/install-cli-toolchain.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"

cat > "$test_dir/bin/zypper" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_ZYPPER_CALLS"
[[ "${1:-}" == --non-interactive ]] || exit 90
case "${2:-}" in
  addrepo) exit "${MOCK_ADDREPO_STATUS:-0}" ;;
  --gpg-auto-import-keys)
    [[ "${3:-}" == refresh ]] || exit 92
    exit "${MOCK_KEY_REFRESH_STATUS:-0}"
    ;;
  refresh) exit "${MOCK_REFRESH_STATUS:-0}" ;;
  dup) exit "${MOCK_DUP_STATUS:-0}" ;;
  install) exit "${MOCK_INSTALL_STATUS:-0}" ;;
  patch-check) exit "${MOCK_PATCH_STATUS:-0}" ;;
  clean) exit "${MOCK_CLEAN_STATUS:-0}" ;;
  *) exit 91 ;;
esac
MOCK
cat > "$test_dir/bin/rpm" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == --eval && "${2:-}" == '%{_arch}' ]] || exit 1
printf '%s\n' "${MOCK_RPM_ARCH:-x86_64}"
MOCK
cat > "$test_dir/bin/node" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_NODE_VERSION:-v26.13.0}"
MOCK
cat > "$test_dir/bin/npm" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_NPM_VERSION:-11.10.0}"
MOCK
cat > "$test_dir/bin/fish" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_FISH_VERSION:-fish, version 4.9.3}"
MOCK
chmod +x "$test_dir/bin/"{zypper,rpm,node,npm,fish}

# Stub commands required by the installed-binary assertions, including both
# Python names resolving to exactly the same interpreter.
for binary in nano npx corepack python python3 pip3 virtualenv pipx uv rustc cargo go; do
  ln -s /usr/bin/true "$test_dir/bin/$binary"
done
export PATH="$test_dir/bin:$PATH"
export MOCK_ZYPPER_CALLS="$test_dir/zypper.calls"

bash "$installer" > "$test_dir/clean.log"
grep -Fq 'openSUSE patch check passed.' "$test_dir/clean.log"
grep -Fqx -- '--non-interactive addrepo https://download.opensuse.org/repositories/shells:fish/openSUSE_Tumbleweed/shells:fish.repo' "$MOCK_ZYPPER_CALLS"
grep -Fqx -- '--non-interactive --gpg-auto-import-keys refresh' "$MOCK_ZYPPER_CALLS"
grep -Fqx -- '--non-interactive dup --no-recommends' "$MOCK_ZYPPER_CALLS"
grep -Fq -- '--non-interactive install --no-recommends bash nano fish' "$MOCK_ZYPPER_CALLS"
grep -Fq -- 'nodejs26 npm26 nodejs26-devel corepack24' "$MOCK_ZYPPER_CALLS"
grep -Fq -- 'python3 python3-pip python3-devel python3-virtualenv python3-pipx python3-uv' "$MOCK_ZYPPER_CALLS"
grep -Fqx -- '--non-interactive patch-check' "$MOCK_ZYPPER_CALLS"
grep -Fqx -- '--non-interactive clean --all' "$MOCK_ZYPPER_CALLS"

# arm64 must not add an OBS repository without aarch64 packages, and must
# continue to accept the stock Tumbleweed fish version.
: > "$MOCK_ZYPPER_CALLS"
MOCK_RPM_ARCH=aarch64 MOCK_FISH_VERSION='fish, version 4.8.1' \
  bash "$installer" > "$test_dir/arm64.log"
grep -Fqx -- '--non-interactive refresh' "$MOCK_ZYPPER_CALLS"
if grep -Fq 'addrepo' "$MOCK_ZYPPER_CALLS"; then
  echo 'ERROR: arm64 incorrectly configured the x86_64-only OBS fish repository.' >&2
  exit 1
fi

# Profile-specific additions must pass to the same Zypper invocation.
bash "$installer" libusb-1_0-0 libusb-1_0-devel > /dev/null
grep -Fq -- 'libusb-1_0-0 libusb-1_0-devel' "$MOCK_ZYPPER_CALLS"

for failure_case in patch_100 patch_101 query_error addrepo_error key_refresh_error refresh_error dup_error install_error clean_error wrong_node wrong_npm wrong_fish old_obs_fish unsupported_arch; do
  case "$failure_case" in
    patch_100) failure_env=(MOCK_PATCH_STATUS=100) ;;
    patch_101) failure_env=(MOCK_PATCH_STATUS=101) ;;
    query_error) failure_env=(MOCK_PATCH_STATUS=42) ;;
    addrepo_error) failure_env=(MOCK_ADDREPO_STATUS=42) ;;
    key_refresh_error) failure_env=(MOCK_KEY_REFRESH_STATUS=42) ;;
    refresh_error) failure_env=(MOCK_RPM_ARCH=aarch64 MOCK_REFRESH_STATUS=42) ;;
    dup_error) failure_env=(MOCK_DUP_STATUS=42) ;;
    install_error) failure_env=(MOCK_INSTALL_STATUS=42) ;;
    clean_error) failure_env=(MOCK_CLEAN_STATUS=42) ;;
    wrong_node) failure_env=(MOCK_NODE_VERSION=v24.0.0) ;;
    wrong_npm) failure_env=(MOCK_NPM_VERSION=12.0.0) ;;
    wrong_fish) failure_env=(MOCK_FISH_VERSION='fish version unknown') ;;
    old_obs_fish) failure_env=(MOCK_FISH_VERSION='fish, version 4.8.1') ;;
    unsupported_arch) failure_env=(MOCK_RPM_ARCH=i686) ;;
  esac
  if env "${failure_env[@]}" bash "$installer" > "$test_dir/$failure_case.log" 2>&1; then
    echo "ERROR: $failure_case unexpectedly succeeded." >&2
    exit 1
  fi
done
grep -Fq 'patch check returned 100' "$test_dir/patch_100.log"
grep -Fq 'patch check returned 101' "$test_dir/patch_101.log"
grep -Fq 'patch check returned 42' "$test_dir/query_error.log"
grep -Fq 'Expected Node.js 26' "$test_dir/wrong_node.log"
grep -Fq 'Expected openSUSE npm 11' "$test_dir/wrong_npm.log"
grep -Fq 'Expected the openSUSE-packaged fish' "$test_dir/wrong_fish.log"
grep -Fq 'Expected OBS fish 4.9.3 or newer' "$test_dir/old_obs_fish.log"
grep -Fq 'Unsupported architecture for safecli fish: i686' "$test_dir/unsupported_arch.log"

echo 'Tumbleweed x86_64 OBS fish, aarch64 fallback, patch and failure cases passed.'
