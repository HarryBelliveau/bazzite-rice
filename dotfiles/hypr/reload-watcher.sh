#!/usr/bin/env bash
# Restart workspace-watcher.sh so it picks up edits to its RULES table.
# (bash reads RULES once at startup; the running watcher is stale until reloaded.)
#
# Lives in its own script so the killer shell's own argv doesn't contain the
# string "workspace-watcher.sh" -- if it did, pkill -f would suicide.

set -u

pkill -f workspace-watcher.sh 2>/dev/null || true
sleep 0.3
hyprctl dispatch exec '~/.config/hypr/workspace-watcher.sh' >/dev/null
notify-send -t 1500 "Workspace watcher" "Reloaded" 2>/dev/null || true
