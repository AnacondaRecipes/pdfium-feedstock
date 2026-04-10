#!/bin/bash
set -euo pipefail

# Build pdfium using pypdfium2-team's native build system (build_native.py).
# This avoids depot_tools and handles GN configuration, dependency fetching,
# and compiler integration automatically.
echo "=== Building PDFium via pypdfium2 native build system ==="

# The source is the pypdfium2 sdist which contains setupsrc/build_native.py
cd setupsrc

# build_native.py needs gn and ninja in PATH
# GN: try conda-forge first, fall back to CIPD, then build from source
if ! command -v gn &>/dev/null || [[ $(gn --version 2>/dev/null | cut -d' ' -f1) -lt 2300 ]]; then
    echo "GN too old or missing, acquiring newer version..."
    GN_REV="6e8dcdebbadf4f8aa75e6a4b6e0bdf89dce1513a"
    if [[ "$(uname)" == "Darwin" ]]; then
        GN_PLAT="mac-$([[ "$(uname -m)" == "arm64" ]] && echo arm64 || echo amd64)"
    else
        GN_PLAT="linux-$([[ "$(uname -m)" == "aarch64" ]] && echo arm64 || echo amd64)"
    fi
    mkdir -p "$SRC_DIR/gn_bin"
    python3 -c "
import urllib.request, time, sys
url = 'https://chrome-infra-packages.appspot.com/dl/gn/gn/${GN_PLAT}/+/git_revision:${GN_REV}'
for i in range(3):
    try:
        urllib.request.urlretrieve(url, '$SRC_DIR/gn_bin/gn.zip')
        sys.exit(0)
    except: pass
    if i < 2: time.sleep(5*(i+1))
sys.exit(1)
" && (cd "$SRC_DIR/gn_bin" && unzip -oq gn.zip && chmod +x gn) || {
        echo "CIPD unavailable, building GN from source..."
        git clone https://gn.googlesource.com/gn.git "$SRC_DIR/gn_src"
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i.bak "s/-mmacosx-version-min=14/-mmacosx-version-min=11.0/" "$SRC_DIR/gn_src/build/gen.py"
        fi
        (cd "$SRC_DIR/gn_src" && CC="${CC:-cc}" CXX="${CXX:-c++}" AR="${AR:-ar}" \
            python3 build/gen.py --allow-warnings && ninja -C out gn)
        mkdir -p "$SRC_DIR/gn_bin" && cp "$SRC_DIR/gn_src/out/gn" "$SRC_DIR/gn_bin/gn"
    }
    export PATH="$SRC_DIR/gn_bin:$PATH"
fi
echo "GN: $(gn --version)"
echo "Ninja: $(ninja --version)"

# Run pypdfium2's native build system
# It clones pdfium source, fetches deps from DEPS file, configures GN, builds with ninja
echo "=== Running build_native.py ==="
python3 -c "
import build_native, base
# Build pdfium at the pinned version
build_native.main(
    build_ver=${PKG_VERSION},
    gn_args='pdf_enable_v8=false pdf_enable_xfa=false pdf_use_skia=false pdf_use_partition_alloc=false pdf_bundle_freetype=true use_glib=false',
)
"

# Find the built library
PDFIUM_DIR="$SRC_DIR/data/sourcebuild-native"
echo "Build output:"
ls -lh "$PDFIUM_DIR/" 2>/dev/null || true
find "$SRC_DIR" -name "libpdfium.*" -type f 2>/dev/null | head -5

# --- Install ---
echo "=== Installing ==="
mkdir -p "$PREFIX/lib" "$PREFIX/include"

# Install shared library
if [[ "$(uname)" == "Darwin" ]]; then
    LIBFILE=$(find "$SRC_DIR" -name "libpdfium.dylib" -type f | head -1)
else
    LIBFILE=$(find "$SRC_DIR" -name "libpdfium.so" -type f | head -1)
fi

if [[ -z "$LIBFILE" ]]; then
    echo "ERROR: libpdfium not found. Checking build artifacts..."
    find "$SRC_DIR" -name "libpdfium*" -type f 2>/dev/null
    find "$SRC_DIR" -name "pdfium*" -type f 2>/dev/null | head -10
    exit 1
fi

echo "Installing $LIBFILE"
install -m 0755 "$LIBFILE" "$PREFIX/lib/"

# Install headers from the pdfium source checkout
PDFIUM_SRC=$(find "$SRC_DIR" -name "fpdfview.h" -path "*/public/*" -type f | head -1)
if [[ -n "$PDFIUM_SRC" ]]; then
    HEADER_DIR=$(dirname "$PDFIUM_SRC")
    for header in "$HEADER_DIR"/fpdf*.h; do
        install -m 0644 "$header" "$PREFIX/include/"
    done
fi

echo "=== Done: $(ls $PREFIX/include/fpdf*.h 2>/dev/null | wc -l) headers ==="
