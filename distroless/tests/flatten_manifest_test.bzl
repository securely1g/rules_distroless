"""Action tests for execution-time archive selection."""

load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("//distroless:defs.bzl", "flatten")

def flatten_manifest_tests():
    """Exercise real flatten actions with metadata-rich tar fixtures."""
    for name in ["first", "second"]:
        native.genrule(
            name = "flatten_manifest_" + name,
            outs = ["manifest_" + name + ".tar"],
            cmd = """set -euo pipefail
tmpdir=$$(mktemp -d)
trap 'rm -rf "$$tmpdir"' EXIT
mkdir -p "$$tmpdir/payload"
printf '%s' '%s' > "$$tmpdir/payload/shared"
chmod 0750 "$$tmpdir/payload"
chmod 0640 "$$tmpdir/payload/shared"
ln "$$tmpdir/payload/shared" "$$tmpdir/payload/hard"
ln -s shared "$$tmpdir/payload/link"
"$(BSDTAR_BIN)" --create --format gnutar --file "$@" \
  --uid 123 --gid 456 --uname fixture-user --gname fixture-group \
  --no-recursion -C "$$tmpdir" payload payload/shared payload/hard payload/link
""" % ("%s", name),
            toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
            testonly = True,
        )

    candidates = [":flatten_manifest_first", ":flatten_manifest_second"]
    selections = {
        "full": candidates,
        "ordered": list(reversed(candidates)),
        "subset": candidates[1:],
        "empty": [],
        "deduplicated": candidates,
        "compressed": candidates[1:],
        "empty_deduplicated": [],
    }
    for name, selected in selections.items():
        manifest = "flatten_manifest_" + name + "_inputs"
        native.genrule(
            name = manifest,
            srcs = candidates,
            outs = [manifest + ".txt"],
            cmd = ("printf '%s\\n' " + " ".join(["'$(execpath %s)'" % label for label in selected]) + " > $@") if selected else ": > $@",
            testonly = True,
        )
        flatten(
            name = "flatten_manifest_" + name + "_output",
            tars = candidates,
            tar_manifest = ":" + manifest,
            deduplicate = name in ["deduplicated", "empty_deduplicated"],
            testonly = True,
            **({"compress": "gzip"} if name == "compressed" else {})
        )

    flatten(
        name = "flatten_manifest_default_output",
        tars = candidates,
        testonly = True,
    )

    # These intentional action failures are invoked explicitly by native CI.
    # Keep them out of wildcard builds and ordinary positive test dependencies.
    for name, contents in {
        "unknown": "undeclared.tar",
        "duplicate": "$(execpath :flatten_manifest_first)\\n$(execpath :flatten_manifest_first)",
        "blank": "\\n",
    }.items():
        native.genrule(
            name = "flatten_manifest_" + name + "_inputs",
            srcs = candidates,
            outs = ["manifest_" + name + ".txt"],
            cmd = "printf '%b' '" + contents + "' > $@",
            testonly = True,
        )
        flatten(
            name = "flatten_manifest_" + name,
            tars = candidates,
            tar_manifest = ":flatten_manifest_" + name + "_inputs",
            tags = ["manual"],
            testonly = True,
        )

    outputs = [":flatten_manifest_" + name + "_output" for name in ["default"] + list(selections)]
    sh_test(
        name = "flatten_manifest_test",
        srcs = ["flatten_manifest_test.sh"],
        args = ["$(rootpath :flatten_manifest_test.py)"] + [
            "$(rootpath %s)" % label
            for label in candidates + outputs
        ],
        data = candidates + outputs + ["flatten_manifest_test.py"],
    )
