# dotfiles

macOS dev environment focused on a GitHub-issue → git-worktree → Claude Code workflow.

## Demo

<video src="https://github.com/user-attachments/assets/3798331d-fe6b-4337-835e-aeacddb075d9" controls width="100%"></video>

## Commands

Custom shell functions live in `functions/`. `bootstrap.sh` symlinks the directory to `~/.zsh_functions/`, and `.zshrc` auto-sources every `*.zsh` file inside it.

### `ghwt` — GitHub issue + worktree + Claude

The main workflow. One command turns an idea into a checked-out worktree with Claude already running in plan mode against the issue.

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
5. Runs `_worktree_setup` — executes `."setup-worktree"[]` from `.cursor/worktrees.json` if present, otherwise copies `.env.local` and `local.db` if they exist.
6. Opens a new Cursor window, calls `splt` to draw attention while Cursor loads, then launches `claude --permission-mode plan "Implement GitHub issue #N..."` in a new tmux window if `$TMUX` is set, otherwise in the current terminal.

Source: `functions/ghwt.zsh`.

### `ghwtrm` — remove a `ghwt` worktree

```sh
ghwtrm [<issue-number>]
```

Removes the worktree at `~/.claude/worktrees/{repo}-{N}` and prunes the branch metadata. With no argument it auto-detects the issue number by parsing the current working directory, so you can just run `ghwtrm` from inside the worktree you want to clean up.

Source: `functions/ghwtrm.zsh`.

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

Big yellow ASCII banner used by `ghwt` so it's obvious which terminal to look at while Cursor opens. Also tiles Cursor to the left half of the screen. Press Enter to dismiss.

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
2. Runs `brew bundle` against `Brewfile` — installs starship, fnm, pnpm, pyenv, gh, jq, gnupg, lefthook, tmux, pinentry-mac, doppler, plus the Ghostty, Cursor and OrbStack casks.
3. Clones [Antidote](https://github.com/mattmc3/antidote) (zsh plugin manager) into `~/.antidote`.
4. Symlinks `.zshrc`, `.zsh_plugins.txt`, `starship.toml`, `gpg.conf`, `gpg-agent.conf` and `functions/` into `$HOME` (and `~/.config`, `~/.gnupg`).
5. Authenticates `gh` with the `user` and `write:gpg_key` scopes (refreshes the token if those scopes aren't already granted).
6. Configures git globally: LFS filters, `commit.gpgsign=true`, `tag.gpgSign=true`, and `gh auth setup-git` for HTTPS token auth.
7. If git identity isn't set, prompts for name/email (auto-detected from existing config and the GitHub API), offers to generate an Ed25519 GPG signing key, and registers the key with GitHub via `gh gpg-key add`.
8. Installs Node LTS via `fnm`, Python 3.12 via `pyenv`, and Bun via the official installer.
9. `bun install -g vercel wrangler`, then installs the Claude Code and OpenCode CLIs.
10. `pmset` for always-on server mode (`sleep 0`, `displaysleep 5`, `autorestart 1`).
11. `lefthook install` — wires up the pre-commit secret scanner from `lefthook.yml`.

## Shell config

- **`.zshrc`** — loads Antidote plugins, sets up the Starship prompt, adds Bun / pnpm / fnm to `PATH`, lazy-loads pyenv on first `python`/`pip` use, and auto-sources every `*.zsh` file in `~/.zsh_functions/`.
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
└── functions/             # Custom zsh commands
    ├── ghwt.zsh
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
- `ghwt` and `wt` assume Claude Code is installed and on `PATH` (`bootstrap.sh` installs it). Worktrees live under `~/.claude/worktrees/`.
- If you fork this repo, prune `Brewfile` and skip the steps in `bootstrap.sh` you don't want (Vercel, Wrangler, OpenCode, GPG key generation, etc.).
