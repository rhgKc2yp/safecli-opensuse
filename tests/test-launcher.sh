#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fast argument-assembly tests; no Podman daemon or privileged features needed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export MOCK_PODMAN_CREATE="$tmp/create.args"
export MOCK_PODMAN_EXEC="$tmp/exec.args"

cat > "$tmp/bin/podman" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  container) [[ "${2:-}" == exists ]] && exit 1 ;;
  image)
    [[ "${2:-}" == exists ]] || exit 1
    case "${MOCK_PODMAN_IMAGES:-both}" in
      both) exit 0 ;;
      ghcr) [[ "${3:-}" == ghcr.io/owner/podman-safecli-tumbleweed-* ]] ;;
      local) [[ "${3:-}" == localhost/safecli-* ]] ;;
      none) exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  create) printf '%s\n' "$@" > "$MOCK_PODMAN_CREATE" ;;
  inspect)
    case "${3:-}" in
      *State.Running*) echo true ;;
      *) echo missing ;;
    esac
    ;;
  start) exit 0 ;;
  exec)
    if [[ "${MOCK_WORK_WRITABLE:-yes}" == no && "$*" == *'mktemp /work/'* ]]; then
      exit 1
    fi
    printf '%s\n' "$@" > "$MOCK_PODMAN_EXEC"
    ;;
  *) echo "Unexpected mocked Podman call: $*" >&2; exit 1 ;;
esac
MOCK
cat > "$tmp/bin/id" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in -u|-g) echo 1000 ;; *) /usr/bin/id "$@" ;; esac
MOCK
chmod +x "$tmp/bin/podman" "$tmp/bin/id"
export PATH="$tmp/bin:$PATH"
unset NETWORK IMAGE IMAGE_PREFIX IMAGE_TAG USB_DEVICE MOCK_PODMAN_IMAGES MOCK_WORK_WRITABLE

has_arg() { grep -Fqx -- "$1" "$MOCK_PODMAN_CREATE"; }
not_arg() { ! has_arg "$1"; }

./safecli.sh strict mock-strict true
[[ $(tail -n 1 "$MOCK_PODMAN_EXEC") == true ]]
has_arg 'ghcr.io/owner/podman-safecli-tumbleweed-strict:latest'
has_arg '--network=pasta'
has_arg '--pids-limit=192'
has_arg '--memory=1536m'
has_arg '--memory-swap=1536m'
has_arg '--read-only'
has_arg '--env=HOME=/work'
has_arg '--env=XDG_CONFIG_HOME=/work/.config'
has_arg '--env=XDG_DATA_HOME=/work/.local/share'
has_arg '--volume'
has_arg 'safecli-vol-strict-mock-strict:/work:rw,nosuid,nodev,U'
not_arg '--security-opt=seccomp=unconfined'

# A volume permissions failure must stop before running the requested CLI.
if MOCK_WORK_WRITABLE=no ./safecli.sh strict mock-unwritable true 2> "$tmp/work.err"; then
  echo 'ERROR: An unwritable /work unexpectedly passed the startup check.' >&2
  exit 1
fi
grep -Fq '/work is not writable' "$tmp/work.err"

# Select an existing local build when GHCR was not pulled, without changing
# the image chosen by an explicit override.
MOCK_PODMAN_IMAGES=local ./safecli.sh strict mock-local true
has_arg 'localhost/safecli-strict:latest'
IMAGE_PREFIX=localhost/safecli ./safecli.sh strict mock-override true
has_arg 'localhost/safecli-strict:latest'
IMAGE='ghcr.io/example/custom:tag' ./safecli.sh strict mock-exact true
has_arg 'ghcr.io/example/custom:tag'

# Missing images still fail closed and explain how to pull the published image.
if MOCK_PODMAN_IMAGES=none ./safecli.sh strict mock-missing true 2> "$tmp/missing.err"; then
  echo 'ERROR: Missing local and GHCR images unexpectedly passed.' >&2
  exit 1
fi
grep -Fq "podman pull 'ghcr.io/owner/podman-safecli-tumbleweed-strict:latest'" "$tmp/missing.err"
if MOCK_PODMAN_IMAGES=local IMAGE='ghcr.io/example/missing:latest' \
  ./safecli.sh strict mock-explicit-missing true 2> "$tmp/explicit.err"; then
  echo 'ERROR: Explicit IMAGE silently fell back to another image.' >&2
  exit 1
fi

# Invoking the launcher without a command opens fish, not the old /bin/sh.
./safecli.sh strict mock-shell
[[ $(tail -n 1 "$MOCK_PODMAN_EXEC") == /usr/bin/fish ]]

./safecli.sh nested mock-nested true
has_arg '--network=pasta'
has_arg '--pids-limit=384'
has_arg '--memory=3g'
has_arg '--security-opt=seccomp=unconfined'
not_arg '--read-only'

NETWORK=none ./safecli.sh strict mock-offline true
has_arg '--network=none'

if NETWORK=invalid ./safecli.sh strict invalid true 2>/dev/null; then
  echo 'ERROR: invalid NETWORK was accepted' >&2
  exit 1
fi
if ./safecli.sh usb missing-device true 2>/dev/null; then
  echo 'ERROR: usb mode without USB_DEVICE was accepted' >&2
  exit 1
fi

echo 'All safecli launcher tests passed.'
