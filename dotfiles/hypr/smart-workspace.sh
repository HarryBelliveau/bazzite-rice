#!/usr/bin/env bash
# smart-workspace.sh <workspace-id>
#
# If the workspace isn't currently displayed by any monitor (i.e. it has no
# windows and isn't being shown), bring it up on the focused monitor instead
# of wherever it happened to live last. Otherwise, fall back to the normal
# `workspace` dispatcher (which jumps focus to the monitor showing it).
set -u

ws="${1:?workspace id required}"

# Currently-visible workspaces (one per monitor).
visible=$(hyprctl monitors -j | jq -r '.[].activeWorkspace.id')
for v in $visible; do
    if [[ "$v" == "$ws" ]]; then
        # Already on screen somewhere — just focus it normally.
        exec hyprctl dispatch workspace "$ws"
    fi
done

# Not visible anywhere: open it on the currently focused monitor.
# focusworkspaceoncurrentmonitor will move the workspace here if it exists
# elsewhere with hidden windows, or create it here if it doesn't exist.
exec hyprctl dispatch focusworkspaceoncurrentmonitor "$ws"
