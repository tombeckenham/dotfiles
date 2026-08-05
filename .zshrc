# Consolidated PATH (set once at start, removes duplicates)
path=(
  $HOME/.opencode/bin
  $HOME/.local/bin
  $HOME/.bun/bin
  /opt/homebrew/bin

  $HOME/Library/pnpm
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

# Lazy-load pyenv (only loads when you first use python)
export PYENV_ROOT="$HOME/.pyenv"
pyenv() {
  unfunction pyenv python python3 pip pip3
  eval "$(command pyenv init -)"
  pyenv "$@"
}
python() { pyenv; python "$@" }
python3() { pyenv; python3 "$@" }
pip() { pyenv; pip "$@" }
pip3() { pyenv; pip3 "$@" }

# Source all function files
for f in ~/.zsh_functions/*.zsh; source $f

# >>> grok installer >>>
export PATH="$HOME/.grok/bin:$PATH"
fpath=(~/.grok/completions/zsh $fpath)
autoload -Uz compinit && compinit -C
# <<< grok installer <<<


# Added by Antigravity CLI installer
export PATH="/Users/tom/.local/bin:$PATH"

# kimi-code
export PATH="/Users/tom/.kimi-code/bin:$PATH"
