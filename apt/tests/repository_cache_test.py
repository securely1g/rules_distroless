"""Exercise APT contents-cache reuse and invalidation across fresh output bases."""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


OWNERS = {"fixture_map", "fixture_pkg", "fixture_hub"}


def archive(root, header):
    tree = root / "package"
    if tree.exists():
        shutil.rmtree(tree)
    (tree / "DEBIAN").mkdir(parents=True)
    (tree / "DEBIAN/control").write_text(
        "Package: fixture-dev\nVersion: 1\nArchitecture: all\n"
        "Maintainer: Fixture <fixture@example.invalid>\nDescription: cache fixture\n"
    )
    (tree / "usr/include").mkdir(parents=True)
    (tree / "usr/include" / header).write_text("#define FIXTURE 42\n")
    (tree / "usr/lib/pkgconfig").mkdir(parents=True)
    (tree / "usr/lib/pkgconfig/fixture.pc").write_text(
        "prefix=/usr\nincludedir=${prefix}/include\n"
        "Name: fixture\nDescription: fixture\nVersion: 1\nCflags: -I${includedir}\n"
    )
    output = root / "fixture.deb"
    subprocess.run(
        ["dpkg-deb", "--root-owner-group", "-Zxz", "--build", str(tree), str(output)],
        check=True, capture_output=True,
    )
    return output


def module(workspace, rules, package, header, registry):
    declaration = '''bazel_dep(name = "rules_distroless", version = "0.9.4.sonic.23")
bazel_dep(name = "bazel_skylib", version = "1.5.0")
bazel_dep(name = "rules_cc", version = "0.2.8")
bazel_dep(name = "platforms", version = "0.0.10")
'''
    if not registry:
        declaration += 'local_path_override(module_name = "rules_distroless", path = %s)\n' % json.dumps(str(rules))
    lock = {
        "version": 2, "sources": {}, "packages": {},
        "dependency_sets": {"fixture": {"sets": {"amd64": {}}}},
    }
    (workspace / "MODULE.bazel").write_text(
        'module(name = "apt_cache_fixture")\n' + declaration + '''
filemap = use_repo_rule("@rules_distroless//apt/private:deb_filemap.bzl", "deb_filemap")
package = use_repo_rule("@rules_distroless//apt/private:deb_import.bzl", "deb_import")
hub = use_repo_rule("@rules_distroless//apt/private:translate_dependency_set.bzl", "translate_dependency_set")
filemap(name = "fixture_map", files = %s)
package(
    name = "fixture_pkg", urls = [%s], sha256 = %s,
    package_name = "fixture-dev", target_name = "fixture-dev",
    dep_filemaps = ["@fixture_map//:filemap.json"],
)
hub(name = "fixture_hub", depset_name = "fixture", lock_content = %s)
''' % (
            json.dumps(json.dumps(["usr/include/" + header])),
            json.dumps(package.as_uri()), json.dumps(hashlib.sha256(package.read_bytes()).hexdigest()),
            json.dumps(json.dumps(lock)),
        )
    )


def run(root, workspace, name, registry):
    base = root / name
    profile = root / (name + ".json.gz")
    command = [
        "bazel", "--batch", "--nosystem_rc", "--nohome_rc",
        "--host_jvm_args=-Xmx1024m", "--output_base=" + str(base),
        "query", "--repo_contents_cache=" + str(root / "contents"),
        "--profile=" + str(profile), "--record_full_profiler_data",
        "--experimental_profile_additional_tasks=starlark_repository_fn",
    ]
    if registry:
        command.extend(["--registry=" + registry.as_uri(), "--registry=https://bcr.bazel.build"])
    mirrors = os.environ.get("APT_CACHE_TEST_DOWNLOADER_CONFIG")
    if mirrors:
        command.append("--experimental_downloader_config=" + mirrors)
    command.append("set(@fixture_map//:filemap.json @fixture_pkg//:BUILD.bazel @fixture_hub//:BUILD.bazel)")
    log = root / (name + ".log")
    with log.open("w") as stream:
        result = subprocess.run(
            command, cwd=workspace, env=dict(os.environ, USE_BAZEL_VERSION="8.5.1"),
            stdout=stream, stderr=subprocess.STDOUT,
        )
    if result.returncode:
        raise RuntimeError("Bazel failed; see %s\n%s" % (log, log.read_text()[-6000:]))
    with gzip.open(profile, "rt") as stream:
        events = json.load(stream)["traceEvents"]
    executed = {
        event["name"].rsplit("+", 1)[-1]
        for event in events
        if event.get("cat") == "Starlark repository function call"
    } & OWNERS
    generated = next((base / "external").glob("*fixture_pkg/BUILD.bazel")).read_text()
    locations = {
        owner: next((base / "external").glob("*" + owner + "/BUILD.bazel")).parent.resolve()
        for owner in OWNERS
    }
    assert all(path.is_relative_to(root / "contents") for path in locations.values()), locations
    return executed, generated, locations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path)
    args = parser.parse_args()
    registry = args.registry.resolve() if args.registry else None
    rules = Path(__file__).resolve().parents[2]
    root = Path(tempfile.mkdtemp(prefix="apt-contents-cache-"))
    print("Evidence:", root, flush=True)
    workspace = root / "consumer"
    workspace.mkdir()
    (workspace / "BUILD.bazel").write_text("")
    package = archive(root, "fixture.h")
    module(workspace, rules, package, "fixture.h", registry)
    cold, first, locations = run(root, workspace, "cold", registry)
    assert {"fixture_pkg", "fixture_map"} <= cold, ("cold rules", cold)
    # Remove the old output base so absolute links or old local state cannot
    # accidentally make the fresh-output-base cache check pass.
    shutil.rmtree(root / "cold")
    warm, second, reused = run(root, workspace, "warm", registry)
    assert not warm, ("rules executed instead of using the contents cache", warm)
    assert locations == reused, "a repository was regenerated into a new contents-cache entry"
    assert first == second, "prepared-cache reuse changed generated BUILD contents"
    assert "fixture.h" in second
    package = archive(root, "changed.h")
    module(workspace, rules, package, "changed.h", registry)
    invalidated, third, updated = run(root, workspace, "invalidated", registry)
    assert {"fixture_map", "fixture_pkg"} <= invalidated, ("inputs did not invalidate", invalidated)
    assert "changed.h" in third and "usr/include/fixture.h" not in third
    assert locations["fixture_pkg"] != updated["fixture_pkg"]
    print("PASS: cold execution, fresh-output-base cache reuse, relocation, and input invalidation", flush=True)


if __name__ == "__main__":
    main()
