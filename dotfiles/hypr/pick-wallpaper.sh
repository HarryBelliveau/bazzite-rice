#!/usr/bin/env bash
# Terminal wallpaper picker. Opens fzf with previews and applies the selection
# via cycle-wallpaper.sh. Designed to be launched from Hyprland (e.g. SUPER+W)
# so it spawns its own kitty window. Videos get an on-demand cached thumbnail
# (first hover extracts a frame with ffmpeg; subsequent hovers reuse it).
# TAB inside the picker cycles the filter mode: all -> images -> videos -> all.
#
# Usage:
#   pick-wallpaper.sh                  # spawn a kitty window running the picker
#   pick-wallpaper.sh --inner [MON]    # the actual fzf loop (run inside kitty)
#   pick-wallpaper.sh --preview REL    # render a single preview row (for fzf)
#   pick-wallpaper.sh --list STATE     # emit filter-mode-filtered relpaths
#   pick-wallpaper.sh --rotate STATE   # advance the filter mode in STATE file
#   pick-wallpaper.sh --prompt STATE   # emit prompt string for current mode

set -euo pipefail

SCRIPT_REAL="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_REAL")"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WALL_DIR="${WALLPAPER_DIR:-$REPO_ROOT/wallpapers}"
CYCLE="$SCRIPT_DIR/cycle-wallpaper.sh"
THUMB_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-picker/thumbs"

# Section dividers used in the "all" view. They start with a marker that no
# real filename can begin with, so the selection handler can skip them.
IMG_HEADER='── images ──'
VID_HEADER='── videos ──'

# Find files matching the given find-test args, sorted, under WALL_DIR.
_find_files() {
    find "$WALL_DIR" \
        \( -type d -name '__MACOSX' \) -prune -o \
        -type f ! -name '._*' \( "$@" \) \
        -print | LC_ALL=C sort
}

# Emit absolute wallpaper paths (with optional dividers) filtered by mode.
# Gifs live in the "videos" bucket since they're animated.
find_walls() {
    local mode="$1"
    local img_p=( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg'
                  -o -iname '*.webp' -o -iname '*.jxl' )
    local vid_p=( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv'
                  -o -iname '*.mov' -o -iname '*.gif' )
    case "$mode" in
        images) _find_files "${img_p[@]}" ;;
        videos) _find_files "${vid_p[@]}" ;;
        *)
            local imgs vids
            imgs=$(_find_files "${img_p[@]}")
            vids=$(_find_files "${vid_p[@]}")
            if [[ -n "$imgs" ]]; then
                printf '%s\n' "$IMG_HEADER"
                printf '%s\n' "$imgs"
            fi
            if [[ -n "$vids" ]]; then
                printf '%s\n' "$VID_HEADER"
                printf '%s\n' "$vids"
            fi
            ;;
    esac
}

# Mode-state helpers driven by a small state file. fzf's TAB bind rotates the
# mode and reloads the list / prompt.
read_mode() {
    local v
    v=$(cat "$1" 2>/dev/null) || v=""
    case "$v" in images|videos|all) echo "$v" ;; *) echo all ;; esac
}

mode_prompt() {
    case "$1" in
        images) printf 'images> ' ;;
        videos) printf 'videos> ' ;;
        *)      printf 'all> ' ;;
    esac
}

if [[ "${1:-}" == "--list" ]]; then
    mode=$(read_mode "${2:-}")
    while IFS= read -r p; do
        if [[ "$p" == "$WALL_DIR"/* ]]; then
            printf '%s\n' "${p#"$WALL_DIR"/}"
        else
            # Divider line; pass through unmodified.
            printf '%s\n' "$p"
        fi
    done < <(find_walls "$mode")
    exit 0
fi

if [[ "${1:-}" == "--rotate" ]]; then
    state="${2:-}"
    cur=$(read_mode "$state")
    case "$cur" in
        all)    next=images ;;
        images) next=videos ;;
        videos) next=all ;;
    esac
    printf '%s\n' "$next" > "$state"
    exit 0
fi

if [[ "${1:-}" == "--prompt" ]]; then
    mode_prompt "$(read_mode "${2:-}")"
    exit 0
fi

# fzf invokes this once per highlighted row to render the right-side preview.
# For videos we extract a frame to a cache (keyed by absolute path + mtime) so
# the second hover is instant.
if [[ "${1:-}" == "--preview" ]]; then
    rel="${2:-}"
    src="$WALL_DIR/$rel"
    # Section dividers and missing files: print a hint and exit cleanly.
    if [[ ! -f "$src" ]]; then
        printf '\n  (section divider -- press TAB to filter, or pick a file)\n'
        exit 0
    fi
    case "${src,,}" in
        *.mp4|*.webm|*.mkv|*.mov)
            mkdir -p "$THUMB_DIR"
            mtime=$(stat -c %Y "$src" 2>/dev/null || echo 0)
            key=$(printf '%s\0%s' "$src" "$mtime" | sha1sum | cut -d' ' -f1)
            thumb="$THUMB_DIR/$key.jpg"
            if [[ ! -s "$thumb" ]]; then
                # Grab a frame ~10% into the clip, scaled to 1280px wide.
                dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src" 2>/dev/null || true)
                ts=$(awk -v d="${dur:-10}" 'BEGIN { printf "%.2f", (d > 0 ? d * 0.1 : 1) }')
                ffmpeg -hide_banner -loglevel error -ss "$ts" -i "$src" \
                    -frames:v 1 -vf 'scale=1280:-1' -q:v 4 "$thumb" \
                    </dev/null >/dev/null 2>&1 || true
            fi
            [[ -s "$thumb" ]] && src="$thumb"
            ;;
    esac
    exec kitten icat --clear --transfer-mode=memory --unicode-placeholder \
        --stdin=no --place="${FZF_PREVIEW_COLUMNS:-80}x${FZF_PREVIEW_LINES:-24}@0x0" \
        -- "$src"
fi

# Re-launch ourselves inside a kitty window for the actual UI.
if [[ "${1:-}" != "--inner" ]]; then
    exec kitty \
        --class=wallpaper-picker \
        --title="Wallpaper Picker" \
        -o initial_window_width=120c \
        -o initial_window_height=32c \
        -- "$SCRIPT_REAL" --inner "${1:-}"
fi

shift
target_mon="${1:-}"

# Per-run state file holds the current filter mode (all/images/videos). fzf's
# TAB bind mutates it then triggers reload+prompt refresh.
state_file=$(mktemp -t wallpaper-picker-mode.XXXXXX)
printf 'all\n' > "$state_file"
trap 'rm -f "$state_file"' EXIT

# Bail early if there's nothing to show at all.
if [[ -z "$(find_walls all)" ]]; then
    echo "no wallpapers in $WALL_DIR" >&2
    sleep 2
    exit 1
fi

header="TAB: filter (all/images/videos)   ENTER: span across monitors   ALT-1: DP-1   ALT-2: DP-2   ESC: cancel"
[[ -n "$target_mon" ]] && header="TAB: filter (all/images/videos)   ENTER: apply to $target_mon   ESC: cancel"

script_q="$(printf '%q' "$SCRIPT_REAL")"
state_q="$(printf '%q' "$state_file")"
list_cmd="$script_q --list $state_q"
rotate_cmd="$script_q --rotate $state_q"
prompt_cmd="$script_q --prompt $state_q"
# Each preview row delegates to `$SCRIPT_REAL --preview <rel>`, which handles
# both images (passed straight to kitten icat) and videos (lazy ffmpeg thumb).
preview_cmd="$script_q --preview {}"

selection=$(eval "$list_cmd" | fzf \
    --prompt="$(eval "$prompt_cmd")" \
    --header="$header" \
    --preview="$preview_cmd" \
    --preview-window='right,60%,border-left' \
    --expect=alt-1,alt-2 \
    --bind="tab:execute-silent($rotate_cmd)+reload($list_cmd)+transform-prompt($prompt_cmd)" \
    --reverse \
    --no-mouse) || exit 0

key="$(printf '%s\n' "$selection" | sed -n '1p')"
pick="$(printf '%s\n' "$selection" | sed -n '2p')"
[[ -z "$pick" ]] && exit 0
# Picking a section divider is a no-op.
[[ "$pick" == "$IMG_HEADER" || "$pick" == "$VID_HEADER" ]] && exit 0

abs="$WALL_DIR/$pick"

# Videos (and animated GIFs) take a moment to start: ffprobe, mpvpaper spawn,
# IPC sync wait. Detach so the picker window closes immediately on pick.
case "${abs,,}" in
    *.mp4|*.webm|*.mkv|*.mov|*.gif) is_vid=1 ;;
    *) is_vid=0 ;;
esac

run_cycle() {
    if (( is_vid )); then
        setsid "$CYCLE" "$@" >/dev/null 2>&1 < /dev/null &
        disown
    else
        "$CYCLE" "$@"
    fi
}

case "$key" in
    alt-1) run_cycle pick "$abs" DP-1 ;;
    alt-2) run_cycle pick "$abs" DP-2 ;;
    *)
        if [[ -n "$target_mon" ]]; then
            run_cycle pick "$abs" "$target_mon"
        else
            run_cycle span "$abs"
        fi
        ;;
esac
