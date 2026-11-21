# safecli — openSUSE Tumbleweed edition

Run unfamiliar CLI tools in **rootless Podman** with three isolation profiles. This is a direct openSUSE Tumbleweed port of [podman-safecli](https://github.com/rhgKc2yp/podman-safecli). All images use the [official openSUSE Tumbleweed image](https://hub.docker.com/r/opensuse/tumbleweed) (`docker.io/opensuse/tumbleweed:latest`), include the same multi-language CLI toolchain, and enable container networking by default.

| Profile | Isolation and tools | Memory | PIDs |
| --- | --- | ---: | ---: |
| `strict` | Read-only root filesystem, general-purpose CLI toolchain, no host-directory mounts | 1.5 GiB | 192 |
| `usb` | As above, plus one explicitly allowed USB/serial device | 1.5 GiB | 192 |
| `nested` | Bubblewrap support; seccomp unconfined **only** for this profile | 3 GiB | 384 |

All profiles use `pasta` networking, `--cap-drop=ALL`, `no-new-privileges`, private namespaces, a 2-CPU limit and a persistent named `/work` volume. No host home directory, SSH agent, display or Podman socket is shared. Use `NETWORK=none` to disable networking when creating a container. Networking permits outbound traffic (including reachable LAN hosts): this is **not** a guarantee that untrusted programs are safe. USB access and the relaxed nested profile increase risk.

## Preinstalled CLI software

All three images install the same focused toolchain from [scripts/install-cli-toolchain.sh](scripts/install-cli-toolchain.sh). It covers the core Node.js, Python, Rust and Go CLI workflows without bundling unrelated runtimes. Compiler packages still increase image size and the number of components to monitor for vulnerabilities.

| Area | Packages / available commands |
| --- | --- |
| Shells / editor | `bash`, `nano`; fish (default interactive shell): **4.9.3 or newer** from `shells:fish` OBS on amd64, stock Tumbleweed fish on arm64 |
| Download, source, TLS | `curl`, `wget`, `ca-certificates`, `openssl`, `git`, `openssh-clients` |
| UNIX, archives, text | `coreutils`, `findutils`, `diffutils`, `grep`, `sed`, `gawk`, `which`, `file`, `less`, `procps-ng`, `util-linux`, `tar`, `gzip`, `bzip2`, `xz`, `zstd`, `zip`, `unzip`, `patch`, `jq`, `ripgrep` |
| Node.js / TypeScript | openSUSE `nodejs26`, `npm26`, `nodejs26-devel`, `corepack24` (`corepack`, `pnpm`, `yarn` shims); **Node.js 26** and its distro-packaged **npm 11.x** (`npm`/`npx`) |
| Python | `python3`, `python3-pip`, `python3-devel`, `python3-virtualenv`, `python3-pipx`, `python3-uv`; a `python` → `python3` symlink if missing; also `python -m venv` |
| Rust / Go | `rust`, `cargo`, `go` (`go`, `gofmt`) |
| Native builds | `gcc`, `gcc-c++`, `make`, `cmake`, `pkgconf-pkg-config`, `libopenssl-devel`, `libffi-devel`, `zlib-devel` |

The `usb` profile additionally has `usbutils`, `libusb-1_0-0`, `libusb-1_0-devel`; the `nested` profile additionally has `bubblewrap` (the shared list already includes `util-linux`). During uncached builds, `zypper refresh` and `zypper dup --no-recommends` move the base to the latest tested Tumbleweed snapshot, then install exactly the selected packages without recommendations. Node.js 26, npm 11 and Corepack come from the **standard Tumbleweed repositories**, with no Fedora RPMs or language-registry install scripts. Tumbleweed is a rolling release: the complete `dup` is its primary update mechanism, and `zypper patch-check` is not a reliable vulnerability gate for its snapshot-based updates. Trivy provides the release-blocking OS vulnerability scan. Corepack can download the project-selected pnpm/Yarn version at **runtime**.

**Fish repository by architecture:** On `linux/amd64` (RPM `x86_64`), the installer runs `zypper addrepo https://download.opensuse.org/repositories/shells:fish/openSUSE_Tumbleweed/shells:fish.repo`, refreshes repository metadata, and installs `fish` from the newer `shells:fish` OBS source via Zypper. The repository remains configured so future `zypper dup` operations update fish normally. Builds reject an x86_64 fish version older than 4.9.3. On `linux/arm64` (RPM `aarch64`), that OBS repository currently has no matching RPM, so the installer does **not** add it and uses Tumbleweed's stock fish instead. This preserves the original two-architecture build matrix without installing binaries for the wrong architecture. On x86_64 the first noninteractive refresh auto-imports the OBS signing key; Zypper then verifies repository and RPM signatures. This is trust in the repository-provided key, not a fingerprint pin, so review the OBS repository and its signing-key changes before relying on published images.

The launcher opens **fish by default** when no command is provided (`/bin/sh` remains available explicitly). The image also sets `SHELL=/usr/bin/fish` and uses fish as its default image command. All package-manager user installs belong under the **persistent, writable `/work` named volume**, since the system directories are read-only in `strict` and `usb`. The launcher sets `HOME=/work`, `XDG_CONFIG_HOME=/work/.config`, and `XDG_DATA_HOME=/work/.local/share` so fish history and configuration are stored on that volume:

| Ecosystem | Persistent location | How to install |
| --- | --- | --- |
| npm global tools | `/work/.npm-global` (`NPM_CONFIG_PREFIX`) | `npm install -g <package>` |
| Python packages | `/work/venv` (create once after container startup) | `/work/venv/bin/pip install <package>` |
| Cargo tools | `/work/.cargo` (`CARGO_HOME`) | `cargo install <package>` |
| Go tools | `/work/go` (`GOPATH`, `GOBIN=/work/go/bin`) | `go install example.com/tool@latest` |

The image adds `/work/.npm-global/bin`, `/work/.cargo/bin` and `/work/go/bin` to `PATH`. It also retains `/work/.local/bin` for `pipx`, `uv` and npm tools installed with the old prefix. System directories precede these user-writable directories in `PATH`, so user-installed commands do not accidentally override core system commands. You do **not** need to run `npm config set prefix` or export paths in fish; the image configures them already.

Create the Python virtual environment **after** the `/work` volume is mounted, not while building the image, because the mount hides image-layer files at `/work`. For example:

```sh
./safecli.sh strict python-demo python3 -m venv /work/venv
./safecli.sh strict python-demo /work/venv/bin/pip install some-package
./safecli.sh strict shell-demo                   # opens fish
./safecli.sh strict shell-demo nano /work/note.txt
./safecli.sh strict js-demo npm config get prefix  # /work/.npm-global
./safecli.sh strict js-demo node --version
./safecli.sh strict rust-demo cargo --version
./safecli.sh strict go-demo go version
```

Python's system environment is distribution-managed: install Python dependencies into the `/work/venv` environment, through `pipx`, or with `uv`, instead of `pip install` into system Python. You can activate the venv in fish with `source /work/venv/bin/activate.fish`, or call its binaries directly. Recreate a persisted venv if a later image changes the major/minor Python version. In `strict`/`usb`, the root filesystem is read-only and `/tmp` is `noexec`; tools that need executable temporary files can use a writable directory under `/work` (for example `mkdir -p /work/tmp` then `set -gx TMPDIR /work/tmp` in fish). Only `/work` persists. Other runtimes (Ruby, PHP, Lua, Java, .NET, Dart, etc.) are deliberately omitted; install them in a separate image when a project needs one. Builds may exhaust the default memory/PID limits, especially for large Rust/Go projects.

## Requirements and usage

Linux, rootless Podman, working cgroup v2/user namespaces and `pasta` (typically the `passt` package) are required. Run as a regular user, **not `sudo`**. USB mode also needs `crun` and host device permissions.

Build locally (fresh Tumbleweed snapshot and RPM updates). The launcher uses these images when a matching GHCR image is not present; set `IMAGE_PREFIX=localhost/safecli` to explicitly select your local build when both are available:

```sh
podman build --pull=always --no-cache -f Containerfile.strict -t localhost/safecli-strict:latest .
podman build --pull=always --no-cache -f Containerfile.usb -t localhost/safecli-usb:latest .
podman build --pull=always --no-cache -f Containerfile.nested -t localhost/safecli-nested:latest .
chmod +x safecli.sh
./safecli.sh strict trial  # opens fish
podman cp ./unknown-cli safecli-strict-trial:/work/unknown-cli
./safecli.sh strict trial /work/unknown-cli --help
```

For published GHCR images, **publish this fork under your own GitHub repository first**. The launcher has an example GHCR prefix (`ghcr.io/owner/podman-safecli-tumbleweed`); replace `owner` with your GitHub namespace using `IMAGE_PREFIX` (or edit the default once). The launcher automatically picks the downloaded image for the selected profile:

```sh
podman pull ghcr.io/your-github-user/podman-safecli-tumbleweed-strict:latest
IMAGE_PREFIX=ghcr.io/your-github-user/podman-safecli-tumbleweed ./safecli.sh strict trial
```

For the other profiles, pull the corresponding `-usb:latest` or `-nested:latest` image first. The preference is **configured GHCR image if present, otherwise a local `localhost/safecli` build**. Explicit `IMAGE` or `IMAGE_PREFIX` overrides this selection. Images are never pulled automatically by the launcher. Do not use the original Fedora repository's GHCR images for this variant.

Other profile examples:

```sh
USB_DEVICE=/dev/bus/usb/001/005 ./safecli.sh usb device-test
./safecli.sh nested nested-test bwrap --help
NETWORK=none ./safecli.sh strict offline-test
```

`usb` allows only specified USB/serial/hidraw character devices; SELinux may still restrict device access. Nested user namespaces depend on host kernel/LSM settings and may not work on every host. For exact image selection, use `IMAGE='ghcr.io/your-github-user/podman-safecli-tumbleweed-strict@sha256:REPLACE_WITH_64_HEX_DIGEST'`; `IMAGE_TAG` and `IMAGE_PREFIX` are alternatives. The launcher uses `--pull=never`: pull the image explicitly before creating a sandbox.

Containers and their `/work` volumes persist. The launcher uses Podman's `:U` mount option to correct ownership of the **dedicated named volume** for the container's unprivileged UID/GID, and checks that `/work` can actually be written before running a CLI. `:U` recursively changes file ownership within that Podman-managed volume at container creation, so reopening a large existing volume can be slow; it does **not** bind-mount your host home directory. If fish reports `Permission denied` for `/work/.config` or `/work/.local/share`, exit fish, then remove and recreate **only the container** with this updated launcher. Preserve the named volume. Since unknown CLI tools can read `/work`, do not store secrets or sensitive shell commands there.

To apply a new image, **recreate the container**; restarting it is not enough. Do not delete the named volume unless you want to delete its data:

```sh
podman stop safecli-strict-trial
podman rm safecli-strict-trial
podman pull ghcr.io/your-github-user/podman-safecli-tumbleweed-strict:latest
IMAGE_PREFIX=ghcr.io/your-github-user/podman-safecli-tumbleweed ./safecli.sh strict trial
# optional cleanup of data, irreversible: podman volume rm safecli-vol-strict-trial
```

Creation-time settings, including networking and USB device selection, cannot be changed by simply rerunning the launcher against an existing container.

## GHCR publishing and supply-chain security

Commit this project (including `.github/`) to a GitHub repository with default branch `main`. The [workflow](.github/workflows/publish-ghcr.yml) publishes three separate multi-platform images (`linux/amd64`, `linux/arm64`) on pushes to `main`, `v*` tags, manual runs, and **approximately every three days** (04:23 UTC on days 1, 4, 7, ...; not exactly every 72 hours). Pull requests run script and workflow validation; [PR image build](.github/workflows/pr-build.yml) also builds the `strict` image for `linux/amd64` when build-related files change, without publishing it. Set the GHCR package visibility to **Public** if anonymous pulls are desired; existing packages may need Actions write permission. Publishing uses `GITHUB_TOKEN`, with no PAT or long-lived signing key.

Each publication follows this sequence:

1. Fetch `opensuse/tumbleweed:latest`; on amd64 add the `shells:fish` OBS repo, while arm64 keeps the stock repositories. Run `zypper refresh` and `zypper dup --no-recommends`, install the RPM toolchain, then clean package metadata. Repository refresh, distribution upgrade, and package installation failures block the build on either architecture. Both architectures build **without layer cache**. Buildx attaches architecture-aware OCI SBOM metadata.
2. Push a **uniquely named candidate** image; Trivy scans **both** architectures, and blocks normal tag promotion for **fixable HIGH or CRITICAL** vulnerabilities or scan errors. Scan JSON reports are saved as Actions artifacts. Candidates may remain in GHCR even if rejected; they are **not** release-approved. Trivy supports Tumbleweed OS advisories, but the combination of `zypper dup` and Trivy is **not a full CVE inventory**: vulnerabilities without a published fix or advisory can still be missed.
3. Generate full downloadable SPDX JSON SBOMs for amd64 and arm64, without trimming packages or file information. GitHub's standard `sbom-path` attestation has a 16 MiB input limit, so the workflow instead attests the **full SBOM files themselves** as provenance subjects and publishes a small, custom SHA-256 digest-manifest attestation bound to the multi-arch OCI image digest in GitHub and GHCR. This is **not** a native SPDX SBOM predicate. Buildx also attaches its SBOM metadata to the image digest.
4. **Cosign keyless-sign** the digest using GitHub OIDC and verify the expected workflow identity. Only after all checks pass, advance `:latest` (on `main`), a unique `:build-<run_id>-<attempt>` tag, or `:vX.Y.Z` (on a release-tag run). The Actions summary records each digest.

`latest` and version tags are **not immutable** in GHCR. For repeatable use, pin `@sha256:<digest>` and verify the signed identity and provenance. A candidate tag is publicly pullable if the package is public, but never selected by `latest` if checks fail. Existing containers do **not** update on a registry push.

**CI tool updates:** [Dependabot](.github/dependabot.yml) checks GitHub Actions dependencies weekly, including the SHA-pinned `zizmor` action. ShellCheck is supplied by the GitHub-hosted runner image. The [weekly CI tool check](.github/workflows/check-ci-tools.yml) separately checks the pinned Trivy and actionlint executable versions against their latest stable GitHub releases; it opens or updates an issue when a newer version is available, then closes the issue once the pin catches up. It does not automatically change workflow files. Maintainers must review releases and update pins before merging.

**GHCR retention:** [GHCR cleanup](.github/workflows/prune-ghcr.yml) runs daily at 09:47 UTC and removes image/package versions older than **seven days** across the `strict`, `usb` and `nested` packages. It preserves the version carrying `latest` and all versions younger than seven days; if `latest` is missing, ambiguous, or at least seven days old, it skips that package to protect the last known good image. Up to 50 older versions per package are removed per run. **This also deletes old `v*`, `build-*` and `candidate-*` tags, untagged versions, and their associated registry data; references to old digests and their GHCR-hosted signatures/attestations may stop working.** GitHub Actions artifacts retain their independent 30-day period. Manual *Actions → Prune old GHCR image versions → Run workflow* runs in dry-run mode by default; uncheck **dry_run** to delete. The workflow requires `packages:write` and repository admin access to each GHCR package. Monitor its logs for permission or cleanup failures.

Verify a released image (adjust repository and digest; use the tag reference in `cosign verify` only if it resolves to the expected digest):

```sh
IMAGE='ghcr.io/owner/repo-strict@sha256:REPLACE_WITH_64_HEX_DIGEST'
cosign verify "$IMAGE" \
  --certificate-identity 'https://github.com/owner/repo/.github/workflows/publish-ghcr.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
gh attestation verify "oci://$IMAGE" -R owner/repo
```

For an image published from a `v*` tag, replace `@refs/heads/main` in the Cosign certificate identity with `@refs/tags/vX.Y.Z`. The full SPDX SBOMs, SHA-256 digest manifest and Trivy reports are available in the workflow run's artifacts (30-day retention); Buildx SBOM metadata and signed attestations are attached to the image digest. Verify the custom SBOM digest predicate using `gh attestation verify "oci://$IMAGE" -R owner/repo --predicate-type "https://github.com/owner/repo/attestations/sbom-digests/v1"` and compare its hashes with the downloaded full SBOM files. File-subject provenance attestations can be separately verified by file path. GitHub Artifact Attestations require a public repository on most non-Enterprise plans; for eligible private repositories, the plan must support private attestations.

**Security-update caveats:** `opensuse/tumbleweed:latest` follows a tested *rolling* Tumbleweed snapshot, so package transitions can break builds. GitHub schedules can be delayed or disabled after prolonged inactivity. A failed build or scan leaves the previous `latest` image intact, **which may still have vulnerabilities**. Monitor Actions failures and security advisories, and roll forward image digests on each Podman host. See [SECURITY.md](SECURITY.md).

## License

The project's scripts, Containerfiles, CI, tests and documentation use the **MIT License** ([LICENSE](LICENSE)). openSUSE and all bundled RPM packages retain their **own upstream licenses**; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The project MIT license does not relicense any upstream software.
