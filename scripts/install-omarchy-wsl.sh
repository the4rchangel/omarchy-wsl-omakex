#!/usr/bin/env bash
# In-distro installer for Omarchy-on-WSL + omakex.
# Run inside the Arch WSL distro (as root first for user create, then as the user).
#
# Applies every WSL fix discovered for Hyprland/Aquamarine/wayvnc:
#   - Omarchy stable package repo + omarchy desktop
#   - Patched Aquamarine (vgem card0, no renderD128, no SCANOUT/LINEAR/10-bit)
#   - omakex KeX-style launcher
#   - Boot DRM ACL + seatd
#   - Software cursors for wayvnc
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
USER_NAME="${OMAKEX_USER:-omarchy}"
OMARCHY_REF="${OMARCHY_REF:-v4.0.2}"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# ---------- root phase: user + sudo + groups ----------
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  if ! id "$USER_NAME" &>/dev/null; then
    log "Creating user $USER_NAME"
    useradd -m -G wheel,video,render -s /bin/bash "$USER_NAME"
    echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" >"/etc/sudoers.d/$USER_NAME"
    chmod 440 "/etc/sudoers.d/$USER_NAME"
    # empty passwordless sudo already; optional: passwd
  fi
  usermod -aG wheel,video,render "$USER_NAME" || true

  # Ensure wheel can sudo (fresh Arch bootstrap may lack this)
  if [[ ! -f /etc/sudoers.d/wheel ]]; then
    echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/wheel
    chmod 440 /etc/sudoers.d/wheel
  fi

  log "Re-running installer as $USER_NAME"
  exec runuser -u "$USER_NAME" -- env OMAKEX_USER="$USER_NAME" bash "$REPO_DIR/scripts/install-omarchy-wsl.sh"
fi

# ---------- user phase ----------
export OMAKEX_USER="$USER_NAME"
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"

log "Omarchy WSL install as $(id -un) (ref=$OMARCHY_REF)"

# Pacman: Arch mirrors + Omarchy stable repo
if ! grep -q '^Server' /etc/pacman.d/mirrorlist 2>/dev/null; then
  log "Writing Arch mirrorlist"
  sudo tee /etc/pacman.d/mirrorlist >/dev/null <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
EOF
fi

log "Configuring pacman.conf (core/extra + [omarchy] stable)"
sudo tee /etc/pacman.conf >/dev/null <<'EOF'
[options]
HoldPkg = pacman glibc
Architecture = auto
Color
CheckSpace
ParallelDownloads = 5
DownloadUser = alpm
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/$arch
EOF

# Keyring (fresh bootstrap)
if [[ ! -d /etc/pacman.d/gnupg ]]; then
  log "Initializing pacman keyring"
  sudo pacman-key --init
  sudo pacman-key --populate archlinux
fi

log "pacman -Syu"
sudo pacman -Syu --noconfirm

log "Installing build tools + desktop stack"
sudo pacman -S --noconfirm --needed \
  base-devel git cmake ninja pkgconf \
  hyprland aquamarine wayvnc seatd \
  mesa vulkan-swrast libglvnd \
  xorg-xwayland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
  omarchy quickshell foot nautilus \
  noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd woff2-font-awesome \
  gnome-themes-extra yaru-icon-theme \
  grim slurp wl-clipboard \
  pipewire pipewire-pulse wireplumber \
  starship polkit dbus inotify-tools \
  libdrm libgbm cairo pango \
  || warn "some packages failed — continuing"

# Desktop deps for Aquamarine build
sudo pacman -S --noconfirm --needed \
  hyprutils hyprwayland-scanner wayland wayland-protocols \
  libdisplay-info libinput libglvnd libxkbcommon pixman seatd \
  2>/dev/null || true

# Seed Omarchy user configs
log "Seeding Omarchy Hyprland Lua configs"
mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy/plugins" "$HOME/.local/state/omarchy"
for f in hyprland.lua monitors.lua input.lua bindings.lua looknfeel.lua autostart.lua; do
  if [[ ! -f "$HOME/.config/hypr/$f" && -f /usr/share/omarchy/config/hypr/$f ]]; then
    cp "/usr/share/omarchy/config/hypr/$f" "$HOME/.config/hypr/$f"
  fi
done
[[ -f "$HOME/.config/hypr/hyprland.lua" ]] || \
  cp /usr/share/omarchy/config/hypr/hyprland.lua "$HOME/.config/hypr/" 2>/dev/null || true
for f in monitors input bindings looknfeel autostart; do
  [[ -f "$HOME/.config/hypr/$f.lua" ]] || echo "-- user $f overrides" >"$HOME/.config/hypr/$f.lua"
done

# Software cursors (wayvnc + headless HW cursors → black square)
if [[ -f "$HOME/.config/hypr/looknfeel.lua" ]] && ! grep -q 'no_hardware_cursors' "$HOME/.config/hypr/looknfeel.lua"; then
  cat >>"$HOME/.config/hypr/looknfeel.lua" <<'LUA'

-- omakex/WSL: headless+wayvnc cannot composite hardware cursors (black square).
hl.config({
  cursor = {
    no_hardware_cursors = true,
  },
})
LUA
fi

# Theme
export PATH="/usr/share/omarchy/bin:$PATH"
if command -v omarchy-theme-set >/dev/null; then
  log "Setting Tokyo Night theme"
  OMARCHY_THEME_HEADLESS=1 OMARCHY_SETUP_CONTEXT=iso-chroot \
    omarchy-theme-set "Tokyo Night" || warn "theme-set failed"
fi

# Shell PATH
grep -q OMARCHY_PATH "$HOME/.bashrc" 2>/dev/null || cat >>"$HOME/.bashrc" <<'B'

# Omarchy / omakex
export OMARCHY_PATH=/usr/share/omarchy
export PATH="/usr/share/omarchy/bin:$PATH"
B
sudo tee /etc/profile.d/omarchy.sh >/dev/null <<'P'
export OMARCHY_PATH=/usr/share/omarchy
export PATH="/usr/share/omarchy/bin:$PATH"
P

# Patch + build Aquamarine
log "Patching & building Aquamarine (OMAKEX_VGEM / vgem card0)"
bash "$REPO_DIR/scripts/patch-aquamarine.sh"
AQ="$REPO_DIR/build/aquamarine"
cmake -S "$AQ" -B "$AQ/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$AQ/build" -j"$(nproc)"
sudo cmake --install "$AQ/build"
sudo ldconfig

# omakex launcher
log "Installing omakex → /usr/local/bin/omakex"
sudo install -m 0755 "$REPO_DIR/omakex/omakex" /usr/local/bin/omakex
echo "OMAKEX_USER=$USER_NAME" | sudo tee /etc/omakex.conf >/dev/null

# Boot-time DRM + seatd + XDG runtime (WSL remounts /dev/dri with odd gids)
log "Installing boot DRM/seatd helper"
sudo tee /usr/local/lib/omakex-fix-dri.sh >/dev/null <<EOF
#!/bin/bash
for n in /dev/dri/card0 /dev/dri/renderD128; do
  [[ -e "\$n" ]] || continue
  chmod a+rw "\$n" 2>/dev/null || true
  id $USER_NAME &>/dev/null && setfacl -m u:$USER_NAME:rw "\$n" 2>/dev/null || true
done
if [[ ! -S /run/seatd.sock ]] && command -v seatd >/dev/null; then
  seatd -g video >/var/log/omakex-seatd.log 2>&1 &
fi
if id $USER_NAME &>/dev/null; then
  uid=\$(id -u $USER_NAME)
  mkdir -p /run/user/\$uid
  chown $USER_NAME:$USER_NAME /run/user/\$uid
  chmod 700 /run/user/\$uid
fi
EOF
sudo chmod 755 /usr/local/lib/omakex-fix-dri.sh
sudo /usr/local/lib/omakex-fix-dri.sh || true

# wsl.conf: systemd + default user + boot command
log "Writing /etc/wsl.conf"
sudo tee /etc/wsl.conf >/dev/null <<EOF
[boot]
systemd=true
command=/usr/local/lib/omakex-fix-dri.sh

[user]
default=$USER_NAME

[interop]
enabled=true
appendWindowsPath=true
EOF

cat <<EOF

╔══════════════════════════════════════════════════════════╗
║  Omarchy WSL + omakex install complete                 ║
╚══════════════════════════════════════════════════════════╝

  From Windows PowerShell (once):
    wsl --terminate omarchy

  Then open the omarchy distro and run:
    omakex

  That starts Hyprland + Omarchy shell and opens TigerVNC
  on localhost:5901 (like Kali kex).

  Commands:  omakex | omakex stop | omakex status | omakex win

  Notes:
  - Rendering is CPU/llvmpipe (vgem), not GPU.
  - Install TigerVNC on Windows if missing:
      winget install TigerVNC.TigerVNC

EOF
