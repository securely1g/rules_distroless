"""Compare actual flatten outputs with their original archive members."""

import sys
import tarfile


def members(path):
    result = []
    with tarfile.open(path, "r:*") as archive:
        for member in archive:
            # Deduplication normalizes the harmless leading ./ component.
            name = member.name.removeprefix("./")
            data = archive.extractfile(member).read() if member.isfile() else None
            result.append((name, member.type, member.mode, member.uid, member.gid,
                           member.uname, member.gname, member.mtime,
                           member.linkname.removeprefix("./"), data))
    return result


def main():
    first, second, default, full, ordered, subset, empty, dedup, compressed, empty_dedup = sys.argv[1:]
    a, b = members(first), members(second)
    assert {entry[1] for entry in a} == {tarfile.DIRTYPE, tarfile.REGTYPE, tarfile.LNKTYPE, tarfile.SYMTYPE}
    assert all(entry[3:7] == (123, 456, "fixture-user", "fixture-group") for entry in a + b)
    assert members(default) == a + b, "default flatten behavior changed"
    assert members(full) == a + b, "full manifest changed archive metadata or order"
    assert members(ordered) == b + a, "manifest order was ignored"
    assert members(subset) == b, "unselected archive content leaked"
    assert members(empty) == [], "empty manifest did not produce an empty tar"
    assert members(dedup) == b, "deduplication did not retain final archive entries"
    assert members(compressed) == b, "compressed selected output differs"
    assert members(empty_dedup) == [], "empty deduplicated selection failed"
    print("flatten action selection, ordering, empty output and archive metadata verified")


if __name__ == "__main__":
    main()
