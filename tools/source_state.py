#!/usr/bin/env python3
"""Source label for a build: the commit an artifact can be rebuilt from.

Usage: tools/source_state.py <repo> [--allow-dirty]

Prints the full commit SHA when the checkout (and its submodules) has no
modified, staged or unignored untracked files: exactly the tree the build
scripts stage. Otherwise the staged sources are not recoverable from any
commit, so:

  * without --allow-dirty it lists the changes on stderr and exits 1
    (release builds);
  * with --allow-dirty it prints "<sha>-dirty", which tools/verify-release.py
    refuses as a release source (test builds only).

Exit codes: 0 label printed, 1 dirty and not allowed, 2 not a git checkout.
"""
import subprocess
import sys

DIRTY_SUFFIX = "-dirty"


def source_label(repo, allow_dirty):
    """Returns (label, changes). label is None when the tree is dirty and that
    is not allowed."""
    git = ["git", "-C", repo]
    commit = subprocess.run(git + ["rev-parse", "HEAD"], check=True,
                            capture_output=True, text=True).stdout.strip()
    # --ignore-submodules=none: a modified submodule is staged too.
    changes = subprocess.run(
        git + ["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"],
        check=True, capture_output=True, text=True).stdout.splitlines()
    if not changes:
        return commit, []
    return (commit + DIRTY_SUFFIX if allow_dirty else None), changes


def main(argv):
    args = [a for a in argv if a != "--allow-dirty"]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        label, changes = source_label(args[0], "--allow-dirty" in argv)
    except subprocess.CalledProcessError as e:
        print(f"not a git checkout: {args[0]}: {e.stderr.strip()}", file=sys.stderr)
        return 2
    if label is None:
        print("the source tree has uncommitted changes; a release must be built from a "
              "commit (commit or remove them):", file=sys.stderr)
        for line in changes[:50]:
            print(f"  {line}", file=sys.stderr)
        if len(changes) > 50:
            print(f"  ... and {len(changes) - 50} more", file=sys.stderr)
        return 1
    if changes:
        print(f"warning: {len(changes)} uncommitted change(s); artifact labeled {label}, "
              "not usable as a release", file=sys.stderr)
    print(label)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
