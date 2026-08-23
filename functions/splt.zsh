# Yellow full-screen "PICK ME" banner. Used by splt and hsplt.
_splt_banner() {
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

  local top_pad=$(( (rows - banner_height) / 2 ))
  if (( top_pad < 0 )); then top_pad=0; fi

  clear

  local fill_line="${yel}$(printf '%*s' "$cols" '')${rst}"

  local i
  for (( i = 0; i < top_pad; i++ )); do
    printf '%s\n' "$fill_line"
  done

  local left_pad=$(( (cols - banner_width) / 2 ))
  if (( left_pad < 0 )); then left_pad=0; fi

  local line pad_left pad_right_len pad_right
  for line in "${banner[@]}"; do
    pad_left=$(printf '%*s' "$left_pad" '')
    pad_right_len=$(( cols - left_pad - banner_width ))
    if (( pad_right_len < 0 )); then pad_right_len=0; fi
    pad_right=$(printf '%*s' "$pad_right_len" '')
    printf '%s\n' "${yel}${pad_left}${blk}${line}${yel}${pad_right}${rst}"
  done

  local bottom_pad=$(( rows - top_pad - banner_height - 1 ))
  if (( bottom_pad < 0 )); then bottom_pad=0; fi
  for (( i = 0; i < bottom_pad; i++ )); do
    printf '%s\n' "$fill_line"
  done
}

_splt_wait() {
  local yel=$'\033[43m'
  local rst=$'\033[0m'
  printf '\n%sPress enter to continue...%s' "$yel" "$rst"
  read -r
  clear
}

splt() {
  # Path/name of the folder open in Cursor, so the correct window gets tiled left
  # even when another Cursor window is full-screen. Defaults to the current
  # directory for manual `splt` invocations; callers like ghwt pass the worktree.
  local target_folder="${1:-$PWD}"

  _splt_banner

  # Open Cursor at the target folder first so the window exists and has a
  # title we can match when tiling (manual `splt` and ghwt* callers).
  cursor --new-window "$target_folder"

  # Activate Cursor, exit full-screen if needed, then tile left
  _cursor_tile_left "$target_folder"

  _splt_wait
}
