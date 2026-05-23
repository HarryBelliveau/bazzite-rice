#!/usr/bin/env bash
# Cycle through wallpapers in <repo>/wallpapers and apply them per monitor.
#   - Images (.png .jpg .jpeg .webp .jxl .gif)  -> swww
#   - Videos (.mp4 .webm .mkv .mov)             -> mpvpaper (live wallpaper)
# Each monitor has its own index, so DP-1 and DP-2 cycle independently.
#
# Note: animated gifs are treated as images and animate fine in swww. Only
# real video containers go through mpvpaper.
#
# Usage:
#   cycle-wallpaper.sh                    # advance every monitor
#   cycle-wallpaper.sh next [MONITOR]
#   cycle-wallpaper.sh prev [MONITOR]
#   cycle-wallpaper.sh init               # re-apply each monitor's saved wallpaper
#   cycle-wallpaper.sh pick PATH [MON]    # set a specific wallpaper

set -euo pipefail

SCRIPT_REAL="$(readlink -f "$0")"
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/../.." && pwd)"
WALL_DIR="${WALLPAPER_DIR:-$REPO_ROOT/wallpapers}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"

mkdir -p "$STATE_DIR"

mapfile -d '' -t walls < <(
    find "$WALL_DIR" \
        \( -type d -name '__MACOSX' \) -prune -o \
        -type f ! -name '._*' \
        \( -iname '*.png'  -o -iname '*.jpg' -o -iname '*.jpeg' \
        -o -iname '*.webp' -o -iname '*.jxl' -o -iname '*.gif' \
        -o -iname '*.mp4'  -o -iname '*.webm' -o -iname '*.mkv' \
        -o -iname '*.mov' \) \
        -print0 | sort -z
)

if (( ${#walls[@]} == 0 )); then
    notify-send -u critical "Wallpaper" "No images/videos in $WALL_DIR" 2>/dev/null || true
    echo "no wallpapers found in $WALL_DIR" >&2
    exit 1
fi

is_video() {
    case "${1,,}" in
        *.mp4|*.webm|*.mkv|*.mov) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_swww_running() {
    pgrep -x swww-daemon >/dev/null && return
    setsid swww-daemon >/dev/null 2>&1 < /dev/null &
    # Wait until daemon's socket is ready (swww commands hang otherwise).
    for _ in {1..20}; do
        swww query >/dev/null 2>&1 && return
        sleep 0.1
    done
}

stop_mpvpaper_for() {
    local mon="$1"
    local pidfile="$STATE_DIR/mpvpaper-$mon.pid"
    if [[ -f "$pidfile" ]]; then
        local pid; pid=$(<"$pidfile")
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        rm -f "$pidfile"
    fi
    pkill -f "mpvpaper.* $mon " 2>/dev/null || true
}

apply_image() {
    local mon="$1" wall="$2"
    stop_mpvpaper_for "$mon"
    ensure_swww_running
    # Subtle fade between wallpapers. Tweak to taste.
    swww img --outputs "$mon" \
        --transition-type any --transition-fps 60 --transition-duration 1 \
        "$wall" >/dev/null
}

apply_video() {
    local mon="$1" wall="$2"
    if ! command -v mpvpaper >/dev/null; then
        notify-send -u normal "Wallpaper" \
            "mpvpaper not installed -- can't play $(basename "$wall")" \
            2>/dev/null || true
        return
    fi
    stop_mpvpaper_for "$mon"
    # Release this monitor from swww so mpvpaper can claim the surface cleanly.
    ensure_swww_running
    swww clear --outputs "$mon" 000000 >/dev/null 2>&1 || true
    setsid mpvpaper -o "no-audio loop-file=inf hwdec=auto" "$mon" "$wall" \
        >/dev/null 2>&1 < /dev/null &
    echo "$!" > "$STATE_DIR/mpvpaper-$mon.pid"
}

apply_wallpaper() {
    local mon="$1" wall="$2"
    if is_video "$wall"; then
        apply_video "$mon" "$wall"
    else
        apply_image "$mon" "$wall"
    fi
}

action="${1:-next}"

if [[ "$action" == "pick" ]]; then
    pick_path="${2:-}"; pick_mon="${3:-}"
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
        apply_wallpaper "$mon" "$pick_path"
    done
    notify-send -t 2000 "Wallpaper" "$(basename "$pick_path") on ${monitors[*]}" 2>/dev/null || true
    exit 0
fi

mon_arg="${2:-}"
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
        *) echo "unknown action: $action" >&2; exit 2 ;;
    esac

    local wall="${walls[$idx]}"
    echo "$idx" > "$state_file"
    apply_wallpaper "$mon" "$wall"
    echo "$mon -> $(basename "$wall") ($((idx + 1))/${#walls[@]})"
}

results=()
for mon in "${monitors[@]}"; do
    results+=("$(apply_to_monitor "$mon")")
done

notify-send -t 2000 "Wallpaper" "$(printf '%s\n' "${results[@]}")" 2>/dev/null || true
