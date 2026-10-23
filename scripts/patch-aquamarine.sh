#!/usr/bin/env bash
# Clone Aquamarine and apply omakex WSL vgem headless DRM-fd patch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${AQUAMARINE_SRC:-$ROOT/build/aquamarine}"
REF="${AQUAMARINE_REF:-v0.15.1}"

mkdir -p "$(dirname "$SRC")"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch "$REF" https://github.com/hyprwm/aquamarine.git "$SRC"
else
  git -C "$SRC" fetch --depth 1 origin "refs/tags/$REF:refs/tags/$REF" 2>/dev/null || true
  git -C "$SRC" checkout -f "$REF"
fi

python3 - <<'PY' "$SRC"
import re, sys
from pathlib import Path
src = Path(sys.argv[1])
hpp = src / "include/aquamarine/backend/Headless.hpp"
if not hpp.exists():
    hpp = src / "src/backend/Headless.hpp"
cpp = src / "src/backend/Headless.cpp"
if not hpp.exists() or not cpp.exists():
    raise SystemExit(f"missing headless sources under {src} (hpp={hpp} cpp={cpp})")

h = hpp.read_text()
if "m_drmFD" not in h:
    m = re.search(r"\} timers;", h)
    if not m:
        raise SystemExit("cannot find '} timers;' in Headless.hpp")
    insert = "\n\n        // omakex/WSL: DRM fd for GBM allocator\n        int m_drmFD       = -1;\n        int m_drmRenderFD = -1;\n"
    h = h[: m.end()] + insert + h[m.end() :]
    hpp.write_text(h)
    print("patched", hpp)
else:
    print("hpp already patched")

c = cpp.read_text()
if "OMAKEX_VGEM" not in c:
    # ensure includes
    for inc in ["#include <cstdlib>", "#include <fcntl.h>", "#include <cstring>", "#include <unistd.h>", "#include <xf86drm.h>"]:
        if inc not in c:
            lines = c.splitlines(True)
            i = 0
            while i < len(lines) and (lines[i].startswith("#include") or lines[i].startswith("#pragma") or lines[i].strip() == ""):
                i += 1
            lines.insert(i, inc + "\n")
            c = "".join(lines)

    # replace start() — keep primary card0 only; vgem renderD128 cannot CREATE_DUMB
    c2, n = re.subn(
        r"bool Aquamarine::CHeadlessBackend::start\(\)\s*\{\s*return true;\s*\}",
        '''bool Aquamarine::CHeadlessBackend::start() {
    const char* enabled = getenv("OMAKEX_VGEM");
    if (!enabled)
        enabled = getenv("AQ_WSL_VGEM");
    if (enabled && enabled[0] != '0') {
        const char* card = getenv("OMAKEX_DRM_CARD");
        if (!card || !*card)
            card = "/dev/dri/card0";
        m_drmFD = ::open(card, O_RDWR | O_CLOEXEC);
        if (m_drmFD < 0) {
            backend->log(AQ_LOG_ERROR, std::format("headless/omakex: failed to open {}: {}", card, strerror(errno)));
        } else {
            backend->log(AQ_LOG_DEBUG, std::format("headless/omakex: using DRM node {} fd={}", card, m_drmFD));
            // Do NOT open renderD128: vgem render node lacks CREATE_DUMB; GBM must use card0.
            m_drmRenderFD = -1;
        }
    }
    return true;
}''',
        c,
        count=1,
    )
    if n != 1:
        raise SystemExit(f"failed to patch start(): replacements={n}")
    c = c2

    c2, n = re.subn(
        r"int Aquamarine::CHeadlessBackend::drmFD\(\)\s*\{\s*return -1;\s*\}",
        "int Aquamarine::CHeadlessBackend::drmFD() {\n    return m_drmFD;\n}",
        c,
        count=1,
    )
    if n != 1:
        raise SystemExit(f"failed to patch drmFD(): replacements={n}")
    c = c2

    c2, n = re.subn(
        r"int Aquamarine::CHeadlessBackend::drmRenderNodeFD\(\)\s*\{\s*return -1;\s*\}",
        "int Aquamarine::CHeadlessBackend::drmRenderNodeFD() {\n    // Prefer primary (card0) on WSL/vgem — render node cannot allocate dumb BOs.\n    return m_drmFD >= 0 ? m_drmFD : m_drmRenderFD;\n}",
        c,
        count=1,
    )
    if n != 1:
        raise SystemExit(f"failed to patch drmRenderNodeFD(): replacements={n}")
    c = c2

    cpp.write_text(c)
    print("patched", cpp)
else:
    print("cpp already patched")
    # Ensure render-node preference is card0 even on re-run of older patch
    if "Do NOT open renderD128" not in c:
        c2, n = re.subn(
            r"backend->log\(AQ_LOG_DEBUG, std::format\(\"headless/omakex: using DRM node \{\} fd=\{\}\", card, m_drmFD\)\);\s*"
            r"char\* renderName = drmGetRenderDeviceNameFromFd\(m_drmFD\);\s*"
            r"if \(renderName\) \{\s*"
            r"m_drmRenderFD = ::open\(renderName, O_RDWR \| O_CLOEXEC\);\s*"
            r"free\(renderName\);\s*"
            r"\}",
            'backend->log(AQ_LOG_DEBUG, std::format("headless/omakex: using DRM node {} fd={}", card, m_drmFD));\n'
            "            // Do NOT open renderD128: vgem render node lacks CREATE_DUMB; GBM must use card0.\n"
            "            m_drmRenderFD = -1;",
            c,
            count=1,
        )
        if n == 1:
            c = c2
            print("updated start() to skip renderD128")
        c2, n = re.subn(
            r"int Aquamarine::CHeadlessBackend::drmRenderNodeFD\(\)\s*\{\s*"
            r"return m_drmRenderFD >= 0 \? m_drmRenderFD : m_drmFD;\s*\}",
            "int Aquamarine::CHeadlessBackend::drmRenderNodeFD() {\n"
            "    // Prefer primary (card0) on WSL/vgem — render node cannot allocate dumb BOs.\n"
            "    return m_drmFD >= 0 ? m_drmFD : m_drmRenderFD;\n"
            "}",
            c,
            count=1,
        )
        if n == 1:
            c = c2
            print("updated drmRenderNodeFD() to prefer card0")
        cpp.write_text(c)

# Backend.cpp: reopenDRMNode defaults to render node — force primary when OMAKEX_VGEM
backend = src / "src/backend/Backend.cpp"
b = backend.read_text()
needle = "auto fd = reopenDRMNode(b->drmFD());"
if "omakex: skip render node" in b:
    print("backend already patched")
elif needle not in b:
    if "reopenDRMNode(b->drmFD(), allowRenderNode)" in b:
        print("backend already patched")
    else:
        raise SystemExit("cannot find reopenDRMNode call in Backend.cpp")
else:
    replacement = '''// omakex: skip render node on vgem (CREATE_DUMB only on card0)
            bool allowRenderNode = true;
            if (const char* ev = getenv("OMAKEX_VGEM"); ev && ev[0] != '0')
                allowRenderNode = false;
            else if (const char* ev = getenv("AQ_WSL_VGEM"); ev && ev[0] != '0')
                allowRenderNode = false;
            auto fd = reopenDRMNode(b->drmFD(), allowRenderNode);'''
    b = b.replace(needle, replacement, 1)
    if "#include <cstdlib>" not in b:
        lines = b.splitlines(True)
        i = 0
        while i < len(lines) and (lines[i].startswith("#include") or lines[i].startswith("#pragma") or lines[i].strip() == ""):
            i += 1
        lines.insert(i, "#include <cstdlib>\n")
        b = "".join(lines)
    backend.write_text(b)
    print("patched", backend)

# GBM.cpp: vgem rejects SCANOUT, LINEAR, and 10-bit formats
gbm = src / "src/allocator/GBM.cpp"
g = gbm.read_text()
if "omakex: vgem XR24 only" in g:
    print("gbm already patched")
else:
    # Insert format/modifier clamp before flags, and skip SCANOUT
    anchor = """    uint32_t flags = GBM_BO_USE_RENDERING;
    if (params.scanout && !MULTIGPU)
        flags |= GBM_BO_USE_SCANOUT;"""
    # After a prior partial patch the SCANOUT block may already be altered
    if "omakex: vgem has no scanout" in g and "omakex: vgem XR24 only" not in g:
        # Upgrade partial patch: add XR24 clamp before the omakexVgem flags block
        old = """    uint32_t flags = GBM_BO_USE_RENDERING;
    // omakex: vgem has no scanout — GBM_BO_USE_SCANOUT makes gbm_bo_create return null
    bool omakexVgem = false;"""
        new = """    // omakex: vgem XR24 only — no 10-bit, no LINEAR modifiers, no SCANOUT
    bool omakexVgem = false;
    if (const char* ev = getenv("OMAKEX_VGEM"); ev && ev[0] != '0')
        omakexVgem = true;
    else if (const char* ev = getenv("AQ_WSL_VGEM"); ev && ev[0] != '0')
        omakexVgem = true;
    if (omakexVgem) {
        explicitModifiers.clear();
        if (attrs.format != DRM_FORMAT_XRGB8888 && attrs.format != DRM_FORMAT_ARGB8888 &&
            attrs.format != DRM_FORMAT_XBGR8888 && attrs.format != DRM_FORMAT_ABGR8888) {
            allocator->backend->log(AQ_LOG_DEBUG,
                std::format("GBM/omakex: remapping format {} -> XR24", fourccToName(attrs.format)));
            attrs.format = DRM_FORMAT_XRGB8888;
        }
    }

    uint32_t flags = GBM_BO_USE_RENDERING;
    // omakex: vgem has no scanout — GBM_BO_USE_SCANOUT makes gbm_bo_create return null
    bool omakexVgemUnused = false; // kept for structure; real flag set above
    (void)omakexVgemUnused;"""
        # Simpler: replace the whole partial block including getenv
        import re as _re
        g2, n = _re.subn(
            r"    uint32_t flags = GBM_BO_USE_RENDERING;\n"
            r"    // omakex: vgem has no scanout[^\n]*\n"
            r"    bool omakexVgem = false;\n"
            r"    if \(const char\* ev = getenv\(\"OMAKEX_VGEM\"\); ev && ev\[0\] != '0'\)\n"
            r"        omakexVgem = true;\n"
            r"    else if \(const char\* ev = getenv\(\"AQ_WSL_VGEM\"\); ev && ev\[0\] != '0'\)\n"
            r"        omakexVgem = true;\n"
            r"    if \(params\.scanout && !MULTIGPU && !omakexVgem\)\n"
            r"        flags \|= GBM_BO_USE_SCANOUT;\n"
            r"    else if \(omakexVgem && params\.scanout\)\n"
            r"        allocator->backend->log\(AQ_LOG_DEBUG, \"GBM/omakex: omitting GBM_BO_USE_SCANOUT for vgem\"\);",
            """    // omakex: vgem XR24 only — no 10-bit, no LINEAR modifiers, no SCANOUT
    bool omakexVgem = false;
    if (const char* ev = getenv("OMAKEX_VGEM"); ev && ev[0] != '0')
        omakexVgem = true;
    else if (const char* ev = getenv("AQ_WSL_VGEM"); ev && ev[0] != '0')
        omakexVgem = true;
    if (omakexVgem) {
        explicitModifiers.clear();
        if (attrs.format != DRM_FORMAT_XRGB8888 && attrs.format != DRM_FORMAT_ARGB8888 &&
            attrs.format != DRM_FORMAT_XBGR8888 && attrs.format != DRM_FORMAT_ABGR8888) {
            allocator->backend->log(AQ_LOG_DEBUG,
                std::format("GBM/omakex: remapping format {} -> XR24", fourccToName(attrs.format)));
            attrs.format = DRM_FORMAT_XRGB8888;
        }
    }

    uint32_t flags = GBM_BO_USE_RENDERING;
    if (params.scanout && !MULTIGPU && !omakexVgem)
        flags |= GBM_BO_USE_SCANOUT;
    else if (omakexVgem && params.scanout)
        allocator->backend->log(AQ_LOG_DEBUG, "GBM/omakex: omitting GBM_BO_USE_SCANOUT for vgem");""",
            g,
            count=1,
        )
        if n != 1:
            raise SystemExit(f"failed to upgrade GBM partial patch: n={n}")
        g = g2
    elif anchor in g:
        replacement = """    // omakex: vgem XR24 only — no 10-bit, no LINEAR modifiers, no SCANOUT
    bool omakexVgem = false;
    if (const char* ev = getenv("OMAKEX_VGEM"); ev && ev[0] != '0')
        omakexVgem = true;
    else if (const char* ev = getenv("AQ_WSL_VGEM"); ev && ev[0] != '0')
        omakexVgem = true;
    if (omakexVgem) {
        explicitModifiers.clear();
        if (attrs.format != DRM_FORMAT_XRGB8888 && attrs.format != DRM_FORMAT_ARGB8888 &&
            attrs.format != DRM_FORMAT_XBGR8888 && attrs.format != DRM_FORMAT_ABGR8888) {
            allocator->backend->log(AQ_LOG_DEBUG,
                std::format("GBM/omakex: remapping format {} -> XR24", fourccToName(attrs.format)));
            attrs.format = DRM_FORMAT_XRGB8888;
        }
    }

    uint32_t flags = GBM_BO_USE_RENDERING;
    if (params.scanout && !MULTIGPU && !omakexVgem)
        flags |= GBM_BO_USE_SCANOUT;
    else if (omakexVgem && params.scanout)
        allocator->backend->log(AQ_LOG_DEBUG, "GBM/omakex: omitting GBM_BO_USE_SCANOUT for vgem");"""
        g = g.replace(anchor, replacement, 1)
    else:
        raise SystemExit("cannot find GBM flags block to patch")
    if "#include <cstdlib>" not in g:
        lines = g.splitlines(True)
        i = 0
        while i < len(lines) and (lines[i].startswith("#include") or lines[i].startswith("#pragma") or lines[i].strip() == ""):
            i += 1
        lines.insert(i, "#include <cstdlib>\n")
        g = "".join(lines)
    gbm.write_text(g)
    print("patched", gbm)

# Headless getRenderFormats: only 8-bit INVALID modifiers on vgem
hc = (src / "src/backend/Headless.cpp").read_text()
if "omakex: vgem render formats" in hc:
    print("headless formats already patched")
else:
    # Prepend early-return at start of getRenderFormats body
    old = """std::vector<SDRMFormat> Aquamarine::CHeadlessBackend::getRenderFormats() {
    for (const auto& impl : backend->getImplementations()) {"""
    new = """std::vector<SDRMFormat> Aquamarine::CHeadlessBackend::getRenderFormats() {
    // omakex: vgem render formats — only XR24/AR24 with implicit modifiers
    if (const char* ev = getenv("OMAKEX_VGEM"); ev && ev[0] != '0') {
        return {SDRMFormat{.drmFormat = DRM_FORMAT_XRGB8888, .modifiers = {DRM_FORMAT_INVALID}},
                SDRMFormat{.drmFormat = DRM_FORMAT_ARGB8888, .modifiers = {DRM_FORMAT_INVALID}},
                SDRMFormat{.drmFormat = DRM_FORMAT_XBGR8888, .modifiers = {DRM_FORMAT_INVALID}},
                SDRMFormat{.drmFormat = DRM_FORMAT_ABGR8888, .modifiers = {DRM_FORMAT_INVALID}}};
    }
    if (const char* ev = getenv("AQ_WSL_VGEM"); ev && ev[0] != '0') {
        return {SDRMFormat{.drmFormat = DRM_FORMAT_XRGB8888, .modifiers = {DRM_FORMAT_INVALID}},
                SDRMFormat{.drmFormat = DRM_FORMAT_ARGB8888, .modifiers = {DRM_FORMAT_INVALID}},
                SDRMFormat{.drmFormat = DRM_FORMAT_XBGR8888, .modifiers = {DRM_FORMAT_INVALID}},
                SDRMFormat{.drmFormat = DRM_FORMAT_ABGR8888, .modifiers = {DRM_FORMAT_INVALID}}};
    }
    for (const auto& impl : backend->getImplementations()) {"""
    if old not in hc:
        raise SystemExit("cannot find getRenderFormats() to patch")
    (src / "src/backend/Headless.cpp").write_text(hc.replace(old, new, 1))
    print("patched headless getRenderFormats")
PY

echo "Aquamarine sources ready at $SRC"
echo "Build with: cmake -S $SRC -B $SRC/build && cmake --build $SRC/build -j\"\$(nproc)\""
