#!/usr/bin/env bash
# Symlink everything under dotfiles/ into ~/.config/, preserving any pre-existing
# real files as <file>.bak.<timestamp>. Idempotent: re-running just refreshes links.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$DEST"

find "$SRC" -type f ! -name install.sh -print0 | while IFS= read -r -d '' src; do
    rel="${src#"$SRC"/}"
    dst="$DEST/$rel"
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

echo
echo "Done. Reload Hyprland with: hyprctl reload"
echo "If you backed up real files, they're at *.bak.$STAMP -- review and delete when satisfied."
