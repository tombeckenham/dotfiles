#!/bin/zsh
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Bootstrapping from $DOTFILES_DIR"

# 1. Xcode Command Line Tools
if ! xcode-select -p &>/dev/null; then
  echo "==> Installing Xcode Command Line Tools..."
  xcode-select --install
  echo "    Waiting for installation to complete (press any key when done)..."
  read -n 1 -s
fi

# 2. Homebrew
if ! command -v brew &>/dev/null; then
  echo "==> Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# 3. Install packages from Brewfile
echo "==> Running brew bundle..."
brew bundle --file="$DOTFILES_DIR/Brewfile"

# 4. Antidote (zsh plugin manager)
if [[ ! -d ~/.antidote ]]; then
  echo "==> Cloning Antidote..."
  git clone --depth=1 https://github.com/mattmc3/antidote.git ~/.antidote
fi

# 5. Create directories
mkdir -p ~/.gnupg ~/.config
chmod 700 ~/.gnupg

# 6. Symlink config files
symlink() { rm -f "$2" && ln -sf "$1" "$2" && echo "    $2 -> $1"; }

echo "==> Creating symlinks..."
symlink "$DOTFILES_DIR/.zshrc"           "$HOME/.zshrc"
symlink "$DOTFILES_DIR/.zsh_plugins.txt" "$HOME/.zsh_plugins.txt"
symlink "$DOTFILES_DIR/starship.toml"    "$HOME/.config/starship.toml"
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
gh auth setup-git

# 8. Git identity + GPG signing key (per-machine, not tracked)
if [[ ! -f "$HOME/.gitconfig.local" ]]; then
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

  {
    echo "[user]"
    echo "	name = $git_name"
    echo "	email = $git_email"
    if [[ -n "$gpg_key" ]]; then
      echo "	signingkey = $gpg_key"
    fi
    if [[ -z "$gpg_key" ]]; then
      echo "[commit]"
      echo "	gpgsign = false"
      echo "[tag]"
      echo "	gpgSign = false"
    fi
  } > "$HOME/.gitconfig.local"

  echo "    Written to ~/.gitconfig.local"
fi

# 9. Install language runtimes
echo "==> Installing language runtimes..."
eval "$(fnm env)"
fnm install --lts
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

# 14. Install lefthook for pre-commit secret scanning
echo "==> Installing lefthook hooks..."
(cd "$DOTFILES_DIR" && lefthook install)

# 15. Done
echo ""
echo "==> Done! Open a new terminal to load the updated config."
