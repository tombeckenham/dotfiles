#!/bin/zsh
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Bootstrapping from $DOTFILES_DIR"

# CLI installers below drop binaries here; .zshrc isn't loaded in this script,
# so without this every re-run would reinstall them.
export PATH="$HOME/.local/bin:$HOME/Library/Application Support/fnm:$HOME/Library/pnpm:$HOME/.bun/bin:$HOME/.opencode/bin:$HOME/.grok/bin:$HOME/.pyenv/bin:/opt/homebrew/bin:$PATH"
mkdir -p "$HOME/.local/bin"

# macOS CPU name used by GitHub release assets (arm64 or amd64).
release_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo arm64 ;;
    x86_64) echo amd64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

# Print the browser download URL of the first asset whose name matches.
github_asset_url() {
  local repo="$1" pattern="$2"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | /usr/bin/python3 -c '
import json, re, sys
pat = re.compile(sys.argv[1])
for asset in json.load(sys.stdin)["assets"]:
    if pat.search(asset["name"]):
        print(asset["browser_download_url"])
        raise SystemExit(0)
sys.exit("no release asset matched %s" % pat.pattern)
' "$pattern"
}

unquarantine() {
  xattr -dr com.apple.quarantine "$1" 2>/dev/null || true
}

# Copy App.app out of a remote disk image into /Applications.
install_dmg_app() {
  local url="$1" app="$2" tmp mount
  [[ -d "/Applications/${app}.app" ]] && return 0
  echo "==> Installing ${app}..."
  tmp="$(mktemp -d)"
  curl -fL --retry 3 --output "$tmp/app.dmg" "$url"
  mount="$(hdiutil attach "$tmp/app.dmg" -nobrowse -readonly | /usr/bin/sed -n 's#.*\(/Volumes/.*\)#\1#p' | /usr/bin/tail -1)"
  if [[ ! -d "${mount}/${app}.app" ]]; then
    echo "ERROR: ${app}.app not found in ${mount}" >&2
    [[ -n "$mount" ]] && hdiutil detach "$mount" >/dev/null || true
    rm -rf "$tmp"
    return 1
  fi
  cp -R "${mount}/${app}.app" /Applications/
  hdiutil detach "$mount" >/dev/null
  unquarantine "/Applications/${app}.app"
  rm -rf "$tmp"
}

# 1. Xcode Command Line Tools
if ! xcode-select -p &>/dev/null; then
  echo "==> Installing Xcode Command Line Tools..."
  xcode-select --install
  echo "    Waiting for installation to complete (press any key when done)..."
  read -n 1 -s
fi

# 2. Homebrew — only tools with no official macOS installer (see Brewfile)
if ! command -v brew &>/dev/null; then
  echo "==> Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

echo "==> Running brew bundle..."
brew bundle --file="$DOTFILES_DIR/Brewfile"

# 3. Official installers. Each one is the curl script or disk image from the
#    project's own site. A Homebrew copy earlier on PATH does not count: the
#    native location is what gets installed, and .zshrc searches it first.
arch="$(release_arch)"

if [[ ! -x "$HOME/.local/bin/starship" ]]; then
  echo "==> Installing Starship..."
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"
fi

if [[ ! -x "$HOME/Library/Application Support/fnm/fnm" ]]; then
  echo "==> Installing fnm..."
  # The script's macOS default is Homebrew. --force-install takes the binary.
  # --skip-shell: .zshrc already runs `fnm env`.
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --force-install --skip-shell
fi

if [[ ! -x "$HOME/Library/pnpm/pnpm" && ! -x "$HOME/Library/pnpm/bin/pnpm" ]]; then
  echo "==> Installing pnpm..."
  export PNPM_HOME="$HOME/Library/pnpm"
  # `pnpm setup` appends to the rc of $SHELL. Point that at bash, then throw
  # the edit away — .zshrc already exports PNPM_HOME and puts it on PATH.
  bashrc_backup=""
  if [[ -f "$HOME/.bashrc" ]]; then
    bashrc_backup="$(mktemp)"
    cp "$HOME/.bashrc" "$bashrc_backup"
  fi
  curl -fsSL https://get.pnpm.io/install.sh | env PNPM_HOME="$PNPM_HOME" SHELL=/bin/bash sh -
  if [[ -n "$bashrc_backup" ]]; then
    mv "$bashrc_backup" "$HOME/.bashrc"
  else
    rm -f "$HOME/.bashrc"
  fi
fi

if [[ ! -x "$HOME/.pyenv/bin/pyenv" ]]; then
  if [[ -d "$HOME/.pyenv" ]]; then
    echo "==> pyenv: ~/.pyenv already exists, leaving it (Homebrew uses that directory for versions)."
  else
    echo "==> Installing pyenv..."
    curl -fsSL https://pyenv.run | bash
  fi
fi

if [[ ! -x "$HOME/.local/bin/gh" ]]; then
  echo "==> Installing GitHub CLI..."
  tmp="$(mktemp -d)"
  curl -fL --retry 3 --output "$tmp/gh.zip" "$(github_asset_url cli/cli "^gh_.*_macOS_${arch}\\.zip$")"
  unzip -q "$tmp/gh.zip" -d "$tmp"
  gh_bin="$(/usr/bin/find "$tmp" -type f -path '*/bin/gh' -print -quit)"
  install -m 755 "$gh_bin" "$HOME/.local/bin/gh"
  unquarantine "$HOME/.local/bin/gh"
  rm -rf "$tmp"
fi

if [[ ! -x "$HOME/.local/bin/git-lfs" ]]; then
  echo "==> Installing Git LFS..."
  tmp="$(mktemp -d)"
  curl -fL --retry 3 --output "$tmp/lfs.zip" "$(github_asset_url git-lfs/git-lfs "^git-lfs-darwin-${arch}-.*\\.zip$")"
  unzip -q "$tmp/lfs.zip" -d "$tmp"
  install_sh="$(/usr/bin/find "$tmp" -name install.sh -print -quit)"
  (cd "$(dirname "$install_sh")" && PREFIX="$HOME/.local" ./install.sh)
  unquarantine "$HOME/.local/bin/git-lfs"
  rm -rf "$tmp"
fi

if [[ ! -x "$HOME/.local/bin/jq" ]]; then
  echo "==> Installing jq..."
  curl -fL --retry 3 --output "$HOME/.local/bin/jq" \
    "https://github.com/jqlang/jq/releases/latest/download/jq-macos-${arch}"
  chmod 755 "$HOME/.local/bin/jq"
  unquarantine "$HOME/.local/bin/jq"
fi

if [[ ! -x "$HOME/.local/bin/lefthook" ]]; then
  echo "==> Installing lefthook..."
  case "$arch" in
    arm64) hook_arch="MacOS_arm64" ;;
    amd64) hook_arch="MacOS_x86_64" ;;
  esac
  curl -fL --retry 3 --output "$HOME/.local/bin/lefthook" \
    "$(github_asset_url evilmartians/lefthook "^lefthook_.*_${hook_arch}$")"
  chmod 755 "$HOME/.local/bin/lefthook"
  unquarantine "$HOME/.local/bin/lefthook"
fi

if [[ ! -x "$HOME/.local/bin/zoxide" ]]; then
  echo "==> Installing zoxide..."
  curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
fi

if [[ ! -x "$HOME/.local/bin/doppler" ]]; then
  echo "==> Installing Doppler CLI..."
  # Completions follow $HOME. A throwaway home keeps the installer off ~/.zshrc.
  # GnuPG (from Homebrew) verifies the binary signature.
  fake_home="$(mktemp -d)"
  curl -fsSL --tlsv1.2 --proto "=https" --retry 3 https://cli.doppler.com/install.sh \
    | env HOME="$fake_home" sh -s -- --install-path "$HOME/.local/bin"
  rm -rf "$fake_home"
  unquarantine "$HOME/.local/bin/doppler"
fi

if [[ ! -x "$HOME/.local/bin/herdr" ]]; then
  echo "==> Installing Herdr..."
  curl -fsSL https://herdr.dev/install.sh | sh
fi

if [[ ! -d /Applications/Ghostty.app ]]; then
  ghostty_url="$(curl -fsSL https://release.files.ghostty.org/appcast.xml | /usr/bin/grep -oE 'https://release.files.ghostty.org/[0-9.]+/Ghostty\.dmg' | /usr/bin/tail -1)"
  install_dmg_app "$ghostty_url" Ghostty
fi

if [[ ! -d /Applications/Cursor.app ]]; then
  case "$(uname -m)" in
    arm64) cursor_platform="darwin-arm64" ;;
    x86_64) cursor_platform="darwin-x64" ;;
  esac
  cursor_url="$(curl -fsSL "https://cursor.com/api/download?platform=${cursor_platform}&releaseTrack=stable" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["downloadUrl"])')"
  install_dmg_app "$cursor_url" Cursor
fi

if [[ ! -d /Applications/OrbStack.app ]]; then
  install_dmg_app "https://orbstack.dev/download/stable/latest/${arch}" OrbStack
fi

# 4. Antidote (zsh plugin manager)
if [[ ! -d ~/.antidote ]]; then
  echo "==> Cloning Antidote..."
  git clone --depth=1 https://github.com/mattmc3/antidote.git ~/.antidote
fi

# 5. Create directories
mkdir -p ~/.gnupg ~/.config ~/.config/herdr
chmod 700 ~/.gnupg

# 6. Symlink config files
symlink() { rm -f "$2" && ln -sf "$1" "$2" && echo "    $2 -> $1"; }

echo "==> Creating symlinks..."
symlink "$DOTFILES_DIR/.zshrc"           "$HOME/.zshrc"
symlink "$DOTFILES_DIR/.zsh_plugins.txt" "$HOME/.zsh_plugins.txt"
symlink "$DOTFILES_DIR/starship.toml"    "$HOME/.config/starship.toml"
symlink "$DOTFILES_DIR/herdr/config.toml" "$HOME/.config/herdr/config.toml"
symlink "$DOTFILES_DIR/gpg.conf"         "$HOME/.gnupg/gpg.conf"
symlink "$DOTFILES_DIR/gpg-agent.conf"   "$HOME/.gnupg/gpg-agent.conf"
symlink "$DOTFILES_DIR/functions"        "$HOME/.zsh_functions"

# 7. GitHub CLI authentication
if ! gh auth status &>/dev/null; then
  echo ""
  echo "==> Authenticating with GitHub CLI..."
  echo "    This will open a browser for OAuth authentication."
  gh auth login --hostname github.com --git-protocol https --web -s user,write:gpg_key
elif ! gh auth status 2>&1 | grep -q "'write:gpg_key'"; then
  echo "==> Refreshing GitHub token for required scopes..."
  gh auth refresh -s user,write:gpg_key
fi

# 8. Git config
echo "==> Configuring git..."

# Base config (idempotent, always applied)
git lfs install --skip-repo
git config --global commit.gpgsign true
git config --global tag.gpgSign true
gh auth setup-git
# Identity (only if not already set)
if [[ -z "$(git config --global user.name 2>/dev/null)" || -z "$(git config --global user.email 2>/dev/null)" ]]; then
  echo ""
  echo "==> Setting up git identity..."

  # Detect name/email: existing git config → GitHub API → manual prompt
  local git_name git_email
  git_name=$(git config --global user.name 2>/dev/null || true)
  git_email=$(git config --global user.email 2>/dev/null || true)
  if [[ -z "$git_name" ]]; then
    git_name=$(gh api user --jq '.name // empty' 2>/dev/null) || git_name=""
  fi

  local git_emails=()
  if [[ -z "$git_email" ]]; then
    local noreply primary
    noreply=$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"' 2>/dev/null) || noreply=""
    primary=$(gh api user/emails --jq '.[] | select(.primary) | .email' 2>/dev/null) || primary=""
    [[ -n "$noreply" ]] && git_emails+=("$noreply")
    [[ -n "$primary" && "$primary" != "$noreply" ]] && git_emails+=("$primary")
  fi

  # Show detected values and let user confirm or override
  if [[ -n "$git_name" ]]; then
    printf "    Name [$git_name]: "; read input
    git_name="${input:-$git_name}"
  else
    printf "    Name: "; read git_name
  fi
  if [[ -n "$git_email" ]]; then
    printf "    Email [$git_email]: "; read input
    git_email="${input:-$git_email}"
  elif (( ${#git_emails[@]} > 0 )); then
    echo "    Available emails:"
    for i in {1..${#git_emails[@]}}; do
      echo "      $i. ${git_emails[$i]}"
    done
    printf "    Email [1]: "; read input
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#git_emails[@]} )); then
      git_email="${git_emails[$input]}"
    elif [[ -n "$input" ]]; then
      git_email="$input"
    else
      git_email="${git_emails[1]}"
    fi
  else
    printf "    Email: "; read git_email
  fi

  gpg_key=""
  echo ""
  printf "    Generate a new GPG signing key? [Y/n/import]: "; read gpg_choice
  gpg_choice="${gpg_choice:-Y}"

  case "$gpg_choice" in
    [Yy]*)
      # Check for existing key first
      gpg_key=$(gpg --list-keys --with-colons "$git_name <$git_email>" 2>/dev/null \
        | awk -F: '/^pub:/{found=1} found && /^fpr:/{print substr($10, length($10)-15); exit}') || true

      if [[ -n "$gpg_key" ]]; then
        echo "    Existing GPG key found: $gpg_key"
        printf "    Use this key? [Y/n]: "; read use_existing
        use_existing="${use_existing:-Y}"
        if [[ ! "$use_existing" =~ ^[Yy] ]]; then
          gpg_key=""
          echo "    Skipping GPG signing."
        fi
      else
        echo "    Generating Ed25519 GPG key..."
        if gpg --batch --passphrase '' --pinentry-mode loopback --quick-generate-key "$git_name <$git_email>" ed25519 cert,sign 2y; then
          gpg_key=$(gpg --list-keys --with-colons "$git_name <$git_email>" 2>/dev/null \
            | awk -F: '/^pub:/{found=1} found && /^fpr:/{print substr($10, length($10)-15); exit}') || true
          echo "    GPG key generated: $gpg_key"
        else
          echo "    ERROR: GPG key generation failed."
          gpg_key=""
        fi
      fi

      if [[ -n "$gpg_key" ]] && gh auth status &>/dev/null; then
        echo "    Registering GPG key with GitHub..."
        if gpg --armor --export "$gpg_key" | gh gpg-key add -t "$(hostname) $(date +%Y-%m-%d)"; then
          echo "    GPG key registered with GitHub."
        else
          echo "    WARNING: Failed to register GPG key with GitHub."
          echo "    Register manually: gpg --armor --export $gpg_key | gh gpg-key add"
        fi
      elif [[ -n "$gpg_key" ]]; then
        echo "    WARNING: Not authenticated with GitHub. Register later:"
        echo "      gpg --armor --export $gpg_key | gh gpg-key add"
      fi
      ;;
    [Ii]*)
      printf "    GPG key ID to use: "; read gpg_key
      if [[ -n "$gpg_key" ]] && ! gpg --list-secret-keys "$gpg_key" &>/dev/null; then
        echo "    WARNING: Key $gpg_key not found locally. Import it first with: gpg --import <keyfile>"
        gpg_key=""
      fi
      ;;
    *)
      echo "    Skipping GPG signing."
      ;;
  esac

  git config --global user.name "$git_name"
  git config --global user.email "$git_email"
  if [[ -n "$gpg_key" ]]; then
    git config --global user.signingkey "$gpg_key"
  else
    git config --global commit.gpgsign false
    git config --global tag.gpgSign false
  fi
  echo "    Git identity configured."
fi

# 9. Install language runtimes
echo "==> Installing language runtimes..."
eval "$(fnm env)"
fnm install --latest
eval "$(command pyenv init -)"
pyenv install --skip-existing 3.12
pyenv global 3.12

# 10. Bun
if ! command -v bun &>/dev/null; then
  echo "==> Installing Bun..."
  curl -fsSL https://bun.com/install | bash
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi

# 11. Install global dev CLIs
echo "==> Installing global dev CLIs..."
bun install -g vercel wrangler

# 12. Claude Code
if ! command -v claude &>/dev/null; then
  echo "==> Installing Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash
fi

# 13. OpenCode
if ! command -v opencode &>/dev/null; then
  echo "==> Installing OpenCode..."
  curl -fsSL https://opencode.ai/install | bash
fi

# 14. Grok Build CLI
if ! command -v grok &>/dev/null; then
  echo "==> Installing Grok Build CLI..."
  curl -fsSL https://x.ai/cli/install.sh | bash
fi

# 15. herdr-reviewr (PR review split used by ghipr/ghwtprv)
if command -v herdr &>/dev/null; then
  if ! herdr plugin list 2>/dev/null | grep -q persiyanov.reviewr; then
    echo "==> Installing herdr-reviewr..."
    herdr plugin install -y persiyanov/herdr-reviewr
  fi
else
  echo "    WARNING: herdr not found. ghi/ghipr/ghsb need it: https://herdr.dev"
fi

# 16. ghsb agent plugin (/ghi, /ghipr, ...) from this repo's marketplace
if ! claude plugin list 2>/dev/null | grep -q 'ghsb@dotfiles'; then
  echo "==> Installing ghsb Claude Code plugin..."
  claude plugin marketplace add tombeckenham/dotfiles
  claude plugin install ghsb@dotfiles
fi
if ! grok plugin list 2>/dev/null | grep -q 'ghsb'; then
  echo "==> Installing ghsb Grok plugin..."
  grok plugin marketplace add tombeckenham/dotfiles
  grok plugin install ghsb --trust
fi

# 17. Doppler (secrets .zshrc exports live in the "dotfiles" project)
if ! doppler me &>/dev/null; then
  echo "==> Logging in to Doppler..."
  doppler login
fi
# Seed the local cache .zshrc reads from
doppler secrets download -p dotfiles -c dev --no-file >/dev/null \
  || echo "    WARNING: couldn't fetch Doppler project 'dotfiles'. Add secrets with: doppler secrets set -p dotfiles -c dev KEY"

# 18. Power management (always-on server mode)
echo "==> Configuring power management..."
sudo pmset -a sleep 0 disksleep 0
sudo pmset -a displaysleep 5
sudo pmset -a autorestart 1

# 19. Install lefthook for pre-commit secret scanning
echo "==> Installing lefthook hooks..."
(cd "$DOTFILES_DIR" && lefthook install)

# 20. Done
echo ""
echo "==> Done! Open a new terminal to load the updated config."
