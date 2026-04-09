#!/bin/bash
set -euo pipefail

echo "=== Building PDFium from source ==="
echo "PDFium branch: chromium/${PKG_VERSION}"

# --- Helper function to extract revision from DEPS ---
get_rev() {
    grep "'${1}_revision'" DEPS | head -1 | sed "s/.*'\([a-f0-9]\{40\}\)'.*/\1/"
}

# --- Helper to clone a dependency at a specific revision ---
clone_dep() {
    local dest="$1"
    local url="$2"
    local rev="$3"
    if [ -d "$dest" ]; then
        echo "  SKIP: $dest (exists)"
        return
    fi
    echo "  CLONE: $dest @ ${rev:0:12}"
    git clone --depth 1 "$url" "$dest" || {
        echo "  RETRY: shallow clone failed, trying full clone..."
        rm -rf "$dest"
        git clone "$url" "$dest"
        (cd "$dest" && git checkout "$rev")
    }
}

# --- 1. Fetch dependencies from DEPS file ---
echo "=== Fetching dependencies ==="
CHROMIUM_GIT="https://chromium.googlesource.com"

# Build system
clone_dep "build" \
    "$CHROMIUM_GIT/chromium/src/build.git" \
    "$(get_rev build)"

clone_dep "buildtools" \
    "$CHROMIUM_GIT/chromium/src/buildtools.git" \
    "$(get_rev buildtools)"

# Core C++ deps
clone_dep "base/allocator/partition_allocator" \
    "$CHROMIUM_GIT/chromium/src/base/allocator/partition_allocator.git" \
    "$(get_rev partition_allocator)"

clone_dep "third_party/abseil-cpp" \
    "$CHROMIUM_GIT/chromium/src/third_party/abseil-cpp.git" \
    "$(get_rev abseil)"

clone_dep "third_party/fast_float/src" \
    "$CHROMIUM_GIT/external/github.com/fastfloat/fast_float.git" \
    "$(get_rev fast_float)"

clone_dep "third_party/fp16/src" \
    "$CHROMIUM_GIT/external/github.com/Maratyszcza/FP16.git" \
    "$(get_rev fp16)"

# Graphics/font
clone_dep "third_party/freetype/src" \
    "$CHROMIUM_GIT/chromium/src/third_party/freetype2.git" \
    "$(get_rev freetype)"

clone_dep "third_party/harfbuzz/src" \
    "$CHROMIUM_GIT/external/github.com/harfbuzz/harfbuzz.git" \
    "$(get_rev harfbuzz)"

clone_dep "third_party/icu" \
    "$CHROMIUM_GIT/chromium/deps/icu.git" \
    "$(get_rev icu)"

# Image format libraries
clone_dep "third_party/libpng" \
    "$CHROMIUM_GIT/chromium/src/third_party/libpng.git" \
    "$(get_rev libpng)"

clone_dep "third_party/libjpeg_turbo" \
    "$CHROMIUM_GIT/chromium/deps/libjpeg_turbo.git" \
    "$(get_rev jpeg_turbo)"

clone_dep "third_party/zlib" \
    "$CHROMIUM_GIT/chromium/src/third_party/zlib.git" \
    "$(get_rev zlib)"

clone_dep "third_party/brotli" \
    "$CHROMIUM_GIT/chromium/src/third_party/brotli.git" \
    "$(get_rev brotli)"

# Build templates (jinja2 for GN code generation)
clone_dep "third_party/jinja2" \
    "$CHROMIUM_GIT/chromium/src/third_party/jinja2.git" \
    "$(get_rev jinja2)"

clone_dep "third_party/markupsafe" \
    "$CHROMIUM_GIT/chromium/src/third_party/markupsafe.git" \
    "$(get_rev markupsafe)"

# C++ standard library sources (referenced by build system, not linked)
clone_dep "third_party/libc++/src" \
    "$CHROMIUM_GIT/external/github.com/llvm/llvm-project/libcxx.git" \
    "$(get_rev libcxx)"

clone_dep "third_party/libc++abi/src" \
    "$CHROMIUM_GIT/external/github.com/llvm/llvm-project/libcxxabi.git" \
    "$(get_rev libcxxabi)"

# Test framework (BUILD.gn references this)
clone_dep "third_party/googletest/src" \
    "$CHROMIUM_GIT/external/github.com/google/googletest.git" \
    "$(get_rev gtest)"

# Clang format scripts (referenced by build files)
clone_dep "third_party/clang-format/script" \
    "$CHROMIUM_GIT/external/github.com/llvm/llvm-project/clang/tools/clang-format.git" \
    "$(get_rev clang_format)"

# NASM (for libjpeg-turbo SIMD)
clone_dep "third_party/nasm" \
    "$CHROMIUM_GIT/chromium/deps/nasm.git" \
    "$(get_rev nasm_source)"

echo "=== Dependencies fetched ==="

# --- 2. Download GN binary ---
# GN (Generate Ninja) build tool. conda-forge's version is too old (v2231,
# need v2354+). Google publishes the correct version via CIPD.
GN_REV=$(grep "'gn_version'" DEPS | head -1 | sed "s/.*git_revision:\([a-f0-9]*\).*/\1/")
echo "GN revision: $GN_REV"

if [[ "$(uname)" == "Darwin" ]]; then
    GN_PLATFORM="mac-$([[ "$(uname -m)" == "arm64" ]] && echo arm64 || echo amd64)"
else
    GN_PLATFORM="linux-$([[ "$(uname -m)" == "aarch64" ]] && echo arm64 || echo amd64)"
fi

echo "Downloading GN for ${GN_PLATFORM}..."
curl -sL --fail "https://chrome-infra-packages.appspot.com/dl/gn/gn/${GN_PLATFORM}/+/git_revision:${GN_REV}" -o gn.zip
unzip -oq gn.zip -d gn_bin
chmod +x gn_bin/gn
GN="$(pwd)/gn_bin/gn"
echo "GN version: $($GN --version)"

# --- 3. Create build configuration stubs ---
mkdir -p build/config
cat > build/config/gclient_args.gni <<'GNI'
build_with_chromium = false
checkout_android = false
checkout_skia = false
GNI

# Stubs for test-only deps (build graph references but we don't build)
mkdir -p third_party/test_fonts
echo 'group("test_fonts") { testonly = true }' > third_party/test_fonts/BUILD.gn
mkdir -p third_party/simdutf
echo 'group("simdutf") {}' > third_party/simdutf/BUILD.gn

# --- 4. Set up compiler integration ---
echo "CC=$CC CXX=$CXX"
echo "BUILD_PREFIX=$BUILD_PREFIX"
CLANG_MAJOR=$(${CC:-clang} -dumpversion 2>/dev/null | cut -d. -f1 || echo "17")
echo "Compiler: $(${CC:-clang} --version 2>&1 | head -1)"
echo "Clang major version: $CLANG_MAJOR"

# Create clang version stubs for Chromium's consistency checks
CLANG_DIR="third_party/llvm-build/Release+Asserts"
mkdir -p "${CLANG_DIR}/bin"
mkdir -p "${CLANG_DIR}/lib"
echo "llvmorg-${CLANG_MAJOR}-init-0-0" > "${CLANG_DIR}/cr_build_revision"
mkdir -p tools/clang/scripts
cat > tools/clang/scripts/update.py <<PYEOF
CLANG_REVISION = 'llvmorg-${CLANG_MAJOR}-init-0'
CLANG_SUB_REVISION = 0
PYEOF

# Symlink our compiler into the expected location
# On conda, CC may be a wrapper script like x86_64-conda-linux-gnu-clang
CC_REAL=$(which ${CC:-clang} 2>/dev/null || echo "")
CXX_REAL=$(which ${CXX:-clang++} 2>/dev/null || echo "")
echo "CC_REAL=$CC_REAL CXX_REAL=$CXX_REAL"

if [[ -n "$CC_REAL" ]]; then
    ln -sf "$CC_REAL" "${CLANG_DIR}/bin/clang"
    ln -sf "${CXX_REAL:-$CC_REAL}" "${CLANG_DIR}/bin/clang++"
else
    echo "WARNING: No CC found, using system clang"
    ln -sf "$(which clang)" "${CLANG_DIR}/bin/clang"
    ln -sf "$(which clang++)" "${CLANG_DIR}/bin/clang++"
fi

# Link compiler runtime libraries
# On Linux, Chromium expects: lib/clang/<ver>/lib/<triple>/libclang_rt.builtins.a
# conda may use a different layout, so we create the expected structure.
CLANG_LIB_DIR=""
for search_dir in "${BUILD_PREFIX:-/usr}/lib/clang" "${PREFIX}/lib/clang" "/usr/lib/clang"; do
    if [[ -d "$search_dir" ]]; then
        CLANG_LIB_DIR=$(find "$search_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
        if [[ -n "$CLANG_LIB_DIR" ]]; then
            break
        fi
    fi
done
echo "CLANG_LIB_DIR=$CLANG_LIB_DIR"
if [[ -n "$CLANG_LIB_DIR" ]]; then
    mkdir -p "${CLANG_DIR}/lib/clang/${CLANG_MAJOR}"
    # Symlink the entire lib subdirectory
    if [[ -d "$CLANG_LIB_DIR/lib" ]]; then
        ln -sf "$CLANG_LIB_DIR/lib" "${CLANG_DIR}/lib/clang/${CLANG_MAJOR}/lib"
    fi

    # On Linux, ensure the triple-specific directory exists with builtins
    if [[ "$(uname)" == "Linux" ]]; then
        TRIPLE=$($CC -dumpmachine 2>/dev/null || echo "x86_64-unknown-linux-gnu")
        # Chromium uses x86_64-unknown-linux-gnu but conda may use x86_64-conda-linux-gnu
        CHROMIUM_TRIPLE=$(echo "$TRIPLE" | sed 's/-conda-/-unknown-/')
        BUILTINS_DIR="${CLANG_DIR}/lib/clang/${CLANG_MAJOR}/lib/${CHROMIUM_TRIPLE}"
        mkdir -p "$BUILTINS_DIR"

        # Find the actual builtins library wherever it may be
        BUILTINS=$(find "${BUILD_PREFIX:-/usr}/lib" "${PREFIX}/lib" -name "libclang_rt.builtins*.a" -path "*/clang/*" 2>/dev/null | head -1)
        echo "BUILTINS=$BUILTINS"
        if [[ -n "$BUILTINS" ]]; then
            ln -sf "$BUILTINS" "${BUILTINS_DIR}/libclang_rt.builtins.a"
        fi

        # Also link any other runtime libs that may be needed
        BUILTINS_SRC_DIR=$(dirname "$BUILTINS" 2>/dev/null)
        if [[ -n "$BUILTINS_SRC_DIR" && -d "$BUILTINS_SRC_DIR" ]]; then
            for lib in "$BUILTINS_SRC_DIR"/libclang_rt.*.a; do
                if [[ -f "$lib" ]]; then
                    ln -sf "$lib" "${BUILTINS_DIR}/$(basename "$lib")"
                fi
            done
        fi
    fi
fi

# --- 5. Apply patches ---
echo "=== Applying build system patches ==="

# Patch: macOS SDK detection for CLI-tools-only (no Xcode.app)
if [[ "$(uname)" == "Darwin" ]] && [[ -f build/mac/find_sdk.py ]]; then
    python3 << 'PATCH_SDK'
with open('build/mac/find_sdk.py', 'r') as f:
    content = f.read()
old = """  if not os.path.isdir(sdk_dir):
    raise SdkError('Install Xcode"""
new = """  if not os.path.isdir(sdk_dir):
    sdk_dir = os.path.join(dev_dir, 'SDKs')
  if not os.path.isdir(sdk_dir):
    raise SdkError('Install Xcode"""
content = content.replace(old, new)
with open('build/mac/find_sdk.py', 'w') as f:
    f.write(content)
PATCH_SDK

    # Patch: sdk_info.py — handle xcodebuild not available
    python3 << 'PATCH_SDKINFO'
with open('build/config/apple/sdk_info.py', 'r') as f:
    content = f.read()
old = """  lines = subprocess.check_output(['xcodebuild',
                                   '-version']).decode('UTF-8').splitlines()
  version_verbatim = lines[0].split()[-1]
  settings['xcode_version'] = FormatVersion(version_verbatim)
  settings['xcode_version_int'] = int(settings['xcode_version'], 10)
  settings['xcode_version_verbatim'] = version_verbatim
  settings['xcode_build'] = lines[-1].split()[-1]"""
new = """  try:
    lines = subprocess.check_output(['xcodebuild',
                                     '-version']).decode('UTF-8').splitlines()
    version_verbatim = lines[0].split()[-1]
    settings['xcode_version'] = FormatVersion(version_verbatim)
    settings['xcode_version_int'] = int(settings['xcode_version'], 10)
    settings['xcode_version_verbatim'] = version_verbatim
    settings['xcode_build'] = lines[-1].split()[-1]
  except (subprocess.CalledProcessError, FileNotFoundError):
    settings['xcode_version'] = '1700'
    settings['xcode_version_int'] = 1700
    settings['xcode_version_verbatim'] = '17.0'
    settings['xcode_build'] = '17A0'"""
content = content.replace(old, new)
with open('build/config/apple/sdk_info.py', 'w') as f:
    f.write(content)
PATCH_SDKINFO
fi

# Patch: Remove Chromium-trunk-only clang flags
# -fno-lifetime-dse: GCC-only flag, not in released LLVM clang
# -fsanitize-ignore-for-ubsan-feature: Chromium trunk clang (v23+)
python3 << 'PATCH_FLAGS'
# Patch compiler flags
with open('build/config/compiler/BUILD.gn', 'r') as f:
    content = f.read()
content = content.replace(
    'cflags += [ "-fno-lifetime-dse" ]',
    '# Patched: -fno-lifetime-dse removed (not in released LLVM clang)'
)
with open('build/config/compiler/BUILD.gn', 'w') as f:
    f.write(content)

# Patch sanitizer flags
with open('build/config/sanitizers/sanitizers.gni', 'r') as f:
    content = f.read()
content = content.replace(
    '"-fsanitize-ignore-for-ubsan-feature=${invoker.sanitizer}",',
    '# Patched: -fsanitize-ignore-for-ubsan-feature removed (requires trunk clang)'
)
with open('build/config/sanitizers/sanitizers.gni', 'w') as f:
    f.write(content)
PATCH_FLAGS

# --- 6. Generate export symbol list for shared library ---
# PDFium builds with -fvisibility=hidden; we need to export the public FPDF API.
echo "=== Generating symbol export list ==="
mkdir -p out
python3 << 'EXPORT_SYMBOLS'
import glob, re, os

symbols = []
for header in sorted(glob.glob("public/fpdf*.h")):
    with open(header) as f:
        for line in f:
            m = re.match(r'FPDF_EXPORT\s+\w.*?\s+(FPDF\w+)\s*\(', line)
            if m:
                symbols.append(m.group(1))

if os.uname().sysname == "Darwin":
    with open("out/pdfium.export_list", "w") as f:
        for s in symbols:
            f.write(f"_{s}\n")
    print(f"macOS export list: {len(symbols)} symbols")
else:
    with open("out/pdfium.version_script", "w") as f:
        f.write("{\n  global:\n")
        for s in symbols:
            f.write(f"    {s};\n")
        f.write("  local:\n    *;\n};\n")
    print(f"Linux version script: {len(symbols)} symbols")
EXPORT_SYMBOLS

# --- 7. Configure GN ---
echo "=== Configuring build ==="
mkdir -p out/Release
# On Linux with conda clang, we need to set the sysroot for system headers
EXTRA_CFLAGS=""
EXTRA_LDFLAGS=""
if [[ "$(uname)" == "Linux" ]]; then
    CONDA_SYSROOT="${BUILD_PREFIX}/${HOST:-x86_64-conda-linux-gnu}/sysroot"
    if [[ ! -d "$CONDA_SYSROOT" ]]; then
        CONDA_SYSROOT="${PREFIX}/${HOST:-x86_64-conda-linux-gnu}/sysroot"
    fi
    if [[ -d "$CONDA_SYSROOT" ]]; then
        echo "Using sysroot: $CONDA_SYSROOT"
        EXTRA_CFLAGS="\"--sysroot=${CONDA_SYSROOT}\","
        EXTRA_LDFLAGS="\"--sysroot=${CONDA_SYSROOT}\","
    fi
fi

cat > out/Release/args.gn <<ARGS
is_debug = false
pdf_is_standalone = true
pdf_enable_v8 = false
pdf_enable_xfa = false
pdf_use_skia = false
pdf_use_partition_alloc = false
pdf_bundle_freetype = true
is_component_build = false
treat_warnings_as_errors = false
use_custom_libcxx = false
use_sysroot = false
clang_use_chrome_plugins = false
use_thin_lto = false
pdf_is_complete_lib = true
use_lld = false
use_glib = false
clang_version = "${CLANG_MAJOR}"
ARGS

# Append sysroot flags if needed
if [[ -n "$EXTRA_CFLAGS" ]]; then
    cat >> out/Release/args.gn <<SYSROOT
extra_cflags = [${EXTRA_CFLAGS}]
extra_ldflags = [${EXTRA_LDFLAGS}]
SYSROOT
fi

$GN gen out/Release
echo "GN generated $(grep -c 'target' out/Release/build.ninja 2>/dev/null || echo '?') rules"

# --- 8. Build ---
NCPU=${CPU_COUNT:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}
echo "=== Building pdfium (-j${NCPU}) ==="
ninja -C out/Release pdfium -j${NCPU}
echo "Static library:"
ls -lah out/Release/obj/libpdfium.a

# --- 9. Create shared library from static archive ---
echo "=== Creating shared library ==="
if [[ "$(uname)" == "Darwin" ]]; then
    SDK_PATH=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
    ${CXX:-clang++} -shared -all_load \
        -Wl,-install_name,@rpath/libpdfium.dylib \
        -isysroot "$SDK_PATH" \
        -framework AppKit -framework CoreFoundation \
        -Wl,-exported_symbols_list,out/pdfium.export_list \
        -o out/Release/libpdfium.dylib \
        out/Release/obj/libpdfium.a
    LIBFILE="libpdfium.dylib"
else
    ${CXX:-clang++} -shared -Wl,--whole-archive \
        out/Release/obj/libpdfium.a \
        -Wl,--no-whole-archive \
        -Wl,-soname,libpdfium.so \
        -Wl,--version-script=out/pdfium.version_script \
        -lpthread -lm -ldl \
        -o out/Release/libpdfium.so
    LIBFILE="libpdfium.so"
fi
echo "Shared library:"
ls -lah out/Release/${LIBFILE}

# --- 10. Install ---
echo "=== Installing ==="
mkdir -p "$PREFIX/lib" "$PREFIX/include"

install -m 0755 "out/Release/${LIBFILE}" "$PREFIX/lib/"

for header in public/fpdf*.h; do
    install -m 0644 "$header" "$PREFIX/include/"
done

echo "=== Installed $(ls $PREFIX/include/fpdf*.h | wc -l) headers and ${LIBFILE} ==="
