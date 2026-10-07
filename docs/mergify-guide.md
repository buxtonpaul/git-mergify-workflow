# Updating a fork to a new upstream version (mergify)

This guide shows how to bring a long-lived fork up to a new upstream release by hand, using
`git mergify-rebase`, `git cherrypick-merge` and `git rebase-first-parent`. The running example is
updating a CHERI QEMU fork branch `alliance-8.0` to upstream QEMU `v8.1.0`. The same steps apply to
any project whose upstream history is made of merge commits (pull requests merged into a mainline).

Set up the tools first; see the [README](../README.md).

## Why mergify instead of `git merge v8.1.0`?

A single `git merge v8.1.0` brings in thousands of upstream commits at once. Every conflict lands
in one huge resolution, and when something breaks later you can't tell which upstream change
caused it.

Upstream's mainline (`git log --first-parent v8.0.0..v8.1.0`) is a sequence of a few hundred
commits. Most of them are merges of a pull request. Mergify merges those **one at a time, in
order**, into the fork:

```
upstream:  o---M1---M2---M3---...---v8.1.0
                \    \    \
fork:   ...--F---X1---X2---X3---...---X(n)     Xi = merge of Mi, with Mi's message
```

Each step is a small merge, conflicts are local to one pull request, and the result has the same
history shape as a direct merge. `git log --first-parent` on the fork shows one entry per upstream
merge, and `git blame` and bisect still work across the update.

The three tools split the work:

- **`git mergify-rebase`** automates the run: it merges each upstream first-parent commit in turn
  and stops when one conflicts.
- **`git cherrypick-merge`** handles a merge whose conflict is too large to resolve in one go. It
  replays that pull request's individual commits one at a time, then rebuilds the merge commit.
- **`git rebase-first-parent`** moves or edits a branch that already contains these merges without
  flattening them. Plain `git rebase` would linearise the upstream commits.

## 0. Before you start

```sh
cd qemu-cheri
git fetch upstream --tags          # remote pointing at upstream QEMU
git status                         # must be clean
git config rerere.enabled true     # recommended: remembers resolutions across retries
```

**Work on a dedicated branch.** Keep the source branch untouched so you can always compare
against it or start over:

```sh
git checkout alliance-8.0
git checkout -b alliance-8.0_8.1   # work branch: all replay commits land here
```

Never run the replay on a detached `HEAD`. After `abort` and similar commands, confirm with
`git branch --show-current`.

**Record a baseline.** Build the fork and run its test suites before changing anything (for QEMU:
`ninja test` plus any target-specific suites). Write down the failures that already exist, so you
can tell later whether a failure is new. Keep a copy of the baseline binary outside the build
directory if you want to compare performance at the end.

## 1. Build the work list

List the upstream mainline commits still to merge, oldest first, into a checklist file **outside**
the repo:

```sh
git log --first-parent --reverse --oneline --decorate HEAD..v8.1.0 > ~/notes/mergify-8.1.md
```

(`git cherrypick-merge show-merge-commits v8.1.0` shows the same list newest first, for a quick
look.)

This file drives the whole run. You take every `mergify-rebase` and `cherrypick-merge` target from
it, tick entries off as they land, and write notes on any merge that needed real work. See
[Keep a checklist](#keep-a-checklist-of-first-parent-commits) and
[Write notes on problematic merges](#write-notes-on-problematic-merges).

`--decorate` shows the release-candidate tags (`v8.1.0-rc0` and so on) in the list. These make
natural checkpoints for a full build and test run.

## 2. Bulk replay with `git mergify-rebase`

Pick a target from your checklist, a few entries below the first unticked one, and pass its sha:

```sh
git mergify-rebase start 1c9a2b3
```

This starts an interactive rebase whose todo list is one `merge -C <M> <M>` step for every
upstream first-parent commit in `HEAD..<target>`, oldest first. Each step merges upstream commit
`M` into the current `HEAD` and reuses `M`'s commit message. Clean merges go through without
stopping. The rebase stops at the first conflict, or when it reaches the target.

**Work in small batches.** Because `mergify-rebase` keeps going until it either conflicts or
finishes, `git mergify-rebase start v8.1.0` can land dozens of untested merges in one go. Give it
a target a handful of commits ahead instead, so you can build and test between batches.
See [Work in small batches](#work-in-small-batches).

### At a conflict

```sh
git mergify-rebase show       # the upstream merge being replayed (git show MERGE_HEAD)
git mergify-rebase status     # which files conflict
```

Resolve the conflicts, then:

```sh
git mergify-rebase autoadd    # stage what's safe: git rm deleted-on-one-side files,
                              # git add merged files with no conflict markers left;
                              # warns about (and skips) files still containing markers
# fix the remaining files, git add them
# build (and run targeted tests) before continuing
git mergify-rebase continue   # commit with the upstream message, then rebase --continue
```

Build after every resolved conflict, **before** you continue. A build break that slips past is
much harder to attribute three merges later.

If the conflict is too big, or too tangled, to resolve as a single merge, don't force it. Go to
step 3.

### `git mergify-rebase` command reference

| Command | Effect |
|---|---|
| `start <commit>` | Replay every upstream first-parent commit in `HEAD..<commit>` as a merge, stopping at conflicts. |
| `show` | `git show MERGE_HEAD`: the upstream commit currently being merged. |
| `status` | `git status`. |
| `autoadd` | Stage mechanically resolvable files: `git rm` for `UD`/`DU`, `git add` for `AA`/`MM`/`UU` without conflict markers. |
| `commit` | Commit the in-progress merge with `MERGE_HEAD`'s message, without continuing. |
| `continue` | `commit` (if a merge is in progress), then `git rebase --continue`. |
| `skip` | Restore every conflicted or modified file to `HEAD` (drop upstream's side), commit and continue. Only use this when you have deliberately decided to drop that upstream change. |
| `stop` | Drop the remaining todo steps and finish the rebase now, keeping every merge done so far. |
| `abort` | `git rebase --abort`: discard **the whole run** since `start`. |

## 3. Hard merges: switch to `git cherrypick-merge`

When one upstream merge `M` conflicts too much, step out of the bulk replay **without losing the
merges already done**:

```sh
git reset --hard HEAD         # throw away the half-done merge of M only
git mergify-rebase stop       # end the rebase here; earlier merges are kept
git branch --show-current     # still on the work branch?
git log --first-parent -1     # HEAD = the last merge that landed, i.e. M^1 is merged
```

(Alternatively, `git mergify-rebase abort`, then `git mergify-rebase start <the commit before M>`
redoes the run up to just before `M`. With rerere enabled, earlier resolutions replay
automatically.)

Then replay `M`'s pull request commit by commit:

```sh
git cherrypick-merge start <M>
```

At each stop:

```sh
git cherrypick-merge show      # the single upstream commit that conflicts
git cherrypick-merge todo      # what's left in this pull request
# resolve, git add, build, run targeted tests
git cherry-pick --continue
```

When the sequence finishes (`todo` is empty), fold the picks back into one merge:

```sh
git cherrypick-merge apply
git log --graph --oneline -3             # HEAD: merge of M, with M's message
```

`apply` also folds in uncommitted changes to tracked files, such as a build fix made after the
last pick. It never adds untracked files, and it lists any it left out.

The result is identical in shape to what `git mergify-rebase` would have produced for `M`. Tick it
off and note in your checklist which sub-commits needed real fixes.

`M` must be a merge commit. Non-merge upstream commits are usually small, so resolve them inside
the mergify-rebase run. See [git-cherrypick-merge.md](git-cherrypick-merge.md) for the full
reference and troubleshooting.

## 4. Checkpoint, then continue

After each batch and each cherrypick-merge:

1. Build and run the tests. Compare the failures against the baseline from step 0, and fix any new
   failure before going further. Commit each fix as a separate commit on the work branch, with a
   message that names the upstream merge that caused it. At each release-candidate tag, run the
   full test suites rather than just the targeted tests.
2. Update the checklist: tick what landed and add notes for anything that needed work.
3. Tag the tested point so you can get back to it cheaply. Naming the tag after the last
   upstream commit merged works well: `git tag mergify-ok-1c9a2b3`.
4. Start the next batch, again taking the target sha from a few entries further down the
   checklist:

   ```sh
   git mergify-rebase start 7f0e4d5
   ```

   It always computes its todo from the current `HEAD`, so merges already done are not repeated.

Repeat steps 2–4 until `git log --first-parent HEAD..v8.1.0` is empty.

## 5. Fixing an earlier merge: `git rebase-first-parent`

Sometimes a problem turns out to be caused by a bad resolution several merges back, and you want
to fix it **in that merge** rather than with a later fix-up commit. A plain `git rebase -i` would
flatten every upstream commit into the fork. `git rebase-first-parent` rebases only the
first-parent chain and recreates each merge with its original other parents:

```sh
git rebase-first-parent -i <bad-merge>^
```

In the editor, each upstream merge appears as an `exec` line that recreates the merge (each is
preceded by a `# <subject>` comment), and each ordinary commit appears as a `pick`. Add a `break`
line right after the merge you want to fix, then save. When the rebase stops:

```sh
# fix the files
git add <files>
git commit --amend --no-edit
git rebase --continue
```

Later merges that touch the same lines may conflict as the rebase continues. Resolve them the
usual way, and with rerere enabled most will resolve themselves.

The same tool also moves the work branch when the **source branch has moved** during a long run
(someone landed a fix on `alliance-8.0` after you created `alliance-8.0_8.1`):

```sh
git rebase-first-parent alliance-8.0    # replay the work branch's first-parent chain
                                        # on top of the new alliance-8.0, keeping the merges
```

It accepts `-i` and `--onto <newbase>` with the same meaning as in `git rebase`. In practice it is
often simpler to merge the new source commits into the work branch at the end instead. Choose
based on whether you want a linear first-parent history.

## 6. Finishing

1. Every entry in the checklist is ticked, and `git log --first-parent --oneline HEAD..v8.1.0`
   prints nothing.
2. Clean full build. Test results match the baseline, minus any failures that the new upstream
   version was expected to fix.
3. Review the overall diff against upstream, which should be just the fork's own changes:

   ```sh
   git diff v8.1.0 HEAD --stat
   git diff alliance-8.0 HEAD --stat        # what the update changed in the fork
   ```

4. Create the final branch from the work branch, and leave the work branch as a record of the
   run:

   ```sh
   git checkout -b alliance-8.1
   ```

## Best practices

### Keep a checklist of first-parent commits

Generate the list of upstream first-parent commits once, at the start of the run (step 1). Mark
each entry as it lands, in whatever way suits you; a `[x]` prefix works well:

```
[x] 6a5e0a2 Merge tag 'pull-target-arm-20230608' of https://...
[x] 94d68c1 Merge tag 'pull-riscv-to-apply-20230612' of https://...   CONFLICT: see notes
    1c9a2b3 Merge tag 'pull-tcg-20230613' of https://...
    ...
    7f0e4d5 (tag: v8.1.0-rc0) Update version for v8.1.0-rc0
```

The first unmarked line is always the next thing to merge, and the shas are what you pass to
`git mergify-rebase start` and `git cherrypick-merge start`. You, or someone taking over, can pick
the run up after a break without reconstructing state from git.

The fork's copies of the merges get new shas, so check what has landed using the **upstream**
sha. It is an ancestor of `HEAD` once merged:

```sh
git merge-base --is-ancestor 94d68c1 HEAD && echo merged
git log --first-parent --oneline alliance-8.0..HEAD   # everything the run has added so far
```

Re-check the list against git whenever you come back to a run, rather than trusting it blindly.

### Write notes on problematic merges

Any merge that needed more than a trivial conflict resolution gets a note: in the checklist
itself, or in a separate log file that the checklist entry points to. Record:

- **What conflicted**: the files and functions, and what upstream was changing.
- **How you resolved it, and why**: which side you kept, what you adapted. In particular, record
  every upstream change you deliberately dropped (for example with `git mergify-rebase skip`).
- **For cherrypick-merges**: which sub-commits needed real fixes, not just the merge as a whole.
- **Follow-up**: build or test fixes committed afterwards, tests whose results changed, and
  anything left to do later.

These notes pay off several times over:
- A conflict or test failure many merges later is often a consequence of an earlier resolution,
  and the notes are how you find it.
- They are the basis for reviewing the run.
- The next mergify will likely hit the same areas.

### Work in small batches

`git mergify-rebase start <target>` runs until it either hits a conflict or reaches the target.
With a distant target, a long stretch of clean merges lands with no build or test in between. When
something then breaks, you can't tell which of the dozens of merges caused it. So:

- Give `start` a target **a handful of commits ahead** (5 or so) in your checklist, then build and
  test before the next batch.
- Use bigger batches for stretches that clearly don't touch the fork's changes (documentation,
  architectures the fork doesn't modify). Use smaller ones, down to a single merge, near the areas
  the fork changes heavily.
- Tag each batch that passes its tests (`git tag mergify-ok-...`). If a later batch goes badly, you
  can `git reset --hard` to the tag rather than starting the run over.
- If a regression does slip through several batches, bisect over the merges only:
  `git bisect start --first-parent <bad> <good>`.

### Other habits

- **Build after every conflict resolution**, before `continue`. Keep the targeted tests for the
  area you touched close at hand.
- **Commit build and test fixes as separate commits** right after the merge that needed them, with
  a message naming that merge. Alternatively, fold them into the merge with
  `git rebase-first-parent` (step 5). Pick one convention and stick to it for the whole run.
- **Stay on the work branch.** Check `git branch --show-current` after any `abort`, `stop` or
  `reset`. Commits made on a detached `HEAD` are easy to lose.
- **Enable rerere** (`git config rerere.enabled true`), so that retrying a merge after an
  `abort` or a `rebase-first-parent` replays the resolutions you've already made.
- **Keep notes and checklists outside the repo**, and stage resolved files by name rather than
  with `git add .`, so scratch files never end up in a commit.
- **Use `skip` sparingly**, and write down what you dropped when you do.

## Quick reference

```sh
. gittools/env.sh
git checkout -b <src>_<ver> <src>
git log --first-parent --reverse --oneline --decorate HEAD..<tag> > <checklist>

# bulk replay, a few checklist entries at a time
git mergify-rebase start <sha a few entries ahead>
  git mergify-rebase show / autoadd / continue           # at each conflict

# too hard? bail out of the bulk run, keep progress:
git reset --hard HEAD
git mergify-rebase stop
git cherrypick-merge start <M>
  git cherrypick-merge show / todo ; git cherry-pick --continue
git cherrypick-merge apply

# build + test, tick the checklist, tag, then the next batch

# fix an earlier merge in place
git rebase-first-parent -i <bad-merge>^
```
