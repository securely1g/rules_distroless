# Public C++ import compatibility

Run `USE_BAZEL_VERSION=8.5.1 bazel test //:import_test` from this directory.
The fixture imports existing, checksum-pinned Debian Zstd runtime and SDK
packages through the real BUILD generator. It compiles against the declared
public `<zstd.h>` header, calls the installed library and compares its loaded
bytes with the declared runtime file. It creates no Debian packages.

The consuming root selects rules_cc 0.2.22. Its private Starlark cc_import
expects a C++ runtime toolchain supplied only by newer Bazel releases;
the public cc_import interface chooses the implementation supported by Bazel.
The regression therefore fails during analysis if the generator returns to
the private load, before the actual native test can run. The enclosing public `cc_library` forwards the package include roots, which
Bazel normalizes relative to the package repository. This preserves ordinary
`#include <zstd.h>` on Bazel 7/8 as well as newer rules_cc releases. Per-library
link flags, dependencies and library selections remain unchanged.
