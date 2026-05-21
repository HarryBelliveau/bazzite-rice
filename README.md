# bazzite-rice

A custom Bazzite GNOME image with Hyprland baked in, built via [BlueBuild](https://blue-build.org/) and GitHub Actions. Implements **Method B** of [instructions.md](instructions.md).

## What's inside

- Base: `ghcr.io/ublue-os/bazzite-gnome:stable`
- Added from `solopasha/hyprland` COPR: Hyprland + the §7 rice toolkit (Waybar, rofi-wayland, swww, hyprpaper/lock/idle/picker/shot/cursor, SwayNotificationCenter, wlogout, grim, slurp, cliphist, wl-clipboard, kitty)
- Plus: `vulkan-validation-layers`, `jetbrains-mono-nerd-fonts`

## One-time setup (before first push)

```bash
# 1. Generate the cosign keypair (creates cosign.pub + cosign.key; .gitignore hides the latter)
COSIGN_PASSWORD="" cosign generate-key-pair

# 2. On GitHub: Settings → Secrets and variables → Actions → New secret
#    Name:  SIGNING_SECRET
#    Value: the full contents of cosign.key (including BEGIN/END lines)

# 3. Push. Wait ~6 minutes for CI to publish ghcr.io/hahafoot/bazzite-rice:latest.

# 4. On GitHub Packages page, set the package visibility to public.
```

## Rebase to it

```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/hahafoot/bazzite-rice:latest
systemctl reboot
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/hahafoot/bazzite-rice:latest
systemctl reboot
```

## Apply the dotfiles

After the second reboot, from any terminal:

```bash
bash ~/Documents/bazzite-rice/dotfiles/install.sh
```

Then pick **Hyprland** from the GDM session menu and log in.

To rollback the OS: `rpm-ostree rollback` or pick the prior deployment in GRUB.
To rollback the rice: restore `*.bak.<timestamp>` files left in `~/.config/`.
