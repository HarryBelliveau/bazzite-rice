#!/usr/bin/env bash
# Launch the apps marked `on` in startup-apps.conf.
# Invoked from hyprland.conf as `exec-once`.
set -u

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/startup-apps.conf"
[[ -r "$CONF" ]] || exit 0

while IFS='|' read -r state name cmd rest; do
    [[ -z "${state:-}" ]] && continue
    [[ "${state:0:1}" == "#" ]] && continue
    [[ "$state" == "on" ]] || continue
    [[ -n "${name:-}" && -n "${cmd:-}" ]] || continue

    # Don't double-launch if something matching is already running.
    if pgrep -if -- "$name" >/dev/null 2>&1; then
        continue
    fi

    setsid sh -c "$cmd" </dev/null >/dev/null 2>&1 &
done < "$CONF"
