# Re-read ~/.zsh_functions before the next interactive command when a file
# changed. A shell that started before this file existed needs one
# `source ~/.zshrc` before the hook is installed.
#
# Stamp is mtime and size. A same-second edit that does not change the size
# is picked up on the next second's save.

_ghsb_functions_dir() {
  echo "${_GHSB_FUNCTIONS_DIR:-$HOME/.zsh_functions}"
}

# One line per file: "mtime size name". Empty if the directory is missing.
_ghsb_functions_stamp() {
  emulate -L zsh
  local dir f
  local -a mt sz lines
  dir=$(_ghsb_functions_dir)
  [[ -d $dir ]] || return 0
  zmodload -F zsh/stat b:zstat
  for f in "$dir"/*.zsh(N); do
    zstat -A mt +mtime -- "$f" || continue
    zstat -A sz +size -- "$f" || continue
    lines+=("$mt[1] $sz[1] ${f:t}")
  done
  print -r -- ${(j:\n:)lines}
}

_ghsb_reload_functions() {
  emulate -L zsh
  [[ -n $_GHSB_RELOAD_BUSY ]] && return 0
  typeset -g _GHSB_RELOAD_BUSY=1

  local stamp dir f rc=0
  local -a files
  stamp=$(_ghsb_functions_stamp)
  if [[ "$stamp" == "$_GHSB_FUNCTIONS_STAMP" ]]; then
    unset _GHSB_RELOAD_BUSY
    return 0
  fi

  dir=$(_ghsb_functions_dir)
  files=("$dir"/*.zsh(N))
  for f in $files; do
    . "$f" || { rc=1; break }
  done
  unset _GHSB_RELOAD_BUSY
  (( rc )) && return 1
  typeset -g _GHSB_FUNCTIONS_STAMP=$stamp
}

if [[ -z ${_GHSB_FUNCTIONS_STAMP+x} ]]; then
  typeset -g _GHSB_FUNCTIONS_STAMP="$(_ghsb_functions_stamp)"
fi

if [[ -o interactive ]]; then
  autoload -Uz add-zsh-hook
  add-zsh-hook preexec _ghsb_reload_functions
fi
