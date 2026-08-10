#!/usr/bin/env bash
#
# build-appimage.sh — Package WireViz (https://github.com/wireviz/WireViz)
# as a self-contained AppImage.
#
# WireViz is a pure-Python CLI tool, so this script:
#   1. Builds an AppDir with an embedded, relocatable Python venv
#   2. pip-installs wireviz (and its Python deps) into that venv
#   3. Bundles a static/portable Graphviz `dot` binary (wireviz's one
#      external, non-Python dependency) so the AppImage works even on
#      systems without Graphviz installed
#   4. Wraps it all with an AppRun launcher, .desktop file and icon
#   5. Downloads appimagetool and runs it to produce the final .AppImage
#
# Requirements to RUN this script: a Linux x86_64 machine, internet
# access, `python3`, `python3-venv`, and `wget`/`curl`. It does NOT
# need Graphviz pre-installed on the build machine (we vendor it),
# but if system Graphviz is missing the script will fall back to
# apt-get to fetch just the `dot` binary for bundling.
#
# Usage:
#   chmod +x build-appimage.sh
#   ./build-appimage.sh [wireviz-version]
#
# Example:
#   ./build-appimage.sh 0.4.1
#
set -euo pipefail

WIREVIZ_VERSION="${1:-0.4.1}"          # pip version to install; override as needed
APP=WireViz
BUILD_DIR="$(pwd)/build"
APPDIR="${BUILD_DIR}/${APP}.AppDir"
ARCH="x86_64"

echo "==> Building ${APP} AppImage (wireviz==${WIREVIZ_VERSION})"

rm -rf "${BUILD_DIR}"
mkdir -p "${APPDIR}/usr/bin" "${APPDIR}/usr/lib" "${APPDIR}/usr/share/applications" \
         "${APPDIR}/usr/share/icons/hicolor/256x256/apps"

# ---------------------------------------------------------------------------
# 1. Embedded Python venv with WireViz installed
# ---------------------------------------------------------------------------
echo "==> Creating embedded venv"
# --copies: copy the actual python interpreter binary into the venv
# instead of symlinking to the build machine's system python. Without
# this, the AppImage silently depends on the *target* machine having a
# python3 at the exact same absolute path the venv was built with.
python3 -m venv --copies "${APPDIR}/usr/venv"
# shellcheck disable=SC1091
source "${APPDIR}/usr/venv/bin/activate"
pip install --upgrade pip wheel >/dev/null
pip install "wireviz==${WIREVIZ_VERSION}"
deactivate

# NOTE: do NOT rewrite the shebang lines in usr/venv/bin/* to
# `#!/usr/bin/env python3` — that makes them run against the *host*
# system's Python (which doesn't have wireviz installed) instead of
# this bundled venv. The venv's own interpreter is invoked directly
# and explicitly in AppRun below, so the shebang line is never even
# used at runtime; leave it as-is.

# ---------------------------------------------------------------------------
# 2. Bundle a Graphviz `dot` binary (WireViz's only non-Python dependency)
# ---------------------------------------------------------------------------
echo "==> Bundling Graphviz"
if command -v dot >/dev/null 2>&1; then
  DOT_BIN="$(command -v dot)"
else
  echo "    system 'dot' not found, installing via apt-get for bundling..."
  sudo apt-get update -qq && sudo apt-get install -y -qq graphviz
  DOT_BIN="$(command -v dot)"
fi

# Copy dot plus the shared libs it needs, and its plugin config.
mkdir -p "${APPDIR}/usr/bin" "${APPDIR}/usr/lib/graphviz"
cp "${DOT_BIN}" "${APPDIR}/usr/bin/dot"
# copy the graphviz plugin directory (layout engines, output renderers)
GV_LIBDIR="$(dirname "$(ldconfig -p | grep libgvc | head -n1 | awk '{print $NF}')")"
if [ -d "${GV_LIBDIR}/graphviz" ]; then
  cp -r "${GV_LIBDIR}/graphviz"/* "${APPDIR}/usr/lib/graphviz/" 2>/dev/null || true
fi
# bundle shared library deps of dot (ldd-resolved), skip base libc/ld
for lib in $(ldd "${DOT_BIN}" | awk '{print $3}' | grep -v '^$'); do
  case "$lib" in
    */libc.so*|*/libpthread.so*|*/libdl.so*|*/librt.so*|*/libm.so*|*/ld-linux*) ;;
    *) cp -n "$lib" "${APPDIR}/usr/lib/" 2>/dev/null || true ;;
  esac
done

# ---------------------------------------------------------------------------
# 3. AppRun launcher
# ---------------------------------------------------------------------------
echo "==> Writing AppRun"
cat > "${APPDIR}/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "${0}")")"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH:-}"
export PATH="${HERE}/usr/bin:${HERE}/usr/venv/bin:${PATH}"
export GVBINDIR="${HERE}/usr/lib/graphviz"
# Invoke the bundled venv's own interpreter explicitly (not via PATH or
# the script's shebang) so it always uses the packaged wireviz install,
# regardless of what Python is or isn't present on the host system.
exec "${HERE}/usr/venv/bin/python3" "${HERE}/usr/venv/bin/wireviz" "$@"
EOF
chmod +x "${APPDIR}/AppRun"

# ---------------------------------------------------------------------------
# 4. Desktop entry + icon
# ---------------------------------------------------------------------------
echo "==> Writing desktop entry"
cat > "${APPDIR}/${APP}.desktop" <<EOF
[Desktop Entry]
Name=WireViz
Comment=Document cables and wiring harnesses from YAML
Exec=AppRun %f
Icon=wireviz
Type=Application
Categories=Utility;Engineering;
Terminal=true
EOF
cp "${APPDIR}/${APP}.desktop" "${APPDIR}/usr/share/applications/"

# Minimal placeholder icon (replace with a real one if you have it)
python3 - "${APPDIR}/usr/share/icons/hicolor/256x256/apps/wireviz.png" <<'PY'
import sys, struct, zlib
path = sys.argv[1]
w = h = 256
def chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data +
            struct.pack('>I', zlib.crc32(tag + data)))
sig = b'\x89PNG\r\n\x1a\n'
ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
raw = b''.join(b'\x00' + bytes([30, 90, 160]) * w for _ in range(h))
idat = chunk(b'IDAT', zlib.compress(raw, 9))
iend = chunk(b'IEND', b'')
with open(path, 'wb') as f:
    f.write(sig + ihdr + idat + iend)
PY
cp "${APPDIR}/usr/share/icons/hicolor/256x256/apps/wireviz.png" "${APPDIR}/wireviz.png"

# ---------------------------------------------------------------------------
# 5. Fetch appimagetool and build the AppImage
# ---------------------------------------------------------------------------
echo "==> Fetching appimagetool"
APPIMAGETOOL="${BUILD_DIR}/appimagetool"
wget -q -O "${APPIMAGETOOL}" \
  "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${ARCH}.AppImage"
chmod +x "${APPIMAGETOOL}"

echo "==> Running appimagetool"
OUTPUT_NAME="wireviz-0.41.AppImage"
# appimagetool is itself an AppImage and needs FUSE to run normally.
# Many CI runners (e.g. GitHub Actions) don't have FUSE available, so
# fall back to --appimage-extract-and-run, which works everywhere.
if ARCH="${ARCH}" "${APPIMAGETOOL}" "${APPDIR}" "${BUILD_DIR}/${OUTPUT_NAME}" 2>/tmp/appimagetool.err; then
  :
elif grep -q "libfuse" /tmp/appimagetool.err; then
  echo "    FUSE not available, retrying with --appimage-extract-and-run"
  ARCH="${ARCH}" "${APPIMAGETOOL}" --appimage-extract-and-run "${APPDIR}" "${BUILD_DIR}/${OUTPUT_NAME}"
else
  cat /tmp/appimagetool.err >&2
  exit 1
fi

echo
echo "==> Done: ${BUILD_DIR}/${OUTPUT_NAME}"
echo "    Run it with: ./${OUTPUT_NAME} path/to/mywire.yml"
