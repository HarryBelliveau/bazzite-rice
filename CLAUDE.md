# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A custom **Bazzite GNOME + Hyprland** OSTree image built via [BlueBuild](https://blue-build.org/) and published to `ghcr.io/hahafoot/bazzite-rice:latest`, plus the dotfiles that ride on top of it. There is no application code here — the artifacts are (1) a container image recipe and (2) shell/config files that get symlinked into `$HOME`.

`instructions.md` is the long-form rationale doc explaining Method A/B/C for getting Hyprland onto Bazzite; this repo implements **Method B** (custom image).

## Two halves, built/deployed independently

1. **Image** — defined by `recipes/recipe.yml`, built by `.github/workflows/build.yml` (BlueBuild GitHub Action, signed with cosign via the `SIGNING_SECRET` repo secret, published to GHCR). Daily cron + push to `main` (paths-ignore `**.md`) + manual dispatch. There is no local build command; pushing to `main` is the build.
2. **Dotfiles** — `dotfiles/install.sh` symlinks every file under `dotfiles/` into `$XDG_CONFIG_HOME` (default `~/.config/`), with one special case: anything under `dotfiles/home/` is symlinked into `$HOME` directly (for `~/.zshrc`, `~/.p10k.zsh`, etc.). The script is idempotent — pre-existing real files become `*.bak.<timestamp>`; pre-existing symlinks are replaced. It also one-shot-installs `sketchybar-app-font` for Waybar workspace icons.

Editing a dotfile in the repo while `install.sh` has already run takes effect immediately (they're symlinks). For Hyprland configs: `hyprctl reload`.

## Hyprland config conventions

- `dotfiles/hypr/hyprland.conf` is the entry point. It `source =`s sibling files and `exec-once`s helper scripts in the same dir.
- **Portal startup order matters** and is encoded in `hyprland.conf` — env is pushed into systemd/dbus, `hyprland-session.target` is started, then portals are explicitly restarted. Don't reorder these `exec-once` lines casually; breaking them breaks screen sharing.
- Wallpaper backend is **swww** (images) + **mpvpaper** (videos), both driven by `cycle-wallpaper.sh`. Not hyprpaper.
- **Startup apps** are data-driven via `dotfiles/hypr/startup-apps.conf` (`state|name|command` lines). `startup-apps.sh` reads it at login; `toggle-startup-apps.sh` is bound to SUPER+SHIFT+A and edits the file + starts/kills the matching process live. The `name` field doubles as a `pgrep -if`/`pkill -if` pattern, so it must appear in the running process's argv.
- `smart-workspace.sh <id>` is the workspace-key handler: if the workspace is already visible on some monitor it just focuses it; otherwise it moves/creates it on the *focused* monitor (vs. wherever it last lived). Keybinds in `hyprland.conf` should call this rather than `dispatch workspace` directly.

## Adding a package to the image

Edit `recipes/recipe.yml` under `modules[].install.packages`. Two COPRs are already enabled (`nett00n/hyprland`, `solopasha/hyprland`); anything in Fedora/Bazzite/those COPRs is fair game. Push to `main` → image rebuilds → users get it on next `rpm-ostree upgrade`.

## Things to leave alone unless asked

- `cosign.pub` (paired with the `SIGNING_SECRET` in CI; rotating it requires regenerating the keypair and updating the repo secret).
- The two-step unsigned→signed rebase flow documented in `README.md` — it's load-bearing for first install.
- `wallpapers/COPYRIGHTED/` — Apple dynamic wallpapers, not redistributable; don't reference them from default configs.
