# Consolidated PATH (set once at start, removes duplicates)
path=(
  $HOME/.opencode/bin
  $HOME/.local/bin
  $HOME/.bun/bin
  /opt/homebrew/bin

  $HOME/Library/pnpm
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

# fnm (fast node manager - replaces nvm)
eval "$(fnm env --use-on-cd)"

# pnpm
export PNPM_HOME="$HOME/Library/pnpm"

# Lazy-load pyenv (only loads when you first use python).
# Init must not call `pyenv` with no args: that prints the help text.
export PYENV_ROOT="$HOME/.pyenv"
_pyenv_lazy_init() {
  unfunction _pyenv_lazy_init pyenv python python3 pip pip3
  eval "$(command pyenv init -)"
}
pyenv() { _pyenv_lazy_init; pyenv "$@" }
python() { _pyenv_lazy_init; python "$@" }
python3() { _pyenv_lazy_init; python3 "$@" }
pip() { _pyenv_lazy_init; pip "$@" }
pip3() { _pyenv_lazy_init; pip3 "$@" }

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


# The next line updates PATH for the Google Cloud SDK.
if [ -f '/Users/tom/code/google-cloud-sdk/path.zsh.inc' ]; then . '/Users/tom/code/google-cloud-sdk/path.zsh.inc'; fi

# The next line enables shell command completion for gcloud.
if [ -f '/Users/tom/code/google-cloud-sdk/completion.zsh.inc' ]; then . '/Users/tom/code/google-cloud-sdk/completion.zsh.inc'; fi
