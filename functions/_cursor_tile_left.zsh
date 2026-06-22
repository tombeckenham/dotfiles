# Activate Cursor and tile a specific window to the left half of the screen.
#
# Pass the worktree path (or folder name) so the right window is targeted. When
# another Cursor window is full-screen, that window lives on its own Space and is
# the one macOS reports as frontmost, so without an explicit match the tile lands
# on the wrong window. We match the just-opened folder by its title instead.
_cursor_tile_left() {
  # VS Code/Cursor window titles contain the workspace folder name (the path's
  # basename), e.g. "file.ts — dotfiles-123". Match on that.
  local match="${1:t}"

  osascript - "$match" >/dev/null 2>&1 <<'OSA'
on run argv
  set matchName to ""
  if (count of argv) > 0 then set matchName to item 1 of argv

  tell application "Cursor" to activate

  tell application "System Events"
    tell process "Cursor"
      -- Find and focus the window for the folder we just opened. It may still be
      -- loading, so poll briefly for its title to appear.
      if matchName is not "" then
        set targetWin to missing value
        repeat 20 times
          repeat with w in windows
            if (name of w) contains matchName then
              set targetWin to contents of w
              exit repeat
            end if
          end repeat
          if targetWin is not missing value then exit repeat
          delay 0.1
        end repeat

        if targetWin is not missing value then
          perform action "AXRaise" of targetWin
          set frontmost to true
          delay 0.3
        end if
      else
        delay 0.3
      end if

      -- Tile the focused window to the left half of the screen. If it's already
      -- full-screen the "Full-Screen Tile" submenu is absent, so exit full screen
      -- first and retry.
      try
        click menu item "Left of Screen" of menu 1 of menu item "Full-Screen Tile" of menu "Window" of menu bar 1
      on error
        try
          click menu item "Exit Full Screen" of menu "Window" of menu bar 1
        on error
          keystroke "f" using {control down, command down}
        end try
        delay 1.0
        try
          click menu item "Left of Screen" of menu 1 of menu item "Full-Screen Tile" of menu "Window" of menu bar 1
        end try
      end try
    end tell
  end tell
end run
OSA
}
