#!/bin/sh
# Run only inside the private root filesystem created by install.py.
set -eu

result=/__rules_distroless_install_result
expected_architecture=$1
shift

test "$(id -u)" = 0
actual_architecture=$(dpkg --print-architecture)
if test "$actual_architecture" != "$expected_architecture"; then
    echo "Expected native $expected_architecture rootfs, found $actual_architecture" >&2
    exit 1
fi

# Debian's documented container policy prevents starting daemons while their
# packages are configured. Preserve the image's original policy exactly.
policy=/usr/sbin/policy-rc.d
scratch=/tmp/rules-distroless-install
mkdir -p /usr/sbin "$scratch"
if test -e "$policy" || test -L "$policy"; then
    cp -a "$policy" "$scratch/policy-rc.d"
fi
restore_policy() {
    rm -f "$policy"
    if test -e "$scratch/policy-rc.d" || test -L "$scratch/policy-rc.d"; then
        cp -a "$scratch/policy-rc.d" "$policy"
    fi
}
trap restore_policy EXIT
rm -f "$policy"
printf '#!/bin/sh\nexit 101\n' > "$policy"
chmod 755 "$policy"

# Only the declared local files are available. Empty repository sources and the
# private network namespace prevent downloads. Do not use --no-download here:
# APT also needs its local-file acquisition step to stage the supplied archives.
mkdir -p "$scratch/sources.list.d"
: > "$scratch/sources.list"
if test "$#" -gt 0; then
    # A rebuilt input can retain its Debian version. Always install explicitly
    # selected archives; a matching version in the base is not proof that its
    # payload matches these declared bytes.
    apt-get --yes --reinstall --no-install-recommends --no-remove \
        -o Dir::Etc::sourcelist="$scratch/sources.list" \
        -o Dir::Etc::sourceparts="$scratch/sources.list.d" \
        -o APT::Get::List-Cleanup=0 \
        -o Dpkg::Use-Pty=0 \
        -o Dpkg::Options::=--force-confold \
        install "$@"
fi
dpkg --configure --pending
dpkg --triggers-only --pending
apt-get -o Dir::Etc::sourcelist="$scratch/sources.list" \
    -o Dir::Etc::sourceparts="$scratch/sources.list.d" check

# A successful APT invocation must have installed each selected archive's
# exact version and architecture; a different already-installed package does
# not satisfy this output contract.
: > "$result/selected.tsv"
for archive in "$@"; do
    package=$(dpkg-deb --field "$archive" Package)
    version=$(dpkg-deb --field "$archive" Version)
    architecture=$(dpkg-deb --field "$archive" Architecture)
    query="$package:$architecture"
    if test "$architecture" = all; then
        query=$package
    fi
    installed=$(dpkg-query --show --showformat='${Version}|${Architecture}|${Status}' "$query")
    if test "$installed" != "$version|$architecture|install ok installed"; then
        echo "Requested $query=$version, found $installed" >&2
        exit 1
    fi
    printf '%s\t%s\t%s\tinstalled\n' "$query" "$version" "$architecture" >> "$result/selected.tsv"
done

dpkg --audit > "$result/audit.txt"
if test -s "$result/audit.txt"; then
    cat "$result/audit.txt" >&2
    exit 1
fi
if test -s /var/lib/dpkg/triggers/Unincorp; then
    echo 'dpkg left unincorporated triggers' >&2
    exit 1
fi
dpkg-query --show --showformat='${binary:Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n' > "$result/packages.tsv"
dpkg --version > "$result/dpkg.txt"
apt-get --version > "$result/apt.txt"

# Build-time package logs contain wall-clock timestamps. Package state,
# configuration, alternatives and generated caches remain in the image.
rm -f /var/log/dpkg.log /var/log/apt/history.log /var/log/apt/term.log
