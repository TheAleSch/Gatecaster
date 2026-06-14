#!/bin/zsh
# Zoom meeting control via System Events keyboard-shortcut dispatch.
#
# Why GUI scripting and not AppleScript proper: Zoom ships NO scripting dictionary
# (`sdef /Applications/zoom.us.app` is empty), so `tell application "zoom.us" to
# mute` doesn't exist. The only reliable local control is sending Zoom's own
# keyboard shortcuts through System Events — exactly what a human would press.
#
# Process-name guard: Zoom installs as "zoom.us" (direct download) OR "Zoom" (Mac
# App Store) with different process names. We resolve whichever is actually running
# and target that; if neither is running we exit quietly so a tap is a harmless no-op.

action="$1"

# Resolve the running Zoom process name without launching anything.
proc=$(osascript <<'APPLESCRIPT'
tell application "System Events"
  if exists process "zoom.us" then
    return "zoom.us"
  else if exists process "Zoom" then
    return "Zoom"
  else
    return ""
  end if
end tell
APPLESCRIPT
)
[ -z "$proc" ] && { echo "zoom not running"; exit 0; }

# key: dispatch a keystroke with modifiers.  key <char> <modifier-list>
key() {
  osascript -e "tell application \"System Events\" to tell process \"$proc\" to keystroke \"$1\" using {$2}"
}
# keycode: dispatch a raw key code (for non-character keys like Y / Return).
# An empty modifier list (`using {}`) is a syntax error, so omit `using` entirely.
keycode() {
  if [ -n "$2" ]; then
    osascript -e "tell application \"System Events\" to tell process \"$proc\" to key code $1 using {$2}"
  else
    osascript -e "tell application \"System Events\" to tell process \"$proc\" to key code $1"
  fi
}

case "$action" in
  mute)        key "a" "command down, shift down" ;;   # Cmd+Shift+A
  video)       key "v" "command down, shift down" ;;   # Cmd+Shift+V
  share)       key "s" "command down, shift down" ;;   # Cmd+Shift+S (opens picker)
  raisehand)   keycode 16 "option down" ;;             # Opt+Y (key code 16 = 'y')
  record-local|record-|record) key "r" "command down, shift down" ;;  # Cmd+Shift+R (default if config unset)
  record-cloud) key "c" "command down, shift down" ;;  # Cmd+Shift+C
  participants) key "u" "command down" ;;              # Cmd+U
  fullscreen)  key "f" "command down, shift down" ;;   # Cmd+Shift+F

  # Emoji reactions — direct shortcuts Opt+Cmd+4..9 (clap/thumbs/heart/joy/wow/tada).
  react-clap)   key "4" "command down, option down" ;;
  react-yes)    key "5" "command down, option down" ;;
  react-heart)  key "6" "command down, option down" ;;

  # Leave: activate Zoom first so the MAIN window has focus — Cmd+W closes whatever
  # window is frontmost, and a focused chat/participants panel would swallow it.
  # Then confirm the leave dialog with Return (key code 36).
  leave)
    osascript -e "tell application \"$proc\" to activate"
    sleep 0.2
    key "w" "command down"
    sleep 0.5
    keycode 36 ""
    ;;

  *) echo "unknown action: $action"; exit 1 ;;
esac
