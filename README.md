# gittools: manual mergify toolkit

Tools and instructions for bringing a long-lived fork (for example `qemu-cheri`) up to date with a
new upstream release by **mergifying**: replaying upstream's history into the fork one upstream
merge at a time, so conflicts are small and the fork's history still reads as a sequence of
"merged upstream X" commits rather than one giant merge.

| Tool | Where | Purpose |
|---|---|---|
| `git mergify-rebase` | [`external/git-mergify-rebase`](https://github.com/CTSRD-CHERI/git-mergify-rebase) (submodule) | Replay a whole run of upstream first-parent commits into the fork, one merge per commit, stopping at each conflict. |
| `git cherrypick-merge` | [`bin/git-cherrypick-merge`](bin/git-cherrypick-merge) | For one hard upstream merge: cherry-pick its individual commits one at a time, then fold them back into a single merge commit. |
| `git rebase-first-parent` | [`external/git-rebase-first-parent`](https://github.com/CTSRD-CHERI/git-rebase-first-parent) (submodule) | Rebase a branch that contains upstream merges, treating each merge relative to its first parent, so the merges are kept. |

## Documentation

- [docs/mergify-guide.md](docs/mergify-guide.md): step-by-step guide to updating a project
  (for example QEMU) to a new upstream version using all three tools.
- [docs/git-cherrypick-merge.md](docs/git-cherrypick-merge.md): reference for
  `git cherrypick-merge`.
- The submodules' own READMEs cover `git mergify-rebase` and `git rebase-first-parent`.
  The guide includes a command reference for both.

## Setup

```sh
git clone --recurse-submodules <this-repo-url> gittools
# or, in an existing clone:
git submodule update --init

# Put the tools on PATH (add this to your shell rc to make it permanent):
. /path/to/gittools/env.sh

git mergify-rebase 2>&1 | head -3   # sanity check
git cherrypick-merge help
git rebase-first-parent -h
```

`env.sh` adds `bin/` and both submodule directories to `PATH`. You need all of them: each tool
calls helper scripts (`git-mergify-rebase-sequence-editor`, `make-mergify-rebase`,
`git-rebase-first-parent-sequence-editor`, `make-rebase-first-parent`) by name.

To update the submodules to the latest upstream versions:

```sh
git submodule update --remote
git commit -am "Update mergify tool submodules"
```
