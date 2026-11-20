#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Linux rootless Podman launcher for unknown CLI programs.
# Usage: ./safecli.sh strict|usb|nested NAME [COMMAND ARG...]
# Examples:
#   ./safecli.sh strict trial
#   USB_DEVICE=/dev/bus/usb/001/005 ./safecli.sh usb probe /work/probe --help
#   ./safecli.sh nested sandbox /usr/bin/fish
set -euo pipefail

usage() {
  cat >&2 <<'HELP'
Usage: safecli.sh {strict|usb|nested} NAME [COMMAND [ARG...]]
  Without COMMAND, open fish (use /bin/sh explicitly for a POSIX shell).
  IMAGE=...                    Exact image (overrides prefix / tag)
  IMAGE_PREFIX=...             Image base (default: ghcr.io/owner/podman-safecli-tumbleweed)
  IMAGE_TAG=...                Image tag (default: latest)
  USB_DEVICE=/dev/...          Required for USB mode, exact character device
  NETWORK=pasta|slirp4netns|none  All modes (default: pasta; none disables network)

The container remains running after the command exits, and is NOT auto-deleted.
The /work named volume persists even if you remove the container.
Use: podman cp ./program CONTAINER:/work/program
     podman stop CONTAINER
     podman start CONTAINER
     podman rm CONTAINER
     podman volume rm safecli-vol-MODE-NAME  # permanent data deletion
HELP
  exit 2
}

(( $# >= 2 )) || usage
mode=$1; name=$2; shift 2
case "$mode" in strict|usb|nested) ;; *) usage ;; esac
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,49}$ ]] || {
  echo 'ERROR: NAME must be 1-50 characters: letters, digits, underscore, dot, hyphen.' >&2
  exit 2
}
command -v podman >/dev/null 2>&1 || { echo 'ERROR: podman not found' >&2; exit 1; }
[[ $(uname -s) == Linux ]] || { echo 'ERROR: Linux host required.' >&2; exit 1; }
(( $(id -u) != 0 )) || { echo 'ERROR: run as regular user; do NOT use sudo.' >&2; exit 1; }

# Prefer the published GHCR image. If absent, use an existing local build
# only when the caller did not explicitly select an image or prefix.
image=${IMAGE:-${IMAGE_PREFIX:-ghcr.io/owner/podman-safecli-tumbleweed}-${mode}:${IMAGE_TAG:-latest}}
container="safecli-${mode}-${name}"
volume="safecli-vol-${mode}-${name}"
net=${NETWORK:-pasta}
case "$net" in pasta|slirp4netns|none) ;;
  *) echo 'ERROR: NETWORK must be pasta, slirp4netns, or none.' >&2; exit 2 ;;
esac

# Probe image only on creation: podman exec on an existing container does not need it.
if ! podman container exists "$container"; then
  if ! podman image exists "$image"; then
    local_image="localhost/safecli-${mode}:${IMAGE_TAG:-latest}"
    if [[ -z "${IMAGE:-}" && -z "${IMAGE_PREFIX:-}" ]] && podman image exists "$local_image"; then
      image=$local_image
    else
      echo "ERROR: Image not available locally: $image" >&2
      echo "Pull a published image: podman pull '$image'" >&2
      echo "Or build locally: podman build -f Containerfile.$mode -t '$local_image' ." >&2
      exit 1
    fi
  fi

  if [[ "$mode" == nested ]]; then
    limit_pids=384; limit_mem=3g
  else
    limit_pids=192; limit_mem=1536m
  fi

  common=(
    --name "$container"
    --label "safecli.profile=$mode"
    --label "safecli.network=$net"
    --pull=never
    --network="$net"
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --pid=private
    --ipc=private
    --uts=private
    --pids-limit="$limit_pids"
    --memory="$limit_mem"
    --memory-swap="$limit_mem"
    --cpus=2
    --ulimit=nofile=1024:1024
    --ulimit=core=0:0
    --workdir=/work
    --env=HOME=/work
    --env=XDG_CACHE_HOME=/work/.cache
    --env=XDG_CONFIG_HOME=/work/.config
    --env=XDG_DATA_HOME=/work/.local/share
    # With --userns=nomap, container UID 1000 maps to a subordinate host UID.
    # :U fixes ownership of this dedicated named volume, including old volumes
    # whose automatic first-mount chown was skipped or no longer matches.
    --volume "$volume:/work:rw,nosuid,nodev,U"
    --stop-timeout=2
  )

  case "$mode" in
    strict)
      common+=(
        --userns=nomap --user=1000:1000
        --read-only
        --tmpfs=/tmp:rw,nosuid,nodev,noexec,size=128m,mode=1777
        --tmpfs=/run:rw,nosuid,nodev,noexec,size=16m
        --tmpfs=/var/tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777
      )
      ;;
    usb)
      dev=${USB_DEVICE:-}
      [[ -n "$dev" ]] || { echo 'ERROR: USB_DEVICE is required in usb mode.' >&2; exit 2; }
      dev=$(readlink -f -- "$dev")
      [[ -c "$dev" ]] || { echo "ERROR: Not a character device: $dev" >&2; exit 2; }
      [[ "$dev" =~ ^(/dev/bus/usb/[0-9]{3}/[0-9]{3}|/dev/(ttyUSB|ttyACM|hidraw)[0-9]+)$ ]] || {
        echo "ERROR: Device outside the allowed USB/serial/hidraw paths: $dev" >&2
        exit 2
      }
      command -v crun >/dev/null 2>&1 || {
        echo 'ERROR: usb mode needs crun for --group-add=keep-groups.' >&2
        exit 1
      }
      common+=(
        --runtime=crun
        --userns=keep-id --user="$(id -u):$(id -g)"
        --group-add=keep-groups
        --device="$dev:$dev:rw"
        --label="safecli.usb=$dev"
        --read-only
        --tmpfs=/tmp:rw,nosuid,nodev,noexec,size=128m,mode=1777
        --tmpfs=/run:rw,nosuid,nodev,noexec,size=16m
        --tmpfs=/var/tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777
      )
      ;;
    nested)
      # Only this mode loosens the default seccomp filter for user-namespace sandboxes.
      # Retains capability drop, no-new-privileges and default SELinux/AppArmor policy.
      common+=(
        --userns=nomap --user=1000:1000
        --security-opt=seccomp=unconfined
        --tmpfs=/tmp:rw,nosuid,nodev,size=256m,mode=1777
        --tmpfs=/run:rw,nosuid,nodev,noexec,size=32m
      )
      ;;
  esac

  podman create "${common[@]}" --entrypoint=/bin/sh "$image" -c 'exec sleep infinity' >/dev/null
  echo "Created $container (profile=$mode, volume=$volume)" >&2
else
  actual_profile=$(podman inspect --format '{{ index .Config.Labels "safecli.profile" }}' "$container")
  [[ "$actual_profile" == "$mode" ]] || {
    echo "ERROR: Existing container $container was not created in profile $mode." >&2
    exit 1
  }
  actual_net=$(podman inspect --format '{{ index .Config.Labels "safecli.network" }}' "$container")
  [[ "$actual_net" == "$net" ]] || {
    echo "ERROR: Existing container uses network=$actual_net, requested network=$net. Use a new name." >&2
    exit 1
  }
  if [[ "$mode" == usb && -n "${USB_DEVICE:-}" ]]; then
    expected=$(podman inspect --format '{{ index .Config.Labels "safecli.usb" }}' "$container")
    current=$(readlink -f -- "$USB_DEVICE")
    [[ "$current" == "$expected" ]] || {
      echo "ERROR: USB device changed: existing=$expected, requested=$current. Make a new container." >&2
      exit 1
    }
  fi
fi

state=$(podman inspect --format '{{.State.Running}}' "$container")
if [[ "$state" != true ]]; then
  podman start "$container" >/dev/null
fi

# Fish, npm, pip, Cargo and Go all require a writable /work. Probe an actual
# write as the container's unprivileged user; -w alone can miss MAC denials.
if ! podman exec "$container" /bin/sh -c \
  'probe=$(mktemp /work/.safecli-write-XXXXXXXX) && rm -f "$probe"'; then
  echo "ERROR: /work is not writable by the sandbox user in $container." >&2
  echo "To apply updated volume ownership, remove and recreate only the container; keep the named volume $volume." >&2
  echo "If the problem persists, inspect volume permissions and SELinux denials on the host." >&2
  exit 1
fi

if (( $# == 0 )); then
  set -- /usr/bin/fish
fi
exec_flags=(-i)
if [[ -t 0 && -t 1 ]]; then
  exec_flags+=(-t)
fi
podman exec "${exec_flags[@]}" "$container" "$@"
