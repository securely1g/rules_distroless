"""Run real APT/dpkg in an isolated filesystem and archive the installed result.

Archive extraction and creation use tar.bzl's declared BSD tar executable.
Package metadata and installation semantics belong entirely to APT/dpkg.
"""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile


MOUNTS = ("__rules_distroless_install", "__rules_distroless_install_result")
MACHINE_ARCHITECTURES = {"x86_64": "amd64", "aarch64": "arm64"}


def sha256(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def select_packages(declared, manifest):
    """Validate a generated selection without accepting undeclared inputs."""
    selected = json.loads(Path(manifest).read_text()) if manifest else declared
    if not isinstance(selected, list) or any(not isinstance(item, str) for item in selected):
        raise ValueError("packages_manifest must be a JSON array of declared DEB paths")
    if len(set(selected)) != len(selected):
        raise ValueError("packages_manifest contains duplicate DEB paths")
    unexpected = set(selected).difference(declared)
    if unexpected:
        raise ValueError("packages_manifest selects undeclared inputs: " + ", ".join(sorted(unexpected)))
    return selected


def package_inventory(path):
    """Read dpkg-query's public output, without rebuilding its database."""
    result = {}
    for line in Path(path).read_text().splitlines():
        name, version, architecture, status = line.split("\t")
        if status in ("config-files", "not-installed"):
            continue
        if status != "installed":
            raise ValueError(f"Package {name} was left {status}, not installed")
        result[name] = {"version": version, "architecture": architecture}
    return result


def run(command, **kwargs):
    subprocess.run([str(item) for item in command], check=True, **kwargs)


def filesystem_paths(root):
    """List entries without following image symlinks into the build machine."""
    paths = [root]
    for directory, directories, files in os.walk(root, followlinks=False):
        paths.extend(Path(directory) / name for name in directories + files)
    return sorted(paths, key=lambda path: str(path.relative_to(root)))


def install(configuration):
    if os.geteuid() != 0:
        raise RuntimeError("apt_install requires root inside a dedicated pinned Linux build container")
    native = MACHINE_ARCHITECTURES.get(platform.machine())
    if configuration["architecture"] != native:
        raise RuntimeError("apt_install requires native execution; foreign-architecture emulation is not supported")
    if configuration["source_date_epoch"] < 0:
        raise ValueError("source_date_epoch must be nonnegative")

    selected = select_packages(configuration["packages"], configuration["packages_manifest"])
    base = Path(configuration["base"]).absolute()
    output = Path(configuration["output"]).absolute()
    receipt = Path(configuration["receipt"]).absolute()
    bsdtar = Path(configuration["tar"]).absolute()
    bwrap = Path(configuration["bwrap"]).absolute()

    # Keep all writable state under a fresh action-owned directory. bubblewrap
    # exposes only this root, the read-only declared packages/script, and the
    # result directory. It never mounts Docker sockets or host filesystem trees.
    with tempfile.TemporaryDirectory(prefix="apt-install-", dir=output.parent) as temporary:
        temporary = Path(temporary)
        root = temporary / "root"
        inputs = temporary / "inputs"
        results = temporary / "results"
        for directory in (root, inputs, results):
            directory.mkdir()
        run([bsdtar, "--extract", "--preserve-permissions", "--numeric-owner", "--file", base, "--directory", root])
        for name in MOUNTS:
            if (root / name).exists() or (root / name).is_symlink():
                raise ValueError("Base uses reserved installation mount: /" + name)
        # This rule takes a materialized filesystem, never unapplied OCI layers.
        if any(path.name.startswith(".wh.") for path in filesystem_paths(root)):
            raise ValueError("base contains OCI whiteouts; materialize its filesystem before installation")

        shutil.copyfile(configuration["guest_script"], inputs / "install.sh")
        package_arguments = []
        input_packages = []
        for number, path in enumerate(selected):
            filename = f"{number:06d}.deb"
            shutil.copyfile(path, inputs / filename)
            package_arguments.append("/" + MOUNTS[0] + "/" + filename)
            input_packages.append({"path": path, "sha256": sha256(path)})

        command = [
            bwrap, "--die-with-parent", "--new-session",
            "--unshare-pid", "--unshare-net", "--unshare-ipc", "--unshare-uts",
            "--cap-drop", "ALL",
            "--cap-add", "CAP_CHOWN", "--cap-add", "CAP_DAC_OVERRIDE",
            "--cap-add", "CAP_FOWNER", "--cap-add", "CAP_FSETID",
            "--cap-add", "CAP_SETUID", "--cap-add", "CAP_SETGID",
            "--cap-add", "CAP_SETFCAP",
            "--bind", root, "/",
            # /run belongs to this private image root too. Do not mask it:
            # packages can install files through /var/run -> /run, and package
            # scripts can create persistent image contents there.
            "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
            "--ro-bind", inputs, "/" + MOUNTS[0],
            "--bind", results, "/" + MOUNTS[1],
            "--chdir", "/", "--clearenv",
            "--setenv", "PATH", "/usr/sbin:/usr/bin:/sbin:/bin",
            "--setenv", "HOME", "/root",
            "--setenv", "DEBIAN_FRONTEND", "noninteractive",
            "--setenv", "LC_ALL", "C",
            "--setenv", "TZ", "UTC",
            "--setenv", "SOURCE_DATE_EPOCH", str(configuration["source_date_epoch"]),
            "/bin/sh", "/" + MOUNTS[0] + "/install.sh", native,
            *package_arguments,
        ]
        run(command)
        inventory = package_inventory(results / "packages.tsv")
        for name in MOUNTS:
            (root / name).rmdir()

        entries = filesystem_paths(root)
        for path in entries:
            os.utime(path, (configuration["source_date_epoch"],) * 2, follow_symlinks=False)
        names = temporary / "entries.txt"
        names.write_bytes(b"\0".join(os.fsencode("./" + str(path.relative_to(root))) for path in entries) + b"\0")
        run([
            # Restricted PAX preserves extended metadata when needed without
            # including the build filesystem's volatile atime/ctime fields.
            bsdtar, "--create", "--format=paxr", "--numeric-owner", "--file", output,
            "--directory", root, "--no-recursion", "--null", "--files-from", names,
        ])
        receipt.write_text(json.dumps({
            "schema": 1,
            "operation": "apt_install",
            "status": "passed",
            "architecture": native,
            "requested_execution_environment": configuration["execution_environment"],
            "base_sha256": sha256(base),
            "input_packages": input_packages,
            "installed_packages": inventory,
            "installed_input_packages": package_inventory(results / "selected.tsv"),
            "dpkg_version": (results / "dpkg.txt").read_text().splitlines()[0],
            "apt_version": (results / "apt.txt").read_text().splitlines()[0],
            "initial_configuration": {
                "maintainer_scripts": "executed_by_dpkg",
                "triggers": "processed_by_dpkg",
                "dpkg_audit": "passed",
                "apt_get_check": "passed",
            },
            "rootfs_sha256": sha256(output),
        }, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    install(json.loads(Path(sys.argv[1]).read_text()))
