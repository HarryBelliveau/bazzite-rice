#!/usr/bin/env bash
# Symlink everything under dotfiles/ into ~/.config/, preserving any pre-existing
# real files as <file>.bak.<timestamp>. Idempotent: re-running just refreshes links.
#
# Files under dotfiles/home/ are symlinked into $HOME directly instead of
# $XDG_CONFIG_HOME (for ~/.zshrc, ~/.p10k.zsh, and other $HOME-rooted dotfiles).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$DEST"

find "$SRC" -type f ! -name install.sh -print0 | while IFS= read -r -d '' src; do
    rel="${src#"$SRC"/}"
    if [[ "$rel" == home/* ]]; then
        dst="$HOME/${rel#home/}"
    else
        dst="$DEST/$rel"
    fi
    mkdir -p "$(dirname "$dst")"

    if [[ -L "$dst" ]]; then
        rm "$dst"
    elif [[ -e "$dst" ]]; then
        mv "$dst" "$dst.bak.$STAMP"
        echo "backed up: $dst -> $dst.bak.$STAMP"
    fi

    ln -s "$src" "$dst"
    echo "linked: $rel"
done

FONT_DIR="$HOME/.local/share/fonts"
FONT_PATH="$FONT_DIR/sketchybar-app-font.ttf"
if [[ ! -f "$FONT_PATH" ]]; then
    mkdir -p "$FONT_DIR"
    if curl -fsSL -o "$FONT_PATH" \
        https://github.com/kvndrsslr/sketchybar-app-font/releases/latest/download/sketchybar-app-font.ttf; then
        fc-cache -f "$FONT_DIR" >/dev/null
        echo "installed font: sketchybar-app-font"
    else
        echo "warn: failed to download sketchybar-app-font (waybar workspace icons will fall back)"
    fi
fi

echo
echo "Done. Reload Hyprland with: hyprctl reload"
echo "If you backed up real files, they're at *.bak.$STAMP -- review and delete when satisfied."
