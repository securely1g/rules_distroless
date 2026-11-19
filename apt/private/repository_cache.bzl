"""Compatibility with Bazel's cross-workspace repository contents cache."""

def reproducible_repository(ctx):
    """Mark a repository reproducible when the running Bazel supports it."""
    if hasattr(ctx, "repo_metadata"):
        return ctx.repo_metadata(reproducible = True)
    return None
