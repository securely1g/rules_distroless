"""Import reviewed package selections using the existing Debian importer."""

load(":deb_filemap.bzl", "deb_filemap")
load(":deb_import.bzl", "deb_import")
load(":lockfile.bzl", "lockfile")
load(":package_set.bzl", "package_closure")
load(":translate_dependency_set.bzl", "translate_dependency_set")
load(":util.bzl", "util")

def import_locked_set(mctx, tag):
    """Declare package repositories directly from a canonical v2 lock."""
    content = mctx.read(tag.lock)
    locked = lockfile.from_json(mctx, content)
    dependency_set = tag.dependency_set or tag.name
    sets = locked.dependency_sets().get(dependency_set, {}).get("sets", {})
    if not sets:
        fail("APT lock has no dependency set " + dependency_set)
    packages = {}
    for architecture, roots in sets.items():
        if not roots:
            fail("APT lock dependency set is empty for " + architecture)
        packages.update(package_closure(
            locked.packages(),
            [key + "=" + version for key, version in roots.items()],
            architecture,
        ))

    # Isolate independently reviewed locks, including a resolver used to prepare
    # their next update. Consumers never need these implementation repo names.
    prefix = tag.name + "__"
    repositories = {}
    for key in packages:
        repository = prefix + util.sanitize(key)
        previous = repositories.setdefault(repository, key)
        if previous != key:
            fail("APT package repository name collision: " + previous + " and " + key)
        deb_filemap(name = repository + "_filemap", files = "[]")
    for key, package in packages.items():
        urls = package.get("urls") or [
            root.rstrip("/") + "/" + package["filename"]
            for root in locked.sources().get(package["suite"], {}).get("uris", [])
        ]
        if not urls:
            fail("APT lock has no download source for " + key)
        repository = prefix + util.sanitize(key)
        deb_import(
            name = repository,
            target_name = repository,
            package_name = package["name"],
            urls = urls,
            sha256 = package["sha256"],
            mergedusr = False,
            depends_on = package["depends_on"],
            dep_filemaps = ["@" + prefix + util.sanitize(dep) + "_filemap//:filemap.json" for dep in package["depends_on"]],
            repo_prefix = prefix,
        )
    translate_dependency_set(
        name = tag.name,
        depset_name = dependency_set,
        lock_content = content,
        repo_prefix = prefix,
    )
