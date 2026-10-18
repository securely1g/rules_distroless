"""Download checksum-pinned, existing packages for native installation tests."""

def _fixture_impl(ctx):
    architecture = {"amd64": "amd64", "x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(ctx.os.arch)
    if not architecture or ctx.os.name != "linux":
        fail("apt_install integration tests require a native Linux AMD64 or ARM64 host")
    inputs = json.decode(ctx.read(ctx.attr.lock))["architectures"][architecture]
    files = {"base.tar.gz": inputs["base"]}
    for name, package in inputs["packages"].items():
        files[name + ".deb"] = package
    for index, package in enumerate(inputs["transactions"]):
        files["hello-%s.deb" % index] = package
    for name, source in files.items():
        ctx.download(source["url"], name, sha256 = source["sha256"])
    ctx.file("BUILD.bazel", "# AUTO-GENERATED. DO NOT EDIT.\nexports_files(glob([\"*\"]))\n")
    ctx.file("architecture.bzl", "# AUTO-GENERATED. DO NOT EDIT.\nARCHITECTURE = %r\n" % architecture)

fixture_repository = repository_rule(
    implementation = _fixture_impl,
    attrs = {"lock": attr.label(allow_single_file = True, mandatory = True)},
)
