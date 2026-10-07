# Source this file to put the mergify tools on your PATH:
#
#   . /path/to/gittools/env.sh
#
# git finds `git-foo` executables on PATH and runs them as `git foo`, so after
# sourcing you can run `git mergify-rebase`, `git cherrypick-merge` and
# `git rebase-first-parent`. The helper scripts each tool calls internally
# (sequence editors, make-* todo generators) also need to be on PATH.

_gittools_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

if [ ! -e "$_gittools_dir/external/git-mergify-rebase/git-mergify-rebase" ]; then
    echo "gittools: submodules missing; run: git -C $_gittools_dir submodule update --init" >&2
fi

export PATH="$_gittools_dir/bin:$_gittools_dir/external/git-mergify-rebase:$_gittools_dir/external/git-rebase-first-parent:$PATH"
unset _gittools_dir
