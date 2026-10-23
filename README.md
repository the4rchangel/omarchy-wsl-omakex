# Omarchy WSL + omakex

Run **[Omarchy](https://omarchy.org)** (Arch + Hyprland) inside **WSL2**, with a Kali **Win-KeX**-style launcher: type `omakex` and the desktop opens in TigerVNC.

Stock Hyprland cannot start on WSL (no real KMS). This project patches **Aquamarine** to use WSL’s **vgem** DRM node for GBM, runs a headless output + **wayvnc**, and ships every fix we hit on the way (cursor, DRM permissions, Omarchy shell, etc.).

> Rendering is **CPU / llvmpipe** — fine for a daily desktop shell, not for games.

## Windows install (recommended)

**Requirements:** Windows 10/11 with **WSL2**, plus any one existing distro (e.g. Ubuntu) used only to bootstrap Arch.

```powershell
# Admin once if WSL is missing:
#   wsl --install
#   wsl --install -d Ubuntu

git clone https://github.com/<you>/omarchy-wsl-omakex.git
cd omarchy-wsl-omakex
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

Optional parameters:

```powershell
.\install.ps1 -UserName omarchy -DistroName omarchy
.\install.ps1 -SkipTigerVNC          # if you already have a VNC viewer
.\install.ps1 -SkipBootstrap         # distro already imported
```

When it finishes:

```powershell
wsl -d omarchy
omakex                 # start desktop + open TigerVNC (localhost:5901)
omakex stop
omakex status
omakex win             # reopen viewer only
```

## What the installer does

| Step | Detail |
|------|--------|
| Bootstrap | Fresh Arch rootfs → `wsl --import omarchy` |
| Packages | Omarchy stable repo + `omarchy` + Hyprland/quickshell/fonts |
| Aquamarine | Patch + rebuild for vgem (`OMAKEX_VGEM`) |
| omakex | `/usr/local/bin/omakex` (KeX UX) |
| Boot fix | `/dev/dri` ACLs + `seatd` via `wsl.conf` `command=` |
| Desktop | Tokyo Night theme, software cursors (no black square), headless 1920×1080 |
| Windows | TigerVNC via winget (optional) |

### Aquamarine / vgem fixes baked in

1. Open **`/dev/dri/card0`** from headless (`drmFD()` ≥ 0).
2. Force **primary node** for GBM (vgem **renderD128** cannot `CREATE_DUMB` for Aquamarine’s reopen path).
3. Drop **`GBM_BO_USE_SCANOUT`**, **LINEAR**, and **10-bit** formats (only XR24/AR24 + `RENDERING` work on vgem).
4. **`cursor:no_hardware_cursors`** so wayvnc doesn’t show a black square.

Details: [docs/AQUAMARINE-SPIKE.md](docs/AQUAMARINE-SPIKE.md).

## Layout

```
install.ps1                 Windows one-shot
omakex/omakex               Session launcher
scripts/
  bootstrap-arch-wsl.sh     Create Arch WSL distro
  bootstrap-arch-wsl.ps1    Thin Windows wrapper (prefer install.ps1)
  install-omarchy-wsl.sh    Full in-distro install (all fixes)
  patch-aquamarine.sh       Clone + patch Aquamarine sources
aquamarine-patches/         Patch notes
docs/                       Spike / research
```

## Manual / advanced

Inside an existing Arch `omarchy` distro, with this repo at `~/omarchy-wsl-omakex`:

```bash
sudo OMAKEX_USER=omarchy bash scripts/install-omarchy-wsl.sh
```

Rebuild Aquamarine only:

```bash
./scripts/patch-aquamarine.sh
cmake -S build/aquamarine -B build/aquamarine/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build/aquamarine/build -j"$(nproc)"
sudo cmake --install build/aquamarine/build && sudo ldconfig
```

## Env vars

| Variable | Default | Meaning |
|----------|---------|---------|
| `OMAKEX_USER` | `omarchy` (or `archangel` if that user exists) | Desktop user; Hyprland will not run as root |
| `OMAKEX_DISPLAY` | `1` | VNC display → port `5900+N` |
| `OMAKEX_GEOMETRY` | `1920x1080` | Headless mode |
| `OMAKEX_NOWIN` | unset | `1` = server only (no TigerVNC popup) |
| `OMAKEX_VNCVIEWER` | auto | Path to `.exe` viewer |
| `OMAKEX_DRM_CARD` | `/dev/dri/card0` | vgem card |

## Status

Proven end-to-end on WSL2 (Microsoft kernel with vgem): Omarchy bar + Tokyo Night + wayvnc + TigerVNC.

**Out of scope:** GPU Hyprland via `/dev/dxg`. Official native Windows path remains [try-omarchy-windows](https://github.com/omacom/try-omarchy-windows) (QEMU).

## License

MIT — see [LICENSE](LICENSE). Omarchy itself is MIT (Basecamp / omacom); Aquamarine/Hyprland keep their upstream licenses.
