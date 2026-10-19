---
name: ghis
description: Start an implement agent for open GitHub issues assigned to the user that have no linked pull request and whose Herdr workspace is not already open. Starts the lowest issue numbers first, five by default. Use when the user runs /ghis, or says "start all my issues", "issues without PRs", "ghi everything assigned to me".
compatibility: Requires Herdr pane (HERDR_PANE_ID), gh, git, and ~/.zsh_functions from tombeckenham/dotfiles.
---

# ghis

Fan-out of `ghi --no-focus -i N` for this repo.

## Invoke

If `HERDR_PANE_ID` is unset, stop and tell the user to run this from a Herdr pane (repo root of the repo to work in).

```bash
RUN="${CLAUDE_PLUGIN_ROOT:-$HOME/code/dotfiles/plugins/ghsb}/scripts/run"
zsh "$RUN" ghis [--dry-run] [--max N]
```

1. Dry-run first when more than a handful of issues would start: `ghis --dry-run`
2. Show them the start and skip lists
3. Run `ghis` (no flag) to start. Do not wrap it in a background shell. `ghi --no-focus` already starts each agent without stealing this pane.

Do not write your own `gh issue list` + loop of `ghi`. `ghis` skips issues linked to a pull request, issues with an empty body, and issues whose Herdr workspace is still open. It starts the lowest numbers first and stops after 5 unless `--max` says otherwise. Run it again for the next batch.

## After it runs

Print stdout. Name how many started vs skipped vs failed. Do not focus each issue space.
