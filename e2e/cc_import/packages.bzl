"""Import the existing Debian Zstd pair through the real BUILD generator."""

load("@rules_distroless//apt/private:deb_filemap.bzl", "deb_filemap")
load("@rules_distroless//apt/private:deb_import.bzl", "deb_import")

_RUNTIME = "trixie_libzstd1-amd64_1.5.7-dfsg-1"
_FILES = ["usr/lib/x86_64-linux-gnu/libzstd.so.1", "usr/lib/x86_64-linux-gnu/libzstd.so.1.5.7"]

def _urls(filename):
    path = "/pool/main/libz/libzstd/" + filename
    return [
        "https://deb.debian.org/debian" + path,
        "https://snapshot.debian.org/archive/debian/20260727T143429Z" + path,
    ]

def _packages_impl(_mctx):
    deb_filemap(name = _RUNTIME + "_filemap", files = json.encode(_FILES))
    deb_import(
        name = _RUNTIME,
        package_name = "libzstd1",
        target_name = _RUNTIME,
        sha256 = "2f6a2aeacfc925eba8b00ac9139bc4bfccf8cacb09eb93de067074b26948eef9",
        urls = _urls("libzstd1_1.5.7+dfsg-1_amd64.deb"),
    )
    deb_import(
        name = "zstd_dev",
        package_name = "libzstd-dev",
        target_name = "zstd_dev",
        depends_on = ["/trixie/libzstd1:amd64=1.5.7+dfsg-1"],
        dep_filemaps = ["@" + _RUNTIME + "_filemap//:filemap.json"],
        sha256 = "de5f8aabcf4cb5cd1b441495ea4c24838e88ecbb30ae22c032a1b3b68a9d6f1e",
        urls = _urls("libzstd-dev_1.5.7+dfsg-1_amd64.deb"),
    )

packages = module_extension(implementation = _packages_impl)
