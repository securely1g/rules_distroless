"""Checked closure and real existing-package import tests; no package production."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//apt:defs.bzl", "AptPackageSetInfo")
load("//apt/private:package_set.bzl", "package_closure")

def _package(name, architecture = "amd64", version = "1", dependencies = []):
    return {
        "name": name,
        "version": version,
        "architecture": architecture,
        "suite": "test",
        "filename": "pool/" + name + ".deb",
        "sha256": "a" * 64,
        "size": 1,
        "depends_on": dependencies,
        "payload_sha256": "b" * 64,
        "payload_size": 2,
        "control_sha256": "c" * 64,
        "control_size": 3,
    }

def _closure_test_impl(ctx):
    env = unittest.begin(ctx)
    for architecture in ["amd64", "arm64"]:
        root = "/test/root:" + architecture + "=1"
        dependency = "/test/dependency:" + architecture + "=1"
        packages = {
            root: _package("root", "all", dependencies = [dependency]),
            dependency: _package("dependency", architecture, dependencies = [root]),
        }
        result = package_closure(packages, [root], architecture)
        asserts.equals(env, sorted([root, dependency]), result.keys())
        asserts.equals(env, packages, result)
        asserts.equals(env, "b" * 64, result[root]["payload_sha256"])
    return unittest.end(env)

_closure_test = unittest.make(_closure_test_impl)

def _invalid_closure_impl(ctx):
    root = "/test/root:amd64=1"
    packages = {root: _package("root")}
    if ctx.attr.case == "foreign_dependency":
        dependency = "/test/dependency:arm64=1"
        packages[root]["depends_on"] = [dependency]
        packages[dependency] = _package("dependency", "arm64")
    elif ctx.attr.case == "foreign_all_key":
        root = "/test/root:arm64=1"
        packages = {root: _package("root", "all")}
    elif ctx.attr.case == "native_package_all_key":
        root = "/test/root:all=1"
        packages = {root: _package("root", "amd64")}
    elif ctx.attr.case == "missing_dependency":
        packages[root]["depends_on"] = ["/test/missing:amd64=1"]
    elif ctx.attr.case == "conflicting_version":
        dependency = "/test/root:amd64=2"
        packages[root]["depends_on"] = [dependency]
        packages[dependency] = _package("root", version = "2")
    elif ctx.attr.case == "missing_source_hash":
        packages[root].pop("sha256")
    elif ctx.attr.case == "partial_content_hash":
        packages[root].pop("control_size")
    elif ctx.attr.case == "metadata_mismatch":
        packages[root]["version"] = "2"
    package_closure(packages, [root], "amd64")
    return []

_invalid_closure = rule(implementation = _invalid_closure_impl, attrs = {"case": attr.string()})

def _failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_failure_test = analysistest.make(_failure_test_impl, expect_failure = True, attrs = {"message": attr.string()})

def _locked_import_test_impl(ctx):
    info = ctx.attr.package_set[AptPackageSetInfo]
    expected_key = "/trixie/media-types:" + info.architecture + "=13.0.0"
    if info.architecture not in ["amd64", "arm64"] or [package.key for package in info.packages] != [expected_key]:
        fail("Imported package set differs from the native checked lock")
    if info.dependency_set != "locked_test" or len(info.files.to_list()) != 2:
        fail("Imported package-set metadata or archive files differ")
    coreutils = ctx.toolchains["@bazel_lib//lib:coreutils_toolchain_type"]
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    commands = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "cd \"${TEST_SRCDIR}/${TEST_WORKSPACE}\"",
        "coreutils=" + repr(coreutils.coreutils_info.bin.short_path),
        "hash() { local value; value=$(\"$coreutils\" sha256sum \"$1\"); printf '%s' \"${value%% *}\"; }",
        "test \"$(hash " + repr(info.lock.short_path) + ")\" = \"$(hash " + repr(ctx.file.checked_lock.short_path) + ")\"",
    ]
    for package in info.packages:
        if package.metadata["architecture"] != "all":
            fail("Architecture-independent package metadata was changed")
        for kind, file in [("payload", package.data), ("control", package.control)]:
            commands.append("test \"$(hash " + repr(file.short_path) + ")\" = " + repr(package.metadata[kind + "_sha256"]))
            commands.append("test \"$(\"$coreutils\" wc -c < " + repr(file.short_path) + ")\" = " + str(package.metadata[kind + "_size"]))
    ctx.actions.write(script, "\n".join(commands) + "\n", is_executable = True)
    runfiles = ctx.runfiles(files = [info.lock, ctx.file.checked_lock], transitive_files = info.files)
    runfiles = runfiles.merge(coreutils.default.default_runfiles)
    runfiles = runfiles.merge(ctx.runfiles(transitive_files = coreutils.default.files))
    return [DefaultInfo(executable = script, runfiles = runfiles)]

locked_import_test = rule(
    implementation = _locked_import_test_impl,
    test = True,
    attrs = {
        "package_set": attr.label(providers = [AptPackageSetInfo], mandatory = True),
        "checked_lock": attr.label(allow_single_file = True, mandatory = True),
    },
    toolchains = ["@bazel_lib//lib:coreutils_toolchain_type"],
)

def locked_package_set_tests():
    _closure_test(name = "locked_closure_test")
    tests = [":locked_closure_test"]
    cases = {
        "foreign_dependency": "foreign-architecture dependency",
        "foreign_all_key": "foreign-architecture dependency",
        "native_package_all_key": "foreign-architecture dependency",
        "missing_dependency": "missing dependency",
        "conflicting_version": "different versions or content",
        "missing_source_hash": "missing source integrity",
        "partial_content_hash": "invalid extracted control integrity",
        "metadata_mismatch": "key differs from its metadata",
    }
    for case, message in cases.items():
        _invalid_closure(name = "invalid_" + case, case = case, tags = ["manual"])
        _failure_test(name = case + "_test", target_under_test = ":invalid_" + case, message = message)
        tests.append(":" + case + "_test")
    native.test_suite(name = "locked_package_set_tests", tests = tests)
