# Activate Cursor and tile it to the left half of the screen
_cursor_tile_left() {
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
    -e 'end tell' > /dev/null 2>&1
}
