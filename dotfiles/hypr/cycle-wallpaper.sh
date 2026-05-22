#!/usr/bin/env bash
# Cycle through wallpapers in <repo>/wallpapers and apply via hyprpaper IPC.
# Each monitor has its own index, so DP-1 and DP-2 can be on different walls.
#
# Usage:
#   cycle-wallpaper.sh                    # advance every monitor
#   cycle-wallpaper.sh next [MONITOR]     # advance one monitor (or all)
#   cycle-wallpaper.sh prev [MONITOR]     # back one
#   cycle-wallpaper.sh init               # re-apply each monitor's saved wallpaper
#   cycle-wallpaper.sh pick PATH [MON]    # set a specific wallpaper, remember it
#
# State per monitor is at $XDG_STATE_HOME/hypr/wallpaper-index-<MON>.

set -euo pipefail

# Resolve the script's real location (it's symlinked into ~/.config/hypr/ by
# dotfiles/install.sh) and locate the sibling wallpapers/ folder inside the
# repo. Lets the repo live anywhere -- no hardcoded path.
SCRIPT_REAL="$(readlink -f "$0")"
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/../.." && pwd)"
WALL_DIR="${WALLPAPER_DIR:-$REPO_ROOT/wallpapers}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"

mkdir -p "$STATE_DIR"

mapfile -d '' -t walls < <(
    find "$WALL_DIR" -maxdepth 1 -type f \
        \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
        -o -iname '*.webp' -o -iname '*.jxl' \) \
        -print0 | sort -z
)

if (( ${#walls[@]} == 0 )); then
    notify-send -u critical "Wallpaper" "No images in $WALL_DIR" 2>/dev/null || true
    echo "no wallpapers found in $WALL_DIR" >&2
    exit 1
fi

action="${1:-next}"
mon_arg="${2:-}"

# Build the monitor list to act on.
if [[ -n "$mon_arg" ]]; then
    monitors=("$mon_arg")
else
    mapfile -t monitors < <(hyprctl monitors -j | jq -r '.[].name')
fi

apply_to_monitor() {
    local mon="$1"
    local state_file="$STATE_DIR/wallpaper-index-$mon"

    local idx=0
    [[ -f "$state_file" ]] && idx=$(<"$state_file")
    (( idx < 0 || idx >= ${#walls[@]} )) && idx=0

    case "$action" in
        next) idx=$(( (idx + 1) % ${#walls[@]} )) ;;
        prev) idx=$(( (idx - 1 + ${#walls[@]}) % ${#walls[@]} )) ;;
        init|current) : ;;
        pick)
            local target="$mon_arg"
            # 'pick' uses arg2 as the path, not the monitor; rebuild monitor list.
            target="${2:-}"
            [[ -z "$target" ]] && { echo "pick requires a path" >&2; exit 2; }
            for i in "${!walls[@]}"; do
                [[ "${walls[$i]}" == "$target" ]] && { idx=$i; break; }
            done
            ;;
        *) echo "unknown action: $action" >&2; exit 2 ;;
    esac

    local wall="${walls[$idx]}"
    echo "$idx" > "$state_file"
    hyprctl hyprpaper wallpaper "${mon},${wall}" >/dev/null
    echo "$mon -> $(basename "$wall") ($((idx + 1))/${#walls[@]})"
}

# Special-case 'pick': arg2 is the path, arg3 (optional) is the monitor.
if [[ "$action" == "pick" ]]; then
    pick_path="${2:-}"
    pick_mon="${3:-}"
    [[ -z "$pick_path" ]] && { echo "pick requires a path" >&2; exit 2; }
    if [[ -n "$pick_mon" ]]; then
        monitors=("$pick_mon")
    else
        mapfile -t monitors < <(hyprctl monitors -j | jq -r '.[].name')
    fi
    for mon in "${monitors[@]}"; do
        state_file="$STATE_DIR/wallpaper-index-$mon"
        for i in "${!walls[@]}"; do
            [[ "${walls[$i]}" == "$pick_path" ]] && { echo "$i" > "$state_file"; break; }
        done
        hyprctl hyprpaper wallpaper "${mon},${pick_path}" >/dev/null
    done
    notify-send -t 2000 "Wallpaper" "$(basename "$pick_path") on ${monitors[*]}" 2>/dev/null || true
    exit 0
fi

results=()
for mon in "${monitors[@]}"; do
    results+=("$(apply_to_monitor "$mon")")
done

notify-send -t 2000 "Wallpaper" "$(printf '%s\n' "${results[@]}")" 2>/dev/null || true
