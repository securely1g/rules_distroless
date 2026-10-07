"""Public package metadata and files for one configured APT dependency set."""

load(":lockfile.bzl", "lockfile")

AptPackageSetInfo = provider(
    doc = "Resolved APT packages for one target architecture, ordered by package key.",
    fields = {
        "architecture": "Debian target architecture, for example amd64 or arm64.",
        "dependency_set": "Dependency set name in the lock.",
        "files": "Depset of the packages' data and control archive Files.",
        "lock": "File containing the canonical v2 package lock.",
        "packages": "List of structs with key, metadata (dict), data (File), and control (File).",
    },
)

def _sha256(value):
    return type(value) == "string" and len(value) == 64 and all([c in "0123456789abcdef" for c in value.elems()])

def package_closure(packages, roots, architecture):
    """Return a validated, sorted closure without resolving package versions.

    Architecture-independent packages may have a key for each target architecture.
    Their dependency edges must still stay within the requested architecture.
    Optional extracted-content hashes are retained verbatim in package metadata.
    """
    pending = list(roots)
    result = {}
    identities = {}
    for _ in range(len(packages) + 1):
        if not pending:
            break
        current = pending
        pending = []
        for key in current:
            if key in result:
                continue
            if key not in packages:
                fail("APT lock is missing dependency " + key)
            package = packages[key]
            (suite, name, arch, version) = lockfile.parse_package_key(key)
            if arch not in [architecture, "all"] or package.get("architecture") not in [architecture, "all"] or (arch == "all" and package.get("architecture") != "all"):
                fail("APT lock contains a foreign-architecture dependency: " + key)
            if (suite, name, version) != (package.get("suite"), package.get("name"), package.get("version")):
                fail("APT lock package key differs from its metadata: " + key)
            if not name or not all([c in "abcdefghijklmnopqrstuvwxyz0123456789+-." for c in name.elems()]):
                fail("APT lock has an invalid package name: " + key)
            filename = package.get("filename", "")
            if not filename or filename.startswith("/") or ".." in filename.split("/"):
                fail("APT lock has an invalid archive filename: " + key)
            if not _sha256(package.get("sha256")) or type(package.get("size")) != "int" or package["size"] <= 0:
                fail("APT lock is missing source integrity: " + key)
            dependencies = package.get("depends_on")
            if type(dependencies) != "list" or not all([type(dep) == "string" for dep in dependencies]):
                fail("APT lock has invalid dependencies: " + key)
            for kind in ["payload", "control"]:
                digest = kind + "_sha256"
                size = kind + "_size"
                if digest in package or size in package:
                    if not _sha256(package.get(digest)) or type(package.get(size)) != "int" or package[size] <= 0:
                        fail("APT lock has invalid extracted " + kind + " integrity: " + key)
            identity = [package.get(field) for field in ["version", "architecture", "sha256", "size", "payload_sha256", "payload_size", "control_sha256", "control_size"]]
            previous = identities.setdefault(name, identity)
            if previous != identity:
                fail("APT lock selects different versions or content for package " + name)
            result[key] = package
            pending.extend(dependencies)
    if pending:
        fail("APT lock dependency traversal did not converge")
    return {key: result[key] for key in sorted(result)}

def _single_files(targets):
    result = {}
    for target, key in targets.items():
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1 or key in result:
            fail("APT package archive must have one file and a unique key: " + str(target.label))
        result[key] = files[0]
    return result

def _apt_package_set_impl(ctx):
    data = _single_files(ctx.attr.data)
    control = _single_files(ctx.attr.control)
    if sorted(data) != sorted(control) or sorted(data) != sorted(ctx.attr.package_records):
        fail("APT package data, control, and metadata sets differ")
    packages = [
        struct(
            key = key,
            metadata = json.decode(ctx.attr.package_records[key]),
            data = data[key],
            control = control[key],
        )
        for key in sorted(data)
    ]
    return [
        DefaultInfo(files = depset(data.values())),
        AptPackageSetInfo(
            architecture = ctx.attr.architecture,
            dependency_set = ctx.attr.dependency_set,
            packages = packages,
            files = depset(data.values() + control.values()),
            lock = ctx.file.lock,
        ),
    ]

apt_package_set = rule(
    doc = "Expose a configured dependency set; normally generated by the apt extension.",
    implementation = _apt_package_set_impl,
    attrs = {
        "architecture": attr.string(mandatory = True),
        "control": attr.label_keyed_string_dict(allow_files = True),
        "data": attr.label_keyed_string_dict(allow_files = True),
        "dependency_set": attr.string(mandatory = True),
        "lock": attr.label(allow_single_file = [".json"], mandatory = True),
        "package_records": attr.string_dict(),
    },
)
