# Install packages with APT and dpkg

`apt_install` installs existing Debian archives into a private copy of a Debian
filesystem. APT chooses the installation order, and dpkg writes its own package
database, runs package scripts and processes triggers.

For example, installing `ca-certificates` creates `/etc/ca-certificates.conf`
and the certificate hash links by running its installation script. Installing
`vim-tiny` registers its editor alternatives. Copying package payloads and a
generated status file does not perform either operation.

This optional rule complements the existing extraction rules. It does not
create DEBs or bootstrap an empty Debian filesystem.

## Inputs and outputs

```starlark
load("@rules_distroless//apt:defs.bzl", "apt_install")

apt_install(
    name = "configured_filesystem",
    base = ":debian_rootfs",  # Complete configured rootfs TAR, including APT/dpkg.
    packages = [
        "@image_packages//ca-certificates:deb",
        "@image_packages//openssl:deb",
    ],
    architecture = "amd64",
    bwrap = ":pinned_bubblewrap",  # Declared native executable, not a host lookup.
    execution_environment = "registry.example/build@sha256:<64-hex-digit-digest>",
)

filegroup(
    name = "installation_receipt",
    srcs = [":configured_filesystem"],
    output_group = "receipt",
)
```

Supply every missing dependency as an original, integrity-checked DEB. The new
`:deb` package target exposes the original archive retained by `apt.install`'s
repository import; `:data` and `:control` keep their existing extraction behavior.
The package target's ordinary dependency closure still consists of payload
TARs, so select the required `:deb` targets explicitly.

An optional `packages_manifest` can select a subset of the declared archives.
Its format is a JSON array of their Bazel execution paths. For example, a
consumer's package-selection check can retain a base image's OpenSSL version and
select only the new program's DEB. The installer rejects undeclared paths and
duplicate entries. Selection policy belongs to the consumer; this rule performs
the selected installation and verifies each resulting package version.

The default output is `<name>.tar`: a **complete installed filesystem**. Use this
as the replacement filesystem when constructing an OCI image with `rules_oci`.
Do not append it to the old base's layers: a package upgrade can remove old
files, which would otherwise reappear from those layers. Preserve the desired
image configuration separately. Inputs must already have OCI whiteouts applied;
the installer rejects whiteout entries.

The `receipt` output group contains `<name>.json`, including input hashes, the
APT/dpkg versions, the resulting package inventory, and successful configuration,
trigger, dependency and audit checks. `requested_execution_environment` records
the caller's declared worker image; the build platform must enforce that image.

## Execution contract

Run this rule on a dedicated native Linux worker inside a build container pinned
by digest. The worker must run as root and permit bubblewrap to create mount,
PID, IPC, UTS and network namespaces. The native `amd64` and `arm64` paths are
supported; cross-architecture emulation is rejected.

For Docker-based CI, the integration tests use a pinned container with
`--cap-add SYS_ADMIN --cap-add NET_ADMIN`, the normal root-container capabilities,
and unconfined seccomp/AppArmor profiles where those profiles otherwise deny
namespace setup. Bubblewrap uses `NET_ADMIN` only to initialize the private
loopback device; package scripts receive neither added capability.
Mount only the build checkout and its declared caches into that worker. No
Docker socket is needed by the rule. An ordinary unprivileged Bazel sandbox
cannot provide the required installation semantics, so this action disables
that outer sandbox and creates its own private namespaces with bubblewrap.

The action exposes only its private root filesystem, read-only declared DEBs and
installation script, and an action-local result directory to package scripts.
It provides private `/proc`, `/dev` and `/tmp`, disables networking, clears
the inherited environment, and drops installation-unneeded capabilities before
executing the guest shell. There is no fallback to the host's package manager,
rootless ownership emulation or an ambient `bwrap` executable.

`/run` remains part of the private image filesystem. Files installed there,
including paths reached through `/var/run`, must survive in the output TAR.
Installer scratch files use private `/tmp` and are not included in the result.

The base supplies its pinned APT/dpkg and package-script tools. The `bwrap` input
and its runtime libraries must come from the declared execution platform. Put
the actual build-container digest in `execution_environment` so a platform
change changes the action key, and configure CI or remote execution to use that
same digest. Merely setting the attribute does not launch or attest a container.

## Installation behavior

- APT installs supplied local archives with repository sources, networking and
  recommended packages disabled. Missing dependencies or unexpected removals fail.
- Explicitly selected archives are reinstalled even when the base reports the
  same Debian version. This replaces a rebuilt library's old payload without
  requiring a packaging-version change; dependencies omitted by the selection
  manifest remain untouched.
- Package scripts and triggers run normally. A temporary `policy-rc.d` denies
  daemon startup during the image build; the original policy is restored.
- APT retains existing configuration files when dpkg needs a noninteractive
  conffile decision. Dependency checks and `dpkg --audit` must pass, every selected
  archive must have its exact version configured, and no pending trigger state
  may remain.
- Package-generated configuration, alternatives, users, ownership, permissions,
  file capabilities and caches remain in the result. BSD tar performs archive
  extraction and creation; no package database or TAR format is reimplemented.
- `source_date_epoch` fixes archive entry timestamps and is exposed to package
  scripts. Wall-clock package logs are removed. Arbitrary script-generated data
  can still vary; the rule does not promise byte-identical outputs for scripts
  that use randomness or other nondeterministic inputs.

See `e2e/apt_install` for initial-configuration checks and later APT install,
upgrade and removal tests against real Debian archives on both architectures.
