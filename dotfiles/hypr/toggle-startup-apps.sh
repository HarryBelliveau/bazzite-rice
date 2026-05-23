#!/usr/bin/env bash
# Rofi menu to manage entries in startup-apps.conf.
# - The menu lists currently-enabled startup apps.
# - Selecting one removes it from the conf AND kills the running process.
# - Selecting "+ add new app..." opens a drun-style picker of installed apps
#   and appends the chosen one as a new `on` entry.
set -euo pipefail

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/startup-apps.conf"
[[ -r "$CONF" ]] || { notify-send "startup-apps" "config not found: $CONF" 2>/dev/null || true; exit 1; }

ADD_ENTRY="+ add new app..."

is_running() {
    pgrep -if -- "$1" >/dev/null 2>&1
}

rofi_menu() {
    rofi -dmenu -i -p "$1" -no-custom -show-icons \
        -theme-str 'window { width: 480px; } listview { lines: 10; }'
}

# Best-effort icon name for a conf entry. Falls back through:
#   1) flatpak appid pulled out of the cmd
#   2) the conf name treated as a desktop id
#   3) the basename of the first cmd token
#   4) the conf name itself (rofi will still try the icon theme)
resolve_icon() {
    local name="$1" cmd="$2" key first
    if [[ "$cmd" =~ flatpak[[:space:]]+run([[:space:]]+--[^[:space:]]+)*[[:space:]]+([^[:space:]]+) ]]; then
        key="${BASH_REMATCH[2],,}"
        [[ -n "${ICON_BY_ID[$key]:-}" ]] && { printf '%s' "${ICON_BY_ID[$key]}"; return; }
    fi
    key="${name,,}"
    [[ -n "${ICON_BY_ID[$key]:-}" ]] && { printf '%s' "${ICON_BY_ID[$key]}"; return; }
    first="${cmd%% *}"; first="${first##*/}"; first="${first,,}"
    [[ -n "${ICON_BY_ID[$first]:-}" ]] && { printf '%s' "${ICON_BY_ID[$first]}"; return; }
    printf '%s' "$name"
}

build_menu() {
    local icon
    while IFS='|' read -r state name cmd rest; do
        [[ -z "${state:-}" ]] && continue
        [[ "${state:0:1}" == "#" ]] && continue
        [[ "$state" == "on" ]] || continue
        [[ -n "${name:-}" && -n "${cmd:-}" ]] || continue

        if is_running "$name"; then
            status="running"
        else
            status="stopped"
        fi
        icon="$(resolve_icon "$name" "$cmd")"
        printf '%s  (%s)\x00icon\x1f%s\n' "$name" "$status" "$icon"
    done < "$CONF"
    printf '%s\x00icon\x1f%s\n' "$ADD_ENTRY" "list-add"
}

# Emit one "<id>\t<name>\t<exec>\t<icon>" line per installed .desktop file.
build_app_list() {
    local -A seen=()
    local dirs=(
        "$HOME/.local/share/applications"
        "$HOME/.local/share/flatpak/exports/share/applications"
        "/var/lib/flatpak/exports/share/applications"
        "/usr/local/share/applications"
        "/usr/share/applications"
    )
    local dir f id
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*.desktop; do
            [[ -r "$f" ]] || continue
            id="${f##*/}"; id="${id%.desktop}"
            [[ -n "${seen[$id]:-}" ]] && continue
            seen[$id]=1
            awk -v id="$id" '
                BEGIN { e=0 }
                /^\[Desktop Entry\][[:space:]]*$/ { e=1; next }
                /^\[/ { e=0; next }
                !e { next }
                /^Type=/      { type=substr($0,6) }
                /^Name=/      { if (name=="") name=substr($0,6) }
                /^Exec=/      { if (exec=="") exec=substr($0,6) }
                /^Icon=/      { if (icon=="") icon=substr($0,6) }
                /^NoDisplay=true/ { hide=1 }
                /^Hidden=true/    { hide=1 }
                END {
                    if (type=="Application" && !hide && exec!="" && name!="") {
                        gsub(/ ?%[UuFfick]/, "", exec)
                        sub(/[ \t]+$/, "", exec)
                        printf "%s\t%s\t%s\t%s\n", id, name, exec, icon
                    }
                }
            ' "$f"
        done
    done
}

add_new_app() {
    local apps idx line id name exec icon short
    apps="$(build_app_list | sort -f -t$'\t' -k2,2)"
    if [[ -z "$apps" ]]; then
        notify-send "startup-apps" "no applications found" 2>/dev/null || true
        return 1
    fi

    # Pipe awk -> rofi directly: bash command substitution strips NUL bytes,
    # and rofi's icon protocol requires "<display>\0icon\x1f<icon>\n".
    # -format 'i' returns the 0-based row index so apps that share a display
    # name (e.g. duplicate Flatpak runtimes) stay unambiguous.
    idx="$(awk -F'\t' '{ printf "%s\x00icon\x1f%s\n", $2, $4 }' <<<"$apps" \
        | rofi -dmenu -i -p "Apps" -show-icons -format 'i')" || return 0
    [[ -z "$idx" ]] && return 0

    line="$(awk -F'\t' -v i="$((idx+1))" 'NR==i' <<<"$apps")"
    [[ -z "$line" ]] && return 1
    IFS=$'\t' read -r id name exec icon <<<"$line"

    # Derive a short identifier that doubles as the pgrep pattern.
    # For "flatpak run <appid>" lines, prefer the appid (covers e.g.
    # com.spotify.Client -> matches the running process via pgrep -if).
    if [[ "$exec" =~ flatpak[[:space:]]+run([[:space:]]+--[^[:space:]]+)*[[:space:]]+([^[:space:]]+) ]]; then
        short="${BASH_REMATCH[2],,}"
    else
        short="${id,,}"
    fi

    if [[ ! "$short" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        notify-send "startup-apps" "invalid derived name: '$short'" 2>/dev/null || true
        return 1
    fi
    if [[ "$exec" == *"|"* ]]; then
        notify-send "startup-apps" "command contains '|', cannot store" 2>/dev/null || true
        return 1
    fi
    if awk -F'|' -v n="$short" '!/^#/ && $2==n {found=1} END{exit !found}' "$CONF"; then
        notify-send "startup-apps" "'$short' already in startup list" 2>/dev/null || true
        return 1
    fi

    printf 'on|%s|%s\n' "$short" "$exec" >> "$CONF"
    if ! is_running "$short"; then
        setsid sh -c "$exec" </dev/null >/dev/null 2>&1 &
    fi
    notify-send "startup-apps" "added & launched $short" 2>/dev/null || true
}

# Map of lowercase desktop-file id -> icon name, used by resolve_icon.
declare -A ICON_BY_ID=()
while IFS=$'\t' read -r _id _name _exec _icon; do
    [[ -z "$_icon" ]] && continue
    ICON_BY_ID["${_id,,}"]="$_icon"
done < <(build_app_list)

selection="$(build_menu | rofi_menu "startup apps")" || exit 0
[[ -z "$selection" ]] && exit 0

if [[ "$selection" == "$ADD_ENTRY" ]]; then
    add_new_app
    exit 0
fi

target="$(awk '{print $1}' <<<"$selection")"
[[ -z "$target" ]] && exit 1

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

removed=0
while IFS= read -r line; do
    if [[ -z "$line" || "${line:0:1}" == "#" ]]; then
        printf '%s\n' "$line" >> "$tmp"
        continue
    fi
    IFS='|' read -r state name cmd rest <<<"$line"
    if [[ "$name" == "$target" ]]; then
        removed=1
        continue
    fi
    printf '%s\n' "$line" >> "$tmp"
done < "$CONF"

if (( ! removed )); then
    notify-send "startup-apps" "no entry named '$target'" 2>/dev/null || true
    exit 1
fi

cat "$tmp" > "$CONF"

pkill -if -- "$target" >/dev/null 2>&1 || true
notify-send "startup-apps" "removed $target" 2>/dev/null || true
