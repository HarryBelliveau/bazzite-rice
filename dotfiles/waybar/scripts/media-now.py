#!/usr/bin/env python3
"""media-now.py — emit one waybar JSON line per active-player metadata change.

Follows playerctl's active player (single source at a time). Wraps the track in
music notes when the active player is Spotify; uses a per-player icon otherwise.
"""
from __future__ import annotations

import html
import json
import subprocess
import sys

ICONS = {
    "spotify":  "♪",
    "mpv":      "",
    "firefox":  "",
    "chromium": "",
    "chrome":   "",
    "vlc":      "嗢",
    "default":  "▶",
}

FIELD_SEP = "\x1f"  # unit separator; vanishingly unlikely in metadata
FMT = FIELD_SEP.join((
    "{{playerName}}", "{{status}}",
    "{{xesam:title}}", "{{xesam:artist}}", "{{xesam:album}}",
))


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def render(player: str, status: str, title: str, artist: str, album: str) -> dict:
    if not (title or artist) or status == "Stopped":
        return {"text": "", "tooltip": "", "class": "stopped", "alt": "stopped"}

    body_plain = "  —  ".join(p for p in (title, artist) if p)
    body = html.escape(body_plain)

    if player.lower() == "spotify":
        text = f"♪  <i>{body}</i>  ♪" if status == "Paused" else f"♪  {body}  ♪"
    else:
        icon = ICONS.get(player.lower(), ICONS["default"])
        text = f"⏸  <i>{body}</i>" if status == "Paused" else f"{icon}  {body}"

    tooltip = f"{player} · {status}\n{title}"
    if artist:
        tooltip += f"\n{artist}"
        if album:
            tooltip += f" — {album}"

    return {
        "text":    text,
        "tooltip": html.escape(tooltip),
        "class":   status.lower(),
        "alt":     status.lower(),
    }


def main() -> None:
    proc = subprocess.Popen(
        ["playerctl", "-F", "metadata", "--format", FMT],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    assert proc.stdout is not None
    try:
        for line in proc.stdout:
            parts = (line.rstrip("\n").split(FIELD_SEP) + [""] * 5)[:5]
            emit(render(*parts))
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        proc.terminate()


if __name__ == "__main__":
    main()
