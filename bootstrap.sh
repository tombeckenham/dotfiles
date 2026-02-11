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
symlink() { ln -sf "$1" "$2" && echo "    $2 -> $1"; }

echo "==> Creating symlinks..."
symlink "$DOTFILES_DIR/.zshrc"           "$HOME/.zshrc"
symlink "$DOTFILES_DIR/.gitconfig"       "$HOME/.gitconfig"
symlink "$DOTFILES_DIR/.zsh_plugins.txt" "$HOME/.zsh_plugins.txt"
symlink "$DOTFILES_DIR/starship.toml"    "$HOME/.config/starship.toml"
symlink "$DOTFILES_DIR/gpg.conf"         "$HOME/.gnupg/gpg.conf"
symlink "$DOTFILES_DIR/gpg-agent.conf"   "$HOME/.gnupg/gpg-agent.conf"
symlink "$DOTFILES_DIR/functions"        "$HOME/.zsh_functions"

# 7. Git identity (per-machine, not tracked)
if [[ ! -f "$HOME/.gitconfig.local" ]]; then
  echo ""
  echo "==> Setting up git identity..."
  printf "    Name: "; read git_name
  printf "    Email: "; read git_email
  printf "    GPG signing key (leave blank to skip): "; read gpg_key

  {
    echo "[user]"
    echo "	name = $git_name"
    echo "	email = $git_email"
    if [[ -n "$gpg_key" ]]; then
      echo "	signingkey = $gpg_key"
    fi
  } > "$HOME/.gitconfig.local"

  # Set default-key in gpg.conf if a GPG key was provided
  if [[ -n "$gpg_key" ]]; then
    echo "default-key $gpg_key" >> "$HOME/.gnupg/gpg.conf"
  fi

  echo "    Written to ~/.gitconfig.local"
fi

# 8. Install language runtimes
echo "==> Installing language runtimes..."
eval "$(fnm env)"
fnm install --lts
eval "$(command pyenv init -)"
pyenv install --skip-existing 3.12
pyenv global 3.12

# 9. GPG signing key check (only if a key was configured)
gpg_key_id=$(git config --global user.signingkey 2>/dev/null || true)
if [[ -n "$gpg_key_id" ]] && ! gpg --list-secret-keys "$gpg_key_id" &>/dev/null; then
  echo ""
  echo "==> GPG signing key not found. To set up commit signing:"
  echo "    On your old machine:  gpg --export-secret-keys $gpg_key_id > ~/gpg-key.bak"
  echo "    On this machine:      gpg --import ~/gpg-key.bak && rm ~/gpg-key.bak"
fi

# 10. Install lefthook for pre-commit secret scanning
echo "==> Installing lefthook hooks..."
(cd "$DOTFILES_DIR" && lefthook install)

# 11. Done
echo ""
echo "==> Done! Open a new terminal to load the updated config."
