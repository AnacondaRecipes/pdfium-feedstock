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
# Neutralize legacy_gn.patch — build_native.py unconditionally git-applies it,
# but our GN (v2342+) supports path_exists() natively so the original patch conflicts.
python3 -c "
with open('$SRC_DIR/setupsrc/build_native.py') as f: c = f.read()
c = c.replace('git_apply_patch(PatchDir/\"legacy_gn.patch\"', 'pass  # skip legacy_gn.patch (new GN)  #')
with open('$SRC_DIR/setupsrc/build_native.py', 'w') as f: f.write(c)
print('Patched out legacy_gn.patch from build_native.py')
"

python3 -c "
import build_native
# DefaultConfig already disables v8, xfa, skia, glib, partition_alloc
build_native.main(build_ver=${PKG_VERSION})
"

# Find the built static library
PDFIUM_SRC_DIR=$(find "$SRC_DIR" -name "pdfium" -type d -path "*/pdfium" | head -1)
STATIC_LIB=$(find "$SRC_DIR" -name "libpdfium.a" -type f | head -1)
echo "Pdfium source: $PDFIUM_SRC_DIR"
echo "Static lib: $STATIC_LIB"

if [[ -z "$STATIC_LIB" ]]; then
    echo "ERROR: libpdfium.a not found"
    find "$SRC_DIR" -name "*pdfium*" -type f 2>/dev/null | head -10
    exit 1
fi

# --- Create shared library (same approach as PR#2) ---
echo "=== Creating shared library ==="

# Stub for hidden HarfBuzz CFF2 symbol (HB_INTERNAL visibility)
cat > /tmp/hb_cff2_stub.cc << 'STUB'
struct hb_font_t;
struct hb_glyph_extents_t;
namespace OT { namespace cff2 {
struct accelerator_t {
    bool get_extents(hb_font_t*, unsigned int, hb_glyph_extents_t*) const;
};
bool accelerator_t::get_extents(hb_font_t*, unsigned int, hb_glyph_extents_t*) const {
    return false;
}
}}
STUB
${CXX:-clang++} -c -fPIC -o /tmp/hb_cff2_stub.o /tmp/hb_cff2_stub.cc

if [[ "$(uname)" == "Darwin" ]]; then
    SDK_PATH=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
    ${CXX:-clang++} -shared -all_load \
        -Wl,-install_name,@rpath/libpdfium.dylib \
        -isysroot "$SDK_PATH" \
        -framework AppKit -framework CoreFoundation \
        -o "${STATIC_LIB%.a}.dylib" \
        "$STATIC_LIB" /tmp/hb_cff2_stub.o 2>&1
    LIBFILE="${STATIC_LIB%.a}.dylib"
else
    ${CXX:-clang++} -shared -Wl,--whole-archive \
        "$STATIC_LIB" \
        -Wl,--no-whole-archive \
        /tmp/hb_cff2_stub.o \
        -Wl,-soname,libpdfium.so \
        -lpthread -lm -ldl \
        -o "${STATIC_LIB%.a}.so" 2>&1
    LIBFILE="${STATIC_LIB%.a}.so"
fi
echo "Shared library: $(ls -lh "$LIBFILE")"

# --- Install ---
echo "=== Installing ==="
mkdir -p "$PREFIX/lib" "$PREFIX/include"
install -m 0755 "$LIBFILE" "$PREFIX/lib/$(basename "$LIBFILE")"

# Install headers
HEADER_DIR=$(find "$PDFIUM_SRC_DIR" -name "fpdfview.h" -path "*/public/*" -type f -exec dirname {} \; | head -1)
if [[ -n "$HEADER_DIR" ]]; then
    for header in "$HEADER_DIR"/fpdf*.h; do
        install -m 0644 "$header" "$PREFIX/include/"
    done
fi

echo "=== Done: $(ls $PREFIX/include/fpdf*.h 2>/dev/null | wc -l) headers ==="
