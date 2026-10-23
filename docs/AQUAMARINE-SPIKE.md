# Aquamarine / Hyprland on WSL2 — spike + production fixes

Host kernel: Microsoft WSL2 with **vgem** (`/dev/dri/card0`, `renderD128`).

## Measured facts

| Item | Result |
|------|--------|
| `/dev/dri/card0` (vgem) | present |
| `gbm_bo_create` XR24 + `GBM_BO_USE_RENDERING` on **card0** | OK |
| `GBM_BO_USE_SCANOUT` / `LINEAR` / XR30 on vgem | **fail** (bo null) |
| `reopenDRMNode(..., allowRenderNode=true)` → renderD128 | breaks Aquamarine GBM on vgem |
| Hardware cursors + wayvnc headless | **black square** — use software cursors |

## Why stock Hyprland dies

Aquamarine `CBackend::start()` needs a backend with `drmFD() >= 0` to build `CGBMAllocator`. Stock `CHeadlessBackend::drmFD()` returns **-1**. DRM backend skips vgem (not KMS).

## Patch set (`scripts/patch-aquamarine.sh`)

When `OMAKEX_VGEM=1` / `AQ_WSL_VGEM=1`:

1. **Headless** opens `/dev/dri/card0` (or `OMAKEX_DRM_CARD`); does **not** open renderD128.
2. **`drmFD()` / `drmRenderNodeFD()`** return the primary fd.
3. **`Backend::reopenDRMNode(fd, allowRenderNode=false)`** so GBM stays on card0.
4. **GBM.cpp** omits `GBM_BO_USE_SCANOUT`, clears LINEAR modifiers, remaps non-8888 → XR24.
5. **Headless `getRenderFormats()`** returns only XR24/AR24/XBGR/ABGR with `DRM_FORMAT_INVALID`.

## Session stack (omakex)

Hyprland Lua (Omarchy) → headless `HEADLESS-1` @ 1920×1080 → **wayvnc** `:5901` → Windows TigerVNC.

Also required in practice:

- User in `video`/`render`; boot script `chmod`/`setfacl` on `/dev/dri` (WSL remounts weird gids)
- `seatd` for libseat
- Session `dbus-daemon` for quickshell
- `cursor.no_hardware_cursors = true`
- Never run Hyprland as root (`omakex` re-execs as `OMAKEX_USER`)

## Fallback

Build out-of-tree **vkms** if vgem path regresses (`CONFIG_DRM_VKMS` is off on Microsoft kernels).
