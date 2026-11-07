# Consolidated PATH (set once at start, removes duplicates)
path=(
  $HOME/.opencode/bin
  $HOME/.local/bin
  "$HOME/Library/Application Support/fnm"
  $HOME/.pyenv/bin
  $HOME/Library/pnpm
  $HOME/.bun/bin
  /opt/homebrew/bin

  $HOME/.kimi-code/bin
  $path
)
typeset -U path

# source antidote
source ~/.antidote/antidote.zsh

autoload -Uz compinit
compinit

# initialize plugins statically with ${ZDOTDIR:-~}/.zsh_plugins.txt
antidote load

# starship
eval "$(starship init zsh)"

# zoxide (smarter cd — use `z <dir>`, `zi` for interactive)
eval "$(zoxide init zsh)"

# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"

# fnm (fast node manager - replaces nvm). The install script drops the
# binary in Application Support; versions stay in ~/.local/share/fnm.
export FNM_DIR="$HOME/.local/share/fnm"
eval "$(fnm env --use-on-cd)"

# pnpm
export PNPM_HOME="$HOME/Library/pnpm"

# pyenv shims are real executables. Do not wrap python/python3: agents exec
# the binary, and a shell function is not one.
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(command pyenv init -)"

# Secrets from the Doppler "dotfiles" project. Reads Doppler's encrypted local
# cache (~60ms, a live fetch is ~1s) and refreshes it in the background for the next shell.
if command -v doppler &>/dev/null; then
  eval "$(doppler secrets download -p dotfiles -c dev --no-file --fallback-only 2>/dev/null \
    | jq -r 'to_entries[] | select(.key | startswith("DOPPLER_") | not) | "export \(.key)=\(.value | @sh)"')"
  doppler secrets download -p dotfiles -c dev --no-file >/dev/null 2>&1 &!
fi

# Source all function files
for f in ~/.zsh_functions/*.zsh; source $f

# >>> grok installer >>>
export PATH="$HOME/.grok/bin:$PATH"
fpath=(~/.grok/completions/zsh $fpath)
autoload -Uz compinit && compinit -C
# <<< grok installer <<<

