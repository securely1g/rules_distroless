# smoke test

This e2e exercises the repo from an end-users perpective.
It catches mistakes in our install instructions, or usages that fail when called from an "external" repository to rules_distroless.
It is also used by the presubmit check for the Bazel Central Registry.

The Google Cloud CLI input is pinned to the version recorded in
`bullseye.lock.json`, because the Cloud SDK APT repository is a rolling source.
Update that version and the package lock together. Debian inputs remain on their
existing dated snapshots. The lock also records each package's download URLs so
resolving the smoke workspace does not rewrite tracked provenance.

CI starts without a generated `MODULE.bazel.lock`, retains it as an artifact,
and checks that resolution and tests leave tracked files unchanged.
