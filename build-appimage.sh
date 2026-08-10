#!/usr/bin/env bash
#
# build-appimage.sh — Package WireViz (https://github.com/wireviz/WireViz)
# as a self-contained AppImage.
#
# WireViz is a pure-Python CLI tool, so this script:
#   1. Installs `uv` and uses it to download a portable, relocatable
#      CPython build (uv fetches the same astral-sh/python-build-standalone
#      builds it uses for `uv python install`) rather than relying on the
#      OS's system Python. Distro Python packages (apt/dnf) bake an
#      absolute /usr prefix into the interpreter at compile time, which
#      breaks the moment the AppImage runs on a machine without that exact
#      Python version at that exact path — this is what caused the earlier
#      "ModuleNotFoundError: No module named 'encodings'" failure.
#   2. pip-installs wireviz (and its Python deps) into that interpreter
#   3. Bundles a static/portable Graphviz `dot` binary (wireviz's one
#      external, non-Python dependency) so the AppImage works even on
#      systems without Graphviz installed
#   4. Wraps it all with an AppRun launcher, .desktop file and icon
#   5. Downloads appimagetool and runs it to produce the final .AppImage
#
# Requirements to RUN this script: a Linux x86_64 machine, internet
# access, and `curl`/`wget`/`tar`. A local Python installation is NOT
# required — `uv` and the interpreter it fetches are both downloaded
# fresh, so the result is reproducible regardless of what's on the
# build machine. It does NOT need Graphviz pre-installed either (we
# vendor it), but if system Graphviz is missing the script will fall
# back to apt-get to fetch just the `dot` binary for bundling.
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
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"  # portable interpreter minor version
APP=WireViz
BUILD_DIR="$(pwd)/build"
APPDIR="${BUILD_DIR}/${APP}.AppDir"
ARCH="x86_64"

echo "==> Building ${APP} AppImage (wireviz==${WIREVIZ_VERSION}, python ${PYTHON_VERSION})"

rm -rf "${BUILD_DIR}"
mkdir -p "${APPDIR}/usr/bin" "${APPDIR}/usr/lib" "${APPDIR}/usr/share/applications" \
         "${APPDIR}/usr/share/icons/hicolor/256x256/apps"

# ---------------------------------------------------------------------------
# 1. Portable, relocatable Python interpreter + WireViz installed into it
# ---------------------------------------------------------------------------
# We fetch the interpreter via `uv` (astral-sh/uv) rather than querying the
# python-build-standalone GitHub API and regex-matching an asset filename
# ourselves: which exact assets exist for which Python version varies by
# release date (some dates don't carry every version), which made a
# hand-rolled lookup fragile. `uv` already solves that reliably since this
# is exactly its job.
echo "==> Installing uv (used to fetch a portable Python build)"
curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
export PATH="${HOME}/.local/bin:${PATH}"

echo "==> Fetching portable Python ${PYTHON_VERSION} via uv"
export UV_PYTHON_INSTALL_DIR="${BUILD_DIR}/uv-python"
uv python install "${PYTHON_VERSION}"

PYROOT="$(find "${UV_PYTHON_INSTALL_DIR}" -maxdepth 1 -type d \
  -name "cpython-${PYTHON_VERSION}.*-linux-x86_64-gnu*" | sort | tail -n1)"
if [ -z "${PYROOT}" ]; then
  echo "Could not locate an installed Python ${PYTHON_VERSION} under ${UV_PYTHON_INSTALL_DIR}" >&2
  exit 1
fi
echo "    using ${PYROOT}"

cp -a "${PYROOT}" "${APPDIR}/usr/pyruntime"

# uv marks its managed interpreters as PEP 668 "externally managed" to
# stop `pip install` from touching them directly. That protection is
# for uv's own managed store; it's meaningless (and just gets in the
# way) once we've copied the interpreter out into our own AppDir, so
# drop the marker before installing wireviz into it.
find "${APPDIR}/usr/pyruntime" -name 'EXTERNALLY-MANAGED' -delete

# The extracted binary may be named python3.X rather than python3; AppRun
# always invokes .../bin/python3 explicitly, so make sure that name exists.
if [ ! -e "${APPDIR}/usr/pyruntime/bin/python3" ]; then
  REAL_PY="$(basename "$(ls "${APPDIR}/usr/pyruntime/bin"/python3.[0-9]* | head -n1)")"
  ln -sf "${REAL_PY}" "${APPDIR}/usr/pyruntime/bin/python3"
fi
PYBIN="${APPDIR}/usr/pyruntime/bin/python3"

"${PYBIN}" -m ensurepip --upgrade >/dev/null 2>&1 || true
"${PYBIN}" -m pip install --upgrade pip wheel >/dev/null
"${PYBIN}" -m pip install "wireviz==${WIREVIZ_VERSION}"

# NOTE: do NOT rewrite shebang lines in usr/pyruntime/bin/* — AppRun
# invokes the interpreter directly and explicitly (see below), so the
# shebang recorded by pip at build time is never used at runtime and
# doesn't matter either way. This whole usr/pyruntime directory is
# self-contained and relocatable as-is; that's the point of using a
# python-build-standalone-derived build instead of the OS's Python.

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
# usr/pyruntime/lib holds libpython3.x.so — needed since the portable
# build links it as a shared library.
export LD_LIBRARY_PATH="${HERE}/usr/lib:${HERE}/usr/pyruntime/lib:${LD_LIBRARY_PATH:-}"
export PATH="${HERE}/usr/bin:${HERE}/usr/pyruntime/bin:${PATH}"
export GVBINDIR="${HERE}/usr/lib/graphviz"
# Invoke the bundled interpreter explicitly (not via PATH or the
# script's shebang) so it always uses the packaged wireviz install,
# regardless of what Python is or isn't present on the host system.
exec "${HERE}/usr/pyruntime/bin/python3" "${HERE}/usr/pyruntime/bin/wireviz" "$@"
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
"${PYBIN}" - "${APPDIR}/usr/share/icons/hicolor/256x256/apps/wireviz.png" <<'PY'
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
