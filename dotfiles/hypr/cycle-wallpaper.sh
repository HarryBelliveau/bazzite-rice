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
#   cycle-wallpaper.sh span PATH          # stretch one image across all monitors

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

# Stretch one image across the union of all monitors so it reads as one
# cohesive picture: scale the source (preserving aspect) so that when it's
# centered on the LARGEST monitor it still reaches the far edge of every
# other monitor, then per monitor crop out its slice and resample to native
# pixel buffer. No black fill, no apparent duplication near the seam, and
# the main subject sits prominently on the largest monitor.
# Respects Wayland transforms so rotated panels (transform 1/3/5/7) get a
# portrait-oriented slice.
apply_spanned_image() {
    local wall="$1"
    local im_cmd
    if command -v magick >/dev/null; then
        im_cmd=magick
    elif command -v convert >/dev/null; then
        im_cmd=convert
    else
        notify-send -u critical "Wallpaper" \
            "ImageMagick required for spanned wallpapers" 2>/dev/null || true
        echo "ImageMagick (magick/convert) not found" >&2
        return 1
    fi

    local src_w src_h
    read -r src_w src_h < <(identify -format '%w %h\n' "$wall" 2>/dev/null | head -1)
    if [[ -z "$src_w" || -z "$src_h" ]]; then
        echo "couldn't read dimensions of $wall" >&2
        return 1
    fi

    # Per-monitor layout. Each tab-separated line:
    #   name  native_w  native_h  sx  sy  lw  lh
    # native_* is the pixel buffer size swww writes (post-transform);
    # sx,sy is the monitor's top-left in compositor coords;
    # lw,lh is the monitor's logical (post-transform, post-scale) size.
    local layout
    layout=$(hyprctl monitors -j | jq -r '
        def lw: if (.transform % 2) == 1 then .height else .width  end;
        def lh: if (.transform % 2) == 1 then .width  else .height end;
        .[] |
        [ .name, lw, lh, .x, .y,
          (lw / .scale | round),
          (lh / .scale | round)
        ] | @tsv
    ')
    if [[ -z "$layout" ]]; then
        echo "no monitors detected" >&2
        return 1
    fi

    local -a names nws nhs sxs sys lws lhs
    local n=0 largest=0 largest_area=0
    local name nw nh sx sy lw lh
    while IFS=$'\t' read -r name nw nh sx sy lw lh; do
        [[ -z "$name" ]] && continue
        names+=("$name"); nws+=("$nw"); nhs+=("$nh")
        sxs+=("$sx");   sys+=("$sy");   lws+=("$lw"); lhs+=("$lh")
        local area=$(( lw * lh ))
        (( area > largest_area )) && { largest_area=$area; largest=$n; }
        n=$(( n + 1 ))
    done <<< "$layout"

    # Anchor everything on the largest monitor's center (compositor coords).
    local lcx=$(( sxs[largest] + lws[largest] / 2 ))
    local lcy=$(( sys[largest] + lhs[largest] / 2 ))

    # Image must extend from the anchor outward to the farthest monitor edge
    # in each direction. The required image dimensions are 2× the max abs
    # offset from the anchor to any monitor corner. abs() via two-arg max.
    local max_hx=0 max_vy=0
    local i d
    for ((i = 0; i < n; i++)); do
        local ml=${sxs[i]} mt=${sys[i]}
        local mr=$(( ml + lws[i] )) mb=$(( mt + lhs[i] ))
        for d in $(( ml - lcx )) $(( mr - lcx )); do
            (( d < 0 )) && d=$(( -d ))
            (( d > max_hx )) && max_hx=$d
        done
        for d in $(( mt - lcy )) $(( mb - lcy )); do
            (( d < 0 )) && d=$(( -d ))
            (( d > max_vy )) && max_vy=$d
        done
    done
    local need_w=$(( max_hx * 2 )) need_h=$(( max_vy * 2 ))

    # Cover both required dimensions while preserving source aspect. Compare
    # ratios via cross-multiplication to avoid floating point.
    local img_w img_h
    if (( need_w * src_h >= need_h * src_w )); then
        img_w=$need_w
        img_h=$(( src_h * need_w / src_w ))
    else
        img_h=$need_h
        img_w=$(( src_w * need_h / src_h ))
    fi
    local img_left=$(( lcx - img_w / 2 ))
    local img_top=$(( lcy - img_h / 2 ))

    local cache_dir="$STATE_DIR/spanned-cache"
    mkdir -p "$cache_dir"
    local mtime
    mtime=$(stat -c %Y "$wall" 2>/dev/null || echo 0)
    local key
    key=$(printf '%s\0%s\0%s\0%dx%d@%d,%d' \
            "$wall" "$mtime" "$layout" "$img_w" "$img_h" "$img_left" "$img_top" \
          | sha1sum | cut -d' ' -f1)

    ensure_swww_running

    for ((i = 0; i < n; i++)); do
        local mon="${names[i]}"
        local mnw="${nws[i]}" mnh="${nhs[i]}"
        local msx="${sxs[i]}" msy="${sys[i]}"
        local mlw="${lws[i]}" mlh="${lhs[i]}"
        local crop_file="$cache_dir/${key}-${mon}.png"

        if [[ ! -s "$crop_file" ]]; then
            # By construction the scaled image fully covers every monitor;
            # crop straight out at the monitor's offset into the image.
            local crop_x=$(( msx - img_left ))
            local crop_y=$(( msy - img_top ))
            "$im_cmd" "$wall" -resize "${img_w}x${img_h}!" \
                -crop "${mlw}x${mlh}+${crop_x}+${crop_y}" +repage \
                -resize "${mnw}x${mnh}!" \
                "$crop_file"
        fi

        stop_mpvpaper_for "$mon"
        swww img --outputs "$mon" \
            --transition-type any --transition-fps 60 --transition-duration 1 \
            "$crop_file" >/dev/null

        # Keep cycle index aligned with the picked image.
        local state_file="$STATE_DIR/wallpaper-index-$mon"
        local j
        for j in "${!walls[@]}"; do
            [[ "${walls[$j]}" == "$wall" ]] && { echo "$j" > "$state_file"; break; }
        done
    done
}

action="${1:-next}"

if [[ "$action" == "span" ]]; then
    span_path="${2:-}"
    [[ -z "$span_path" ]] && { echo "span requires a path" >&2; exit 2; }
    if is_video "$span_path"; then
        notify-send -u normal "Wallpaper" \
            "Can't span videos — applying to each monitor" 2>/dev/null || true
        mapfile -t monitors < <(hyprctl monitors -j | jq -r '.[].name')
        for mon in "${monitors[@]}"; do
            state_file="$STATE_DIR/wallpaper-index-$mon"
            for i in "${!walls[@]}"; do
                [[ "${walls[$i]}" == "$span_path" ]] && { echo "$i" > "$state_file"; break; }
            done
            apply_wallpaper "$mon" "$span_path"
        done
    else
        apply_spanned_image "$span_path"
    fi
    notify-send -t 2000 "Wallpaper" "$(basename "$span_path") spanned across monitors" 2>/dev/null || true
    exit 0
fi

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
