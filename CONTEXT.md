# Editor-to-pi Context

Editor context is sent to a selected pi session working on a checkout. The same checkout can be visible under different paths in Neovim and pi.

## Language

**Checkout**:
A particular working copy of a project, including an individual Git worktree. Different worktrees are different checkouts even when they belong to the same repository.

**Project root**:
The top-level directory of a checkout, distinct from a process's current working directory and from the Git metadata shared by multiple worktrees.
_Avoid_: Repository root when referring to a particular worktree

**Local root**:
The project root as seen by Neovim.

**Remote root**:
The project root as seen by the selected pi session. It can be identical to the local root.

**Target session**:
The particular pi session chosen to receive editor context. Its checkout determines which file references are meaningful.
