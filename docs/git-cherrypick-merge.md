# git cherrypick-merge

`git cherrypick-merge` replays **one** upstream merge commit into your branch by cherry-picking
the commits it brought in one at a time, then folds the result back into a single merge commit
that looks like the original upstream merge.

Use it when a plain merge of that upstream commit (for example, a step of `git mergify-rebase`)
produces a conflict that is too big or tangled to resolve in one go. Because each cherry-pick
applies a single upstream commit, each conflict is small and you can see exactly which upstream
change caused it.

## Terminology

For an upstream merge commit `M`:

- `M^1` (first parent) is upstream's mainline before the merge.
- `M^2` (second parent) is the tip of the branch or pull request being merged.
- The **sub-commits** of `M` are the commits reachable from `M^2` that are not already in your
  branch. These are what the tool cherry-picks.

## Preconditions

- `M` must be a **merge commit**. The tool cherry-picks `cherry-pick-base..M^2`, so a non-merge
  commit (for example, upstream's direct "Update version to X" commits) won't work. Merge those
  with a normal `git merge`, or let `git mergify-rebase` do it.
- Your `HEAD` should already contain `M^1`, meaning every earlier upstream commit is merged.
  Otherwise the range `HEAD..M^2` pulls in unrelated older upstream commits as well. In a mergify
  run this holds automatically if you handle the upstream commits in order.
- The working tree must be clean, and the tags `cherry-pick-base` and `cherry-pick-target` must
  not exist. They mark an in-progress operation, and `start` refuses to run if either is present.
- Be on a branch, not a detached `HEAD`.

## Commands

| Command | Effect |
|---|---|
| `show-merge-commits <target>` | `git log --first-parent HEAD..<target>`: lists the upstream first-parent commits still to merge, oldest last. Use it to build your work list. |
| `start <merge-commit>` | Tags `HEAD` as `cherry-pick-base` and `<merge-commit>` as `cherry-pick-target`, then runs `git cherry-pick cherry-pick-base..cherry-pick-target^2`. Stops at the first conflict, like any `git cherry-pick`. |
| `show` | `git show CHERRY_PICK_HEAD`: the single upstream commit that is currently conflicting. |
| `todo` | Sub-commits not yet picked. |
| `complete` | Sub-commits already picked, including the current conflict. |
| `status` | `todo` + `complete` if an operation is in progress, otherwise `git status`. |
| `apply` | Folds the picked commits into one merge commit (see below) and deletes the tags. |
| `abort` | **Destructive.** `git reset --hard cherry-pick-base` and delete the tags. Discards every pick for this merge and any uncommitted changes. |
| `help` | Usage summary. |

There is no `continue` wrapper. Use plain git while the cherry-pick sequence is running:

```sh
git add <resolved files>
git cherry-pick --continue      # resolve, then carry on with the next sub-commit
git cherry-pick --skip          # drop the current sub-commit (e.g. it became empty)
```

## Workflow

```sh
git cherrypick-merge start <M>

# For each stop:
git cherrypick-merge show       # what is upstream trying to do?
git status                      # which files conflict?
# ...edit, build, test...
git add <files>
git cherry-pick --continue

# Repeat until the sequence finishes (`git status` shows no cherry-pick in progress,
# and `git cherrypick-merge todo` is empty).

git cherrypick-merge apply
git log --graph --oneline -5    # HEAD is now a merge of <M> with M's message and author
```

Build and run tests targeted at the affected area **after each resolved conflict**, before you
continue. This is the main advantage over resolving the whole merge in one go: a breakage can be
traced back to a single upstream commit.

### What `apply` does

1. Refuses to run while the cherry-pick sequence is still in progress.
2. `git add -u`: stages any changes to **tracked** files made since the last pick, for example a
   build fix, so they are folded into the merge. Untracked files are never added. To include a
   new file, `git add` it yourself before `apply`.
3. Builds the merge commit straight from the index (`git commit-tree`). Its parents are
   `cherry-pick-base` and `cherry-pick-target`, and it has the original upstream merge's message
   and author.
4. Moves `HEAD` to the new merge commit. The working tree is not touched.
5. Prints what it folded in and which untracked files it left out. It warns if the merge adds a
   gitlink (submodule entry) at a path `.gitmodules` doesn't declare.
6. Deletes the `cherry-pick-base` and `cherry-pick-target` tags.

The result is a merge commit whose second parent is the original upstream merge `M`, with the
same shape a successful `git merge M` would have produced. Anything you had already committed on
top of the picks before running `apply` is folded into the merge as well.

Check the "Folding uncommitted changes" and "Not included" lists that `apply` prints. If
something is missing or shouldn't be there, fix the files and run `git commit --amend --no-edit`.
Amending keeps both parents and the upstream message.

## Troubleshooting

- **"Error: Current head already tagged."**: a previous operation was not finished or aborted.
  If it was abandoned, delete the tags with `git tag -d cherry-pick-base cherry-pick-target`.
- **The sub-commits include a merge** (the pull request itself had merges): `git cherry-pick`
  stops with "is a merge but no -m option was given". Pick that merge by hand with
  `git cherry-pick -m 1 <sha>`, or skip it with `git cherry-pick --skip` if its content is
  already covered by the surrounding commits. Then `git cherry-pick --continue`.
- **"Your local changes ... would be overwritten" during `--continue`**: this is not a conflict.
  git aborted the next pick, and that sub-commit may be silently dropped from the sequence. Stop,
  commit or stash the stray change, and check that the sub-commit is present
  (`git cherrypick-merge complete` / `git log`) before you go on. Re-pick it by hand if it's
  missing.
- **Empty pick** ("The previous cherry-pick is now empty"): the change is already in your branch.
  Use `git cherry-pick --skip`.
- `git rerere` (`git config rerere.enabled true`) is worth enabling. If you abort and retry a
  merge, it replays resolutions you have already made.
