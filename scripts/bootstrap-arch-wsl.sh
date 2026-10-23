#!/usr/bin/env bash
# Bootstrap a fresh Arch Linux WSL distro named "omarchy" (path 2A).
# Run from Ubuntu (or any) WSL that has curl, zstd, tar, and can call wsl.exe.
set -euo pipefail

DISTRO="${OMAKEX_DISTRO:-omarchy}"
# Resolve Windows profile for install path (WSL → /mnt/c/Users/<name>)
WIN_USER="${OMAKEX_WIN_USER:-}"
if [[ -z "$WIN_USER" ]]; then
  for d in /mnt/c/Users/*; do
    base="$(basename "$d")"
    [[ "$base" == "Public" || "$base" == "Default" || "$base" == "All Users" ]] && continue
    [[ -d "$d/AppData/Local" ]] && WIN_USER="$base" && break
  done
fi
INSTALL_DIR="${OMAKEX_INSTALL_DIR:-/mnt/c/Users/${WIN_USER:-$USER}/AppData/Local/WSL/${DISTRO}}"
BUILD="$(cd "$(dirname "$0")/.." && pwd)/build"
mkdir -p "$BUILD" "$INSTALL_DIR"

WSL="/mnt/c/Windows/System32/wsl.exe"
if "$WSL" -l -q 2>/dev/null | tr -d '\0' | grep -qx "$DISTRO"; then
  echo "Distro '$DISTRO' already exists. To redo: $WSL --unregister $DISTRO"
  exit 0
fi

BOOTSTRAP_URL="${ARCH_BOOTSTRAP_URL:-https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst}"
TAR_ZST="$BUILD/archlinux-bootstrap-x86_64.tar.zst"
ROOTFS_TAR="$BUILD/arch-rootfs.tar"

echo "==> Download bootstrap"
if [[ ! -f "$TAR_ZST" ]]; then
  curl -fL --retry 3 -o "$TAR_ZST" "$BOOTSTRAP_URL"
fi

echo "==> Extract → flat rootfs tar for wsl --import"
rm -rf "$BUILD/bootstrap-extract"
mkdir -p "$BUILD/bootstrap-extract"
# Bootstrap tarball ships root-owned files; extract without preserving owner.
zstd -dc "$TAR_ZST" | sudo tar --no-same-owner --no-same-permissions -xf - -C "$BUILD/bootstrap-extract"
# tarball layout: root.x86_64/...
ROOT="$BUILD/bootstrap-extract/root.x86_64"
if [[ ! -d "$ROOT" ]]; then
  ROOT="$BUILD/bootstrap-extract"
fi
sudo chown -R "$(id -u):$(id -g)" "$ROOT"
# Minimal WSL niceties before import
cat > "$ROOT/etc/wsl.conf" <<'EOF'
[boot]
systemd=true

[user]
default=root

[interop]
enabled=true
appendWindowsPath=true
EOF

sudo tar -C "$ROOT" --owner=0 --group=0 -cf "$ROOTFS_TAR" .
sudo chown "$(id -u):$(id -g)" "$ROOTFS_TAR"

echo "==> wsl --import $DISTRO → $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
"$WSL" --import "$DISTRO" "$(wslpath -w "$INSTALL_DIR")" "$(wslpath -w "$ROOTFS_TAR")"

echo "==> First boot: mirrors + pacman keyring + base packages"
"$WSL" -d "$DISTRO" --user root -- tee /etc/pacman.d/mirrorlist >/dev/null <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF
"$WSL" -d "$DISTRO" --user root -- bash -lc '
  set -euo pipefail
  pacman-key --init
  pacman-key --populate archlinux
  pacman -Syu --noconfirm
  pacman -S --noconfirm --needed base base-devel git sudo curl wget neovim
'

echo "Arch WSL '$DISTRO' ready."
echo "Next: $WSL -d $DISTRO -- bash -lc \"\$(cat scripts/install-omarchy-wsl.sh)\""
echo "Or copy repo into distro and run scripts/install-omarchy-wsl.sh"
