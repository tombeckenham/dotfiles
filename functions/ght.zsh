# Open a new Ghostty window in the current directory (uses existing instance if running)
# Usage: ght
ght() {
  local dir
  dir=$(pwd)
  if pgrep -i ghostty >/dev/null 2>&1; then
    (osascript -e 'on run {thePath}' \
      -e 'tell application "Ghostty" to activate' \
      -e 'delay 0.5' \
      -e 'tell application "System Events" to keystroke "n" using command down' \
      -e 'delay 0.8' \
      -e 'tell application "System Events" to keystroke "cd " & (quoted form of thePath)' \
      -e 'tell application "System Events" to key code 36' \
      -e 'end run' -- "$dir" &)
  else
    open -a Ghostty --args --working-directory="$dir"
  fi
}
