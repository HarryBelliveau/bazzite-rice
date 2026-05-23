#!/usr/bin/env python3
"""media-now.py — emit waybar JSON for the active playerctl media player.

Hides the module after the player has been not-Playing for HIDE_AFTER_PAUSE
seconds. Re-shows immediately when playback resumes.
"""
from __future__ import annotations

import html
import json
import subprocess
import sys
import threading
import time

HIDE_AFTER_PAUSE = 20.0  # seconds since last Playing before we hide

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

state_lock = threading.Lock()
state = {
    "player": "", "status": "Stopped",
    "title": "", "artist": "", "album": "",
    "last_play": 0.0,  # monotonic timestamp of most recent "Playing"
}


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def hidden() -> dict:
    return {"text": "", "tooltip": "", "class": "stopped", "alt": "stopped"}


def render(player: str, status: str, title: str, artist: str, album: str) -> dict:
    if not (title or artist) or status == "Stopped":
        return hidden()

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


def snapshot_and_emit() -> None:
    with state_lock:
        s = dict(state)
    elapsed = time.monotonic() - s["last_play"]
    if s["status"] == "Playing":
        emit(render(s["player"], s["status"], s["title"], s["artist"], s["album"]))
    elif elapsed < HIDE_AFTER_PAUSE and (s["title"] or s["artist"]):
        emit(render(s["player"], s["status"], s["title"], s["artist"], s["album"]))
    else:
        emit(hidden())


def timer_loop() -> None:
    while True:
        time.sleep(5)
        snapshot_and_emit()


def main() -> None:
    threading.Thread(target=timer_loop, daemon=True).start()
    proc = subprocess.Popen(
        ["playerctl", "-F", "metadata", "--format", FMT],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    assert proc.stdout is not None
    try:
        for line in proc.stdout:
            parts = (line.rstrip("\n").split(FIELD_SEP) + [""] * 5)[:5]
            player, status, title, artist, album = parts
            with state_lock:
                state.update(player=player, status=status,
                             title=title, artist=artist, album=album)
                if status == "Playing":
                    state["last_play"] = time.monotonic()
            snapshot_and_emit()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        proc.terminate()


if __name__ == "__main__":
    main()
