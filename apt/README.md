# Checked APT packages

Use `apt.install` and dated package sources when preparing a dependency update.
The generated `@<dependency_set>//:lock.json` contains the resolved v2 lock.
It currently includes every set resolved by that extension, not only the named
hub. Review and check in the required sets, their complete dependency closure,
source URLs, versions and SHA256 hashes. Keep the canonical package lock even
when generated Bazel module-resolution metadata is ignored.

Ordinary builds can import the reviewed selection without resolving indices:

```starlark
apt = use_extension("@rules_distroless//apt:extensions.bzl", "apt")
apt.from_lock(
    name = "runtime_packages",
    lock = "//packages:apt.lock.json",
    dependency_set = "runtime",  # Defaults to name when omitted.
)
use_repo(apt, "runtime_packages")
```

The lock must be a source file exported by its Bazel package. `from_lock` does
not fetch package indices or consult cached resolution facts. It downloads the
existing Debian archives using their checked hashes and reuses the normal
Distroless data/control extraction. No package is compiled or repackaged as a
DEB. Sources declared for separate `apt.install` calls can still resolve; omit
those calls and sources from a workspace that must only use checked imports.
Keep dependency-update resolution separate from ordinary builds.

Each hub exports the original `:lock.json` and `:package_set`. Load
`AptPackageSetInfo` from `@rules_distroless//apt:defs.bzl` in consuming rules:

| Field | Meaning |
| --- | --- |
| `architecture` | Debian architecture selected by the target platform. |
| `dependency_set` | Set name within the lock. |
| `packages` | Complete closure, sorted by key; structs contain `key`, `metadata`, `data` and `control`. |
| `files` | Depset of every data/control archive File in the closure. |
| `lock` | File containing the canonical lock, byte-identical to a `from_lock` input. |

The target's `DefaultInfo` contains only data archives. `data` and `control`
struct fields are Files; `metadata` is the corresponding lock package dict.
Consumers should use these files rather than reconstruct generated repository
names. The imported set rejects missing dependency edges, mismatched metadata,
foreign architecture keys and conflicting versions/content for one package.
An `Architecture: all` package may have separate keys for each target
architecture, so its dependencies remain correctly scoped.

V2 package entries may additionally contain `payload_sha256`/`payload_size`
and `control_sha256`/`control_size`. Each pair is optional and is preserved by
the provider. These describe the transformed data archive and extracted control
archive, respectively. A consuming verification action must compare them with
the actual files when it requires checked extracted content; the provider does
not execute hashing. Keep them in the same canonical lock rather than copying
source package metadata into a second lock schema.

Locked imports contain the package data/control needed for image assembly.
They do not fetch the optional repository Contents indices used to infer
cross-package C/C++ header and symlink providers. Continue using the resolver's
development-package support when those inferred compilation interfaces are
required.

Selection based on an image's installed packages happens during action
execution. A selection action can consume the package-set provider, inspect its
base image and policy inputs, and emit an ordered archive manifest for
`flatten(tars = ["@runtime_packages//:package_set"], tar_manifest = ... )`.
The selected paths must be declared data archives. Keep image-specific retained
package policy and runtime compatibility validation with the image owner.

Validation targets `//apt/tests:locked_package_set_tests` and
`//apt/tests:locked_import_test` exercise invalid closures and import an existing
pinned Debian package on native AMD64 and ARM64. They do not produce DEBs.
