#!/usr/bin/env zsh
# The preexec hook re-sources ~/.zsh_functions when a file's mtime or size changes.
export _GHSB_FUNCTIONS_DIR=$(mktemp -d)
root="${0:A:h}/.."

fail() { echo "FAIL $1"; exit 1 }

set_mtime() {
  python3 -c 'import os,sys; os.utime(sys.argv[1], (float(sys.argv[2]), float(sys.argv[2])))' "$1" "$2"
}

source "$root/functions/_ghsb_reload.zsh"

print -r -- 'demo_cmd() { echo v1 }' > "$_GHSB_FUNCTIONS_DIR/demo.zsh"
base=$(_ghsb_functions_stamp | awk '{print $1; exit}')
set_mtime "$_GHSB_FUNCTIONS_DIR/demo.zsh" "$base"
# Match the stamp .zshrc would have after sourcing every file.
typeset -g _GHSB_FUNCTIONS_STAMP="$(_ghsb_functions_stamp)"
. "$_GHSB_FUNCTIONS_DIR/demo.zsh"
[[ $(demo_cmd) == v1 ]] || fail initial

# Same mtime, different size → reload.
print -r -- 'demo_cmd() { echo version-two }' > "$_GHSB_FUNCTIONS_DIR/demo.zsh"
set_mtime "$_GHSB_FUNCTIONS_DIR/demo.zsh" "$base"
_ghsb_reload_functions || fail size-reload
[[ $(demo_cmd) == version-two ]] || fail size-body

# Unchanged → leave the function alone.
_ghsb_reload_functions || fail stable
[[ $(demo_cmd) == version-two ]] || fail stable-body

# Syntax error does not move the stamp, so the next call tries again.
print -r -- 'demo_cmd() { echo v3' > "$_GHSB_FUNCTIONS_DIR/demo.zsh"
set_mtime "$_GHSB_FUNCTIONS_DIR/demo.zsh" $((base + 5))
_ghsb_reload_functions >/dev/null 2>&1 && fail should-fail
[[ $(demo_cmd) == version-two ]] || fail kept-old
print -r -- 'demo_cmd() { echo v3 }' > "$_GHSB_FUNCTIONS_DIR/demo.zsh"
set_mtime "$_GHSB_FUNCTIONS_DIR/demo.zsh" $((base + 5))
_ghsb_reload_functions || fail retry
[[ $(demo_cmd) == v3 ]] || fail v3

# Interactive shells install the hook once.
hook=$(zsh -f -i 2>/dev/null <<EOF
source "$root/functions/_ghsb_reload.zsh"
print -r -- \$preexec_functions
exit
EOF
)
[[ "$hook" == *_ghsb_reload_functions* ]] || fail hook
# Sourcing again must not stack a second copy.
hook2=$(zsh -f -i 2>/dev/null <<EOF
source "$root/functions/_ghsb_reload.zsh"
source "$root/functions/_ghsb_reload.zsh"
print -r -- \$preexec_functions
exit
EOF
)
count=$(print -r -- "$hook2" | tr ' ' '\n' | grep -c _ghsb_reload_functions)
[[ "$count" == 1 ]] || fail hook-once

echo OK
