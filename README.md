# dotfiles

macOS dev environment focused on a GitHub-issue → git-worktree → Claude Code workflow.

## Demo

<video src="https://github.com/user-attachments/assets/3798331d-fe6b-4337-835e-aeacddb075d9" controls width="100%"></video>

## Commands

Custom shell functions live in `functions/`. `bootstrap.sh` symlinks the directory to `~/.zsh_functions/`, and `.zshrc` auto-sources every `*.zsh` file inside it.

### `ghsb` — issue + Herdr session + finish review pipeline (Architecture A)

Sandbox-oriented successor to the `ghwt` *session* layer. Ghostty stays your terminal; **Herdr** holds the agent session. Optional **Cloudflare Sandbox** provisions a remote preview/dev env. When work is done, `ghsb finish` runs the full review handoff.

```sh
ghsb [-c] [-f] [-b <branch>] [-i <N>] [--local|--cf] "Issue title"
ghsb finish [session-id]
ghsb review <pr-number>          # same as ghsbpr
ghsb status|attach|links|list|rm [session-id]
```

| Piece | Role |
| --- | --- |
| Ghostty | Terminal UI (unchanged) |
| Herdr | Persistent agent panes (cockpit) |
| Local worktree | Same `~/.claude/worktrees/{repo}-{N}` as `ghwt` |
| Cloudflare Sandbox (`--cf`) | Remote clone + dev server + preview URL |
| `ghsb finish` | PR → Playwright video (if UI) → pr-review → ranked files → links |

**Finish pipeline** (run after the agent pushes, or tell the agent to run it):

1. Push branch and ensure a PR exists  
2. Rank changed files for manual review (`~/.ghsb/artifacts/.../files-to-review.txt`)  
3. If user-facing paths changed and a preview/dev URL exists → Playwright walkthrough video  
4. Launch pr-review agent in Herdr (`/review-pr` or `/pr-review-toolkit:review-pr`)  
5. Print PR, github.dev, VS Code web, dev env, and PR preview links  

```sh
# Local Herdr session (default)
ghsb "Add dark mode"

# Also provision CF preview sandbox (needs deploy + env)
export GHSB_API_URL="https://ghsb-sandbox.<you>.workers.dev"
export GHSB_API_TOKEN="…"
ghsb --cf -i 42

ghsb finish          # from the worktree, or: ghsb finish myrepo-42
ghsb links
```

Cloudflare Worker lives in `sandbox/` — see `sandbox/README.md`. Session state: `~/.ghsb/sessions/`.

Agents use **permission-mode auto** (not always-approve).

Source: `functions/ghsb.zsh`, `functions/_ghsb_common.zsh`, `scripts/ghsb-record-preview.mjs`.

### `ghi` — issue + worktree in the current Herdr space

Same checkout as `ghsb` (issue → branch → worktree → setup), but stays in the space you already opened. Does not open Cursor and does not create a new Herdr workspace.

```sh
# Inside Herdr, in a new space:
ghi [-c] [-f] [-b <branch>] [-i <N>] [--no-agent] "Issue title"
```

| Flag | Description |
| --- | --- |
| `-c`, `--current` | Branch from the current branch (default: repo's default branch). |
| `-b <branch>` | Use an existing branch instead of creating one. |
| `-f`, `--fork` | Target the fork's own issue tracker instead of upstream (forks only). |
| `-i <N>` | Develop an existing issue instead of creating a new one. |
| `--no-agent` | Stop after the worktree (no agent). |

What it does:

1. Requires `HERDR_PANE_ID` — run it from inside Herdr, not a plain Ghostty window.
2. Creates or reuses the issue, branch, and worktree at `~/.claude/worktrees/{repo}-{N}` (same as `ghsb` / `ghwt`).
3. Runs `_worktree_setup`, `cd`s this shell into the worktree, and renames the current space to `{repo}-{N}`.
4. Starts grok/claude in this pane once the shell is idle. If this pane already has an agent, it splits a sibling pane in the same space instead.
5. Writes a `ghsb` session so `ghsb finish` still works when you are done.

Source: `functions/ghi.zsh`.

### `ghsbpr` / `ghsb review` — PR review in Herdr

Architecture A sibling of `ghwtpr`: checkout a PR, rank files for manual review, launch pr-review in **Herdr**, print links.

```sh
ghsbpr <pr-number>
ghsb review <pr-number>   # same
```

Source: `functions/ghsbpr.zsh`.

### `ghwt` — GitHub issue + worktree + Claude

Classic workflow. One command turns an idea into a checked-out worktree with an agent in tmux (or the current terminal).

```sh
ghwt [-c] [-f] [-b <branch>] [-i <number>] "Issue title"
```

| Flag | Description |
| --- | --- |
| `-c`, `--current` | Branch from the current branch (default: repo's default branch). |
| `-b <branch>` | Use an existing branch instead of creating one. |
| `-f`, `--fork` | Target the fork's own issue tracker instead of upstream (forks only). |
| `-i <number>` | Develop an existing issue instead of creating a new one. |

What it does:

1. Detects whether you're in a fork (compares `origin` URL with what `gh` resolves) and routes issue creation to the upstream repo if so. Pass `-f`/`--fork` to instead create/reuse issues on the fork itself; `-i <N>` then resolves against whichever target is in effect.
2. Fetches all remote refs.
3. Creates the issue (or reuses `-i <N>`) and creates the branch — via `gh issue develop` for direct repos, or manually for forks.
4. Creates a worktree at `~/.claude/worktrees/{repo}-{issue-number}`.
5. Runs `_worktree_setup` — executes `."setup-worktree"[]` from `.cursor/worktrees.json` if present, otherwise copies `.env.local`, `.dev.vars`, and `local.db` if they exist.
6. Calls `splt` (opens Cursor at the worktree, tiles left, shows the PICK ME banner), then launches `claude --permission-mode plan "Implement GitHub issue #N..."` in a new tmux window if `$TMUX` is set, otherwise in the current terminal.

Source: `functions/ghwt.zsh`.

### `ghwtrm` — remove a `ghwt` worktree

```sh
ghwtrm [<issue-number>]
```

Removes the worktree at `~/.claude/worktrees/{repo}-{N}` and prunes the branch metadata. With no argument it auto-detects the issue number by parsing the current working directory, so you can just run `ghwtrm` from inside the worktree you want to clean up.

Source: `functions/ghwtrm.zsh`.

### `ghwtb` — branch + worktree (no issue)

```sh
ghwtb [-c] [-b <branch>] [<branch-name-or-description>]
```

Same worktree + Cursor + Claude/Grok flow as `ghwt`, but skips GitHub issue creation. Creates a new branch (or reuses an existing one), checks it out at `~/.claude/worktrees/{repo}-{sanitised-branch}`, and launches the AI agent. Pass a description with spaces to auto-slugify the branch name (e.g. `"Add dark mode"` → `add-dark-mode`).

| Flag | Description |
| --- | --- |
| `-c`, `--current` | Branch from the current branch (default: repo's default branch). |
| `-b <branch>` | Use an explicit branch name; any remaining text is passed to the AI as context. |

Source: `functions/ghwtb.zsh`.

### `wt` — generic worktree for an existing branch

```sh
wt <branch-name>
```

Same worktree + Cursor + Claude flow as `ghwt`, but for a branch that isn't tied to a GitHub issue. Fetches the branch from `origin` if it isn't local, sanitises slashes and other shell-unfriendly characters, and creates a worktree at `~/.claude/worktrees/{repo}-{sanitised-branch}`.

Source: `functions/wt.zsh`.

### `ght` — open a Ghostty window in the current directory

```sh
ght [command...]
```

Opens a new Ghostty window in `$PWD`. If a command is supplied, it runs it after opening. Reuses a running Ghostty instance via osascript instead of launching a second app.

Source: `functions/ght.zsh`.

### `splt` — "PICK ME" attention banner

```sh
splt
```

Big yellow ASCII banner used by `ghwt` so it's obvious which terminal to look at while Cursor opens. Opens Cursor at the current directory (or a path you pass), then tiles that window to the left half of the screen. Press Enter to dismiss.

Source: `functions/splt.zsh`.

### Internal helpers

`functions/_worktree_setup.zsh` and `functions/_cursor_tile_left.zsh` are sourced by the commands above and aren't meant to be called directly.

## Installation

```sh
git clone https://github.com/tombeckenham/dotfiles.git ~/dotfiles
cd ~/dotfiles
./bootstrap.sh
```

Open a new terminal afterwards so the shell config loads.

Prerequisites: macOS, your admin password (the script calls `sudo pmset`), and a browser for the GitHub OAuth login that runs partway through.

`bootstrap.sh` is idempotent — re-run it any time you pull new changes.

## What `bootstrap.sh` does

1. Installs Xcode Command Line Tools and Homebrew if either is missing.
2. Runs `brew bundle` against `Brewfile` — installs starship, fnm, pnpm, pyenv, gh, jq, gnupg, lefthook, tmux, zoxide, pinentry-mac, doppler, plus the Ghostty, Cursor and OrbStack casks.
3. Clones [Antidote](https://github.com/mattmc3/antidote) (zsh plugin manager) into `~/.antidote`.
4. Symlinks `.zshrc`, `.zsh_plugins.txt`, `starship.toml`, `gpg.conf`, `gpg-agent.conf` and `functions/` into `$HOME` (and `~/.config`, `~/.gnupg`).
5. Authenticates `gh` with the `user` and `write:gpg_key` scopes (refreshes the token if those scopes aren't already granted).
6. Configures git globally: LFS filters, `commit.gpgsign=true`, `tag.gpgSign=true`, and `gh auth setup-git` for HTTPS token auth.
7. If git identity isn't set, prompts for name/email (auto-detected from existing config and the GitHub API), offers to generate an Ed25519 GPG signing key, and registers the key with GitHub via `gh gpg-key add`.
8. Installs Node LTS via `fnm`, Python 3.12 via `pyenv`, and Bun via the official installer.
9. `bun install -g vercel wrangler`, then installs the Claude Code, OpenCode, and Grok Build CLIs.
10. `pmset` for always-on server mode (`sleep 0`, `displaysleep 5`, `autorestart 1`).
11. `lefthook install` — wires up the pre-commit secret scanner from `lefthook.yml`.

## Shell config

- **`.zshrc`** — loads Antidote plugins, sets up the Starship prompt, initialises zoxide (`z`, `zi`), adds Bun / pnpm / fnm to `PATH`, lazy-loads pyenv on first `python`/`pip` use, and auto-sources every `*.zsh` file in `~/.zsh_functions/`.
- **`.zsh_plugins.txt`** — `zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-completions`, `zsh-history-substring-search`, plus the `git`, `node`, `npm` and `macos` ohmyzsh plugin paths.
- **`starship.toml`** — fast prompt: directory (truncated to repo root), git branch and status, command duration if it took longer than 2s. Language modules are disabled to keep prompt rendering quick.
- **`gpg.conf` / `gpg-agent.conf`** — `auto-key-retrieve`, `pinentry-mac`, 10-minute default cache (2-hour max).
- **`lefthook.yml`** — pre-commit hook that greps staged files for private keys, OpenAI keys (`sk-…`), GitHub tokens (`ghp_…`) and PEM headers, and blocks the commit if any are found.

## File layout

```
.
├── bootstrap.sh           # Installer (run once, safe to re-run)
├── Brewfile               # Homebrew packages
├── .zshrc                 # Shell config
├── .zsh_plugins.txt       # Antidote plugin list
├── starship.toml          # Prompt
├── gpg.conf               # GPG settings
├── gpg-agent.conf         # GPG agent
├── lefthook.yml           # Pre-commit hooks
├── scripts/
│   └── ghsb-record-preview.mjs   # Playwright PR preview video
├── sandbox/               # Cloudflare Sandbox Worker for ghsb --cf
└── functions/             # Custom zsh commands
    ├── ghsb.zsh
    ├── ghsbpr.zsh
    ├── ghi.zsh
    ├── _ghsb_common.zsh
    ├── ghwt.zsh
    ├── ghwtb.zsh
    ├── ghwtpr.zsh
    ├── ghwtrm.zsh
    ├── wt.zsh
    ├── ght.zsh
    ├── splt.zsh
    ├── _worktree_setup.zsh
    └── _cursor_tile_left.zsh
```

## Caveats / forking notes

- macOS only — uses `xcode-select`, `pmset`, `osascript`, `pinentry-mac` and `/opt/homebrew` paths.
- `bootstrap.sh` calls `sudo pmset` to keep the machine awake. Remove that block if you don't want always-on power management.
- `ghwt`, `ghwtb`, and `wt` assume Claude Code is installed and on `PATH` (`bootstrap.sh` installs it). Worktrees live under `~/.claude/worktrees/`.
- If you fork this repo, prune `Brewfile` and skip the steps in `bootstrap.sh` you don't want (Vercel, Wrangler, OpenCode, Grok, GPG key generation, etc.).
