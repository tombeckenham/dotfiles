splt() {
  local cols=$(tput cols)
  local rows=$(tput lines)

  # Black block-letters on yellow background
  local blk=$'\033[30;43m'
  local yel=$'\033[43m'
  local rst=$'\033[0m'

  # ASCII block-letter "PICK ME" (each letter ~7 rows tall)
  local banner=(
    "████  █  ██  █  █     █   █ ████"
    "█   █ █ █  █ █ █      ██ ██ █   "
    "█   █ █ █    ██       █ █ █ █   "
    "████  █ █    █ █      █   █ ████"
    "█     █ █    ██       █   █ █   "
    "█     █ █  █ █ █      █   █ █   "
    "█     █  ██  █  █     █   █ ████"
  )

  local banner_width=${#banner[1]}
  local banner_height=${#banner[@]}

  # Vertical padding to center the banner
  local top_pad=$(( (rows - banner_height) / 2 ))
  if (( top_pad < 0 )); then top_pad=0; fi

  clear

  # Fill line: yellow background across entire width
  local fill_line="${yel}$(printf '%*s' "$cols" '')${rst}"

  # Top padding
  for (( i = 0; i < top_pad; i++ )); do
    printf '%s\n' "$fill_line"
  done

  # Banner lines, centered horizontally
  local left_pad=$(( (cols - banner_width) / 2 ))
  if (( left_pad < 0 )); then left_pad=0; fi

  for line in "${banner[@]}"; do
    local pad_left=$(printf '%*s' "$left_pad" '')
    local pad_right_len=$(( cols - left_pad - banner_width ))
    if (( pad_right_len < 0 )); then pad_right_len=0; fi
    local pad_right=$(printf '%*s' "$pad_right_len" '')
    printf '%s\n' "${yel}${pad_left}${blk}${line}${yel}${pad_right}${rst}"
  done

  # Bottom padding
  local bottom_pad=$(( rows - top_pad - banner_height - 1 ))
  if (( bottom_pad < 0 )); then bottom_pad=0; fi
  for (( i = 0; i < bottom_pad; i++ )); do
    printf '%s\n' "$fill_line"
  done

  # Activate Cursor, exit full-screen if needed, then tile left
  osascript \
    -e 'tell application "Cursor" to activate' \
    -e 'delay 0.3' \
    -e 'tell application "System Events"' \
    -e '  tell process "Cursor"' \
    -e '    try' \
    -e '      click menu item "Left of Screen" of menu 1 of menu item "Full-Screen Tile" of menu "Window" of menu bar 1' \
    -e '    on error' \
    -e '      try' \
    -e '        click menu item "Exit Full Screen" of menu "Window" of menu bar 1' \
    -e '      on error' \
    -e '        keystroke "f" using {control down, command down}' \
    -e '      end try' \
    -e '      delay 1.0' \
    -e '      try' \
    -e '        click menu item "Left of Screen" of menu 1 of menu item "Full-Screen Tile" of menu "Window" of menu bar 1' \
    -e '      end try' \
    -e '    end try' \
    -e '  end tell' \
    -e 'end tell'

  # Wait for user to continue
  printf '\n%sPress enter to continue...%s' "$yel" "$rst"
  read -r
  clear
}
