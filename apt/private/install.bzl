"""Install Debian packages with the base filesystem's APT and dpkg."""

load("@tar.bzl//tar:tar.bzl", "tar_lib")

def _apt_install_impl(ctx):
    if "@sha256:" not in ctx.attr.execution_environment:
        fail("execution_environment must identify the Linux build container by image@sha256:digest")

    bsdtar = ctx.toolchains[tar_lib.toolchain_type]
    output = ctx.actions.declare_file(ctx.label.name + ".tar")
    receipt = ctx.actions.declare_file(ctx.label.name + ".json")
    configuration = ctx.actions.declare_file(ctx.label.name + ".inputs.json")
    ctx.actions.write(configuration, json.encode({
        "architecture": ctx.attr.architecture,
        "base": ctx.file.base.path,
        "bwrap": ctx.executable.bwrap.path,
        "execution_environment": ctx.attr.execution_environment,
        "guest_script": ctx.file._guest_script.path,
        "output": output.path,
        "packages": [package.path for package in ctx.files.packages],
        "packages_manifest": ctx.file.packages_manifest.path if ctx.file.packages_manifest else None,
        "receipt": receipt.path,
        "source_date_epoch": ctx.attr.source_date_epoch,
        "tar": bsdtar.tarinfo.binary.path,
    }))

    ctx.actions.run(
        executable = ctx.executable._installer,
        arguments = [configuration.path],
        inputs = depset(
            [ctx.file.base, ctx.file._guest_script, configuration] +
            ctx.files.packages + ctx.files.packages_manifest,
        ),
        tools = bsdtar.default.files.to_list() + [ctx.attr.bwrap[DefaultInfo].files_to_run],
        outputs = [output, receipt],
        mnemonic = "AptInstall",
        progress_message = "Installing Debian packages and running their configuration scripts for %{label}",
        # The optional installer needs real chown/mount semantics in its pinned
        # build container. bubblewrap provides the private filesystem, PID and
        # network namespaces; a nested Bazel sandbox cannot grant these rights.
        execution_requirements = {"no-sandbox": "1"},
    )
    return [
        DefaultInfo(files = depset([output])),
        OutputGroupInfo(receipt = depset([receipt])),
    ]

apt_install = rule(
    implementation = _apt_install_impl,
    doc = """Install existing DEBs into a private copy of a configured Debian root filesystem.

Unlike payload extraction, this runs APT/dpkg, package scripts and triggers.
The result is a complete filesystem TAR, not an incremental OCI layer. Use it
as the image's replacement filesystem, without the old base's layers.

Execution requires a dedicated, pinned Linux build container running as root
with the namespace/mount capabilities needed by bubblewrap. The declared
`bwrap` executable and the base's APT/dpkg must match the native architecture.
There is no rootless, emulated or host-package-manager fallback. See
`apt/INSTALL.md` for the execution contract and an example.
""",
    attrs = {
        "architecture": attr.string(mandatory = True, values = ["amd64", "arm64"]),
        "base": attr.label(allow_single_file = tar_lib.common.accepted_tar_extensions, mandatory = True, doc = "Complete configured rootfs TAR; OCI whiteouts must already have been applied."),
        "packages": attr.label_list(allow_files = [".deb"], mandatory = True, allow_empty = False, doc = "Original, integrity-checked DEB files. No DEBs are assembled by this rule."),
        "packages_manifest": attr.label(allow_single_file = [".json"], doc = "Optional JSON array selecting a subset of packages by their declared execroot-relative paths. Every selected file must also occur in packages."),
        "bwrap": attr.label(executable = True, cfg = "exec", mandatory = True, doc = "Declared bubblewrap executable for the native Linux execution platform."),
        "execution_environment": attr.string(mandatory = True, doc = "Pinned build-container image@sha256:digest. Part of the action key; the execution platform must enforce this identity."),
        "source_date_epoch": attr.int(default = 0, doc = "Fixed timestamp applied to filesystem entries and exposed to package scripts."),
        "_installer": attr.label(default = "//apt/private:installer", executable = True, cfg = "exec"),
        "_guest_script": attr.label(default = "//apt/private:install.sh", allow_single_file = True),
    },
    toolchains = [tar_lib.toolchain_type],
)
