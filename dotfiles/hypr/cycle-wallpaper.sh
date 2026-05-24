#!/usr/bin/env bash
# Cycle through wallpapers in <repo>/wallpapers and apply them per monitor.
#   - Images (.png .jpg .jpeg .webp .jxl .gif)  -> swww
#   - Videos (.mp4 .webm .mkv .mov)             -> mpvpaper (live wallpaper)
# Each monitor has its own index, so DP-1 and DP-3 cycle independently.
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
        # GIFs route through mpvpaper too: when spanning, swww's per-monitor
        # animation workers run on independent clocks and drift out of sync,
        # while parallel mpv processes started together stay frame-aligned.
        *.gif) return 0 ;;
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

# Wait (up to ~2.5s) for an mpv IPC socket to appear. mpv only creates the
# socket once it's loaded the file and decoded the first frame, so this is
# our signal that mpvpaper is parked on frame 0 and the surface holds it.
_wait_for_mpv_socket() {
    local sock="$1" i
    for ((i = 0; i < 50; i++)); do
        [[ -S "$sock" ]] && return 0
        sleep 0.05
    done
    return 1
}

# Send `set_property pause false` over mpv's JSON IPC socket via python3
# (we have no socat/ncat on this system). Best-effort — failures are silent.
_mpv_unpause() {
    local sock="$1"
    [[ -S "$sock" ]] || return 1
    python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(b"{\"command\":[\"set_property\",\"pause\",false]}\n")
' "$sock" >/dev/null 2>&1
}

# Extract (and cache) the first frame of a video file. Echoes the cache path
# on success; nothing on failure. Used to play a swww transition before
# mpvpaper claims the surface so videos don't pop in cold.
_extract_video_frame() {
    local wall="$1"
    command -v ffmpeg >/dev/null || return 1
    local fdir="$STATE_DIR/video-frames"
    mkdir -p "$fdir"
    local mtime
    mtime=$(stat -c %Y "$wall" 2>/dev/null || echo 0)
    local key
    key=$(printf '%s\0%s' "$wall" "$mtime" | sha1sum | cut -d' ' -f1)
    local frame_file="$fdir/${key}.png"
    if [[ ! -s "$frame_file" ]]; then
        ffmpeg -hide_banner -loglevel error -y -i "$wall" -frames:v 1 \
            "$frame_file" </dev/null >/dev/null 2>&1 || return 1
    fi
    [[ -s "$frame_file" ]] && printf '%s\n' "$frame_file"
}

apply_video() {
    local mon="$1" wall="$2"
    if ! command -v mpvpaper >/dev/null; then
        notify-send -u normal "Wallpaper" \
            "mpvpaper not installed -- can't play $(basename "$wall")" \
            2>/dev/null || true
        return
    fi
    ensure_swww_running

    # 1. Start the swww fade to the still first frame. Fit-with-black-fill so
    #    the still frame is letterboxed exactly like mpv will render the live
    #    video — otherwise swww's default crop-to-fill leaves a zoom-cropped
    #    frame visible through the video's letterbox bars during playback.
    local frame has_frame=0
    frame=$(_extract_video_frame "$wall")
    stop_mpvpaper_for "$mon"
    if [[ -n "$frame" ]]; then
        swww img --outputs "$mon" \
            --resize fit --fill-color 000000 \
            --transition-type any --transition-fps 60 --transition-duration 1 \
            "$frame" >/dev/null
        has_frame=1
    fi

    # 2. Spawn mpvpaper paused IN PARALLEL with the fade so mpv decodes the
    #    first frame while swww is still animating. No swww clear here — it
    #    would wipe the still frame mid-transition and cause a black flash.
    local ipc_dir="$STATE_DIR/mpvpaper-ipc"
    mkdir -p "$ipc_dir"
    local sock="$ipc_dir/${mon}.sock"
    rm -f "$sock"
    setsid mpvpaper \
        -o "no-audio loop-file=inf hwdec=auto pause input-ipc-server=${sock}" \
        "$mon" "$wall" >/dev/null 2>&1 < /dev/null &
    echo "$!" > "$STATE_DIR/mpvpaper-$mon.pid"

    # 3. Wait for the transition to finish AND mpv to be parked on frame 0,
    #    then unpause. mpv's first frame matches the still swww just landed
    #    on, so the surface handoff is invisible.
    (( has_frame )) && sleep 1
    _wait_for_mpv_socket "$sock"
    _mpv_unpause "$sock"
}

apply_wallpaper() {
    local mon="$1" wall="$2"
    if is_video "$wall"; then
        apply_video "$mon" "$wall"
    else
        apply_image "$mon" "$wall"
    fi
}

# Compute the spanned-wallpaper layout given a source's pixel dimensions.
# Emits one MON line per monitor and one IMG line at the end (tab-separated):
#   MON  name  native_w  native_h  mlw  mlh  crop_x  crop_y
#   IMG  img_w  img_h  img_left  img_top  layout_hash
# crop_x/crop_y are the monitor's offset into the scaled image; img_left
# and img_top are the scaled image's compositor-coord position. The layout
# hash fingerprints monitor positions/sizes/transforms for cache keying.
#
# Strategy: anchor the image on the LARGEST monitor's center and scale
# (preserving source aspect) until it reaches the farthest monitor edge in
# both axes. Result: no black fill, no duplicate-looking content near the
# seam, main subject lands on the primary monitor.
_span_layout() {
    local src_w="$1" src_h="$2"

    # name native_w native_h sx sy lw lh (logical post-transform/post-scale)
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
    [[ -z "$layout" ]] && return 1

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

    local lcx=$(( sxs[largest] + lws[largest] / 2 ))
    local lcy=$(( sys[largest] + lhs[largest] / 2 ))

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

    for ((i = 0; i < n; i++)); do
        local cx=$(( sxs[i] - img_left ))
        local cy=$(( sys[i] - img_top ))
        printf 'MON\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${names[i]}" "${nws[i]}" "${nhs[i]}" "${lws[i]}" "${lhs[i]}" "$cx" "$cy"
    done
    local layout_hash
    layout_hash=$(printf '%s' "$layout" | sha1sum | cut -d' ' -f1)
    printf 'IMG\t%s\t%s\t%s\t%s\t%s\n' "$img_w" "$img_h" "$img_left" "$img_top" "$layout_hash"
}

# Apply a still or animated image spanned across all monitors. Per-monitor
# slices are cropped from the SOURCE coordinates (not from a pre-upscaled
# canvas), so a small gif doesn't get scaled up 10× just to be cut. Animated
# GIFs are coalesced and re-emitted as multi-frame GIFs so swww plays them.
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

    local is_animated=0 out_ext=png
    [[ "${wall,,}" == *.gif ]] && { is_animated=1; out_ext=gif; }

    local layout
    layout=$(_span_layout "$src_w" "$src_h") || return 1

    local img_w img_h img_left img_top layout_hash
    read -r _ img_w img_h img_left img_top layout_hash < <(printf '%s\n' "$layout" | awk '$1 == "IMG"')

    local cache_dir="$STATE_DIR/spanned-cache"
    mkdir -p "$cache_dir"
    local mtime
    mtime=$(stat -c %Y "$wall" 2>/dev/null || echo 0)
    local key
    key=$(printf '%s\0%s\0%s\0%dx%d@%d,%d' \
            "$wall" "$mtime" "$layout_hash" "$img_w" "$img_h" "$img_left" "$img_top" \
          | sha1sum | cut -d' ' -f1)

    ensure_swww_running

    local _tag mon mnw mnh mlw mlh crop_x crop_y
    while IFS=$'\t' read -r _tag mon mnw mnh mlw mlh crop_x crop_y; do
        [[ "$_tag" != "MON" ]] && continue
        local crop_file="$cache_dir/${key}-${mon}.${out_ext}"
        if [[ ! -s "$crop_file" ]]; then
            # Translate the per-monitor slice from scaled-image pixels into
            # source pixels (aspect preserved, so the width ratio suffices).
            local scrop_x=$(( crop_x * src_w / img_w ))
            local scrop_y=$(( crop_y * src_w / img_w ))
            local scrop_w=$(( mlw    * src_w / img_w ))
            local scrop_h=$(( mlh    * src_w / img_w ))
            (( scrop_x < 0 )) && scrop_x=0
            (( scrop_y < 0 )) && scrop_y=0
            (( scrop_x + scrop_w > src_w )) && scrop_w=$(( src_w - scrop_x ))
            (( scrop_y + scrop_h > src_h )) && scrop_h=$(( src_h - scrop_y ))

            if (( is_animated )); then
                # Don't upscale each frame to native pixels — that bloats the
                # cached GIF wildly (a 498px source × 44 frames upscaled to
                # 2560×1440 = ~40 MB). Ship the source-sized slice; swww
                # scales to the monitor on playback.
                "$im_cmd" "$wall" -coalesce \
                    -crop "${scrop_w}x${scrop_h}+${scrop_x}+${scrop_y}" +repage \
                    "$crop_file"
            else
                "$im_cmd" "$wall" \
                    -crop "${scrop_w}x${scrop_h}+${scrop_x}+${scrop_y}" +repage \
                    -resize "${mnw}x${mnh}!" \
                    "$crop_file"
            fi
        fi

        stop_mpvpaper_for "$mon"
        swww img --outputs "$mon" \
            --transition-type any --transition-fps 60 --transition-duration 1 \
            "$crop_file" >/dev/null

        local state_file="$STATE_DIR/wallpaper-index-$mon"
        local j
        for j in "${!walls[@]}"; do
            [[ "${walls[$j]}" == "$wall" ]] && { echo "$j" > "$state_file"; break; }
        done
    done <<< "$layout"
}

# Apply a video (or animated GIF) spanned across all monitors via mpvpaper.
# mpv crops on the GPU during playback (no pre-encoding); a synchronized
# launch pattern keeps animations frame-aligned across monitors:
#
#   1. Spawn every mpvpaper instance with `pause` + `input-ipc-server=…`
#      so each mpv decodes and seeks to frame 0 but holds, hiding the
#      per-process startup variance.
#   2. Wait for every IPC socket to appear (mpv has finished its prep).
#   3. Fire `pause false` at all sockets in parallel so they begin playing
#      within one kernel-scheduling slice of each other.
#
# Per-monitor crop is computed in the spanning layout's scaled-image coords
# then mapped back into source-video pixel coords for mpv's `crop` filter.
apply_spanned_video() {
    local wall="$1"
    if ! command -v mpvpaper >/dev/null; then
        notify-send -u normal "Wallpaper" \
            "mpvpaper not installed -- can't play $(basename "$wall")" \
            2>/dev/null || true
        return 1
    fi
    if ! command -v ffprobe >/dev/null; then
        notify-send -u normal "Wallpaper" \
            "ffprobe required to span videos" 2>/dev/null || true
        return 1
    fi

    local src_w src_h
    IFS=, read -r src_w src_h < <(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height -of csv=p=0 "$wall" 2>/dev/null)
    if [[ -z "$src_w" || -z "$src_h" ]]; then
        echo "couldn't read dimensions of $wall" >&2
        return 1
    fi

    local layout
    layout=$(_span_layout "$src_w" "$src_h") || return 1

    local img_w img_h img_left img_top _hash
    read -r _ img_w img_h img_left img_top _hash < <(printf '%s\n' "$layout" | awk '$1 == "IMG"')

    ensure_swww_running

    # 1. Play the swww fade into a still first frame across every monitor.
    #    apply_spanned_image already stops any running mpvpaper per output
    #    and writes the per-monitor crops with the same layout math, so the
    #    still frame and the live video align exactly.
    local frame has_frame=0
    frame=$(_extract_video_frame "$wall")
    if [[ -n "$frame" ]]; then
        apply_spanned_image "$frame"
        has_frame=1
    fi

    # 2. Spawn every mpvpaper paused IN PARALLEL with the swww fade so mpv
    #    has a full second to load + decode the first frame. No per-monitor
    #    swww clear here — that would wipe the still mid-transition.
    local ipc_dir="$STATE_DIR/mpvpaper-ipc"
    mkdir -p "$ipc_dir"
    local -a mons sockets
    local _tag mon mnw mnh mlw mlh crop_x crop_y
    while IFS=$'\t' read -r _tag mon mnw mnh mlw mlh crop_x crop_y; do
        [[ "$_tag" != "MON" ]] && continue

        local vcrop_x=$(( crop_x * src_w / img_w ))
        local vcrop_y=$(( crop_y * src_w / img_w ))
        local vcrop_w=$(( mlw    * src_w / img_w ))
        local vcrop_h=$(( mlh    * src_w / img_w ))
        (( vcrop_x < 0 )) && vcrop_x=0
        (( vcrop_y < 0 )) && vcrop_y=0
        (( vcrop_x + vcrop_w > src_w )) && vcrop_w=$(( src_w - vcrop_x ))
        (( vcrop_y + vcrop_h > src_h )) && vcrop_h=$(( src_h - vcrop_y ))

        local sock="$ipc_dir/${mon}.sock"
        # apply_spanned_image already stopped mpvpaper for this monitor.
        rm -f "$sock"
        setsid mpvpaper \
            -o "no-audio loop-file=inf hwdec=auto pause input-ipc-server=${sock} vf=crop=${vcrop_w}:${vcrop_h}:${vcrop_x}:${vcrop_y}" \
            "$mon" "$wall" >/dev/null 2>&1 < /dev/null &
        echo "$!" > "$STATE_DIR/mpvpaper-$mon.pid"
        mons+=("$mon")
        sockets+=("$sock")

        local state_file="$STATE_DIR/wallpaper-index-$mon"
        local j
        for j in "${!walls[@]}"; do
            [[ "${walls[$j]}" == "$wall" ]] && { echo "$j" > "$state_file"; break; }
        done
    done <<< "$layout"

    # 3. Wait out the rest of the swww fade, then confirm every mpv is
    #    parked on its first frame. By now mpv has been preparing for ~1s,
    #    so the socket-wait is usually a no-op.
    (( has_frame )) && sleep 1
    local s
    for s in "${sockets[@]}"; do
        _wait_for_mpv_socket "$s"
    done

    # 4. Unpause every instance in parallel — start-of-playback offset
    #    between monitors becomes one OS context-switch, not one mpv start.
    for s in "${sockets[@]}"; do
        _mpv_unpause "$s" &
    done
    wait
}

action="${1:-next}"

if [[ "$action" == "span" ]]; then
    span_path="${2:-}"
    [[ -z "$span_path" ]] && { echo "span requires a path" >&2; exit 2; }
    if is_video "$span_path"; then
        apply_spanned_video "$span_path"
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
