#!/bin/bash
set -euo pipefail

echo "=== Building PDFium from source (chromium/${PKG_VERSION}) ==="

# --- Helpers ---
get_rev() {
    grep "'${1}_revision'" DEPS | head -1 | sed "s/.*'\([a-f0-9]\{40\}\)'.*/\1/"
}

clone_dep() {
    local dest="$1" url="$2" rev="$3"
    if [ -d "$dest" ]; then return; fi
    echo "  CLONE: $dest @ ${rev:0:12}"
    git clone --depth 1 "$url" "$dest" || {
        rm -rf "$dest"
        git clone "$url" "$dest"
        (cd "$dest" && git checkout "$rev")
    }
}

# --- 1. Fetch dependencies from DEPS file ---
echo "=== Fetching dependencies ==="
G="https://chromium.googlesource.com"

clone_dep "build"                              "$G/chromium/src/build.git"              "$(get_rev build)"
clone_dep "buildtools"                         "$G/chromium/src/buildtools.git"          "$(get_rev buildtools)"
clone_dep "base/allocator/partition_allocator"  "$G/chromium/src/base/allocator/partition_allocator.git" "$(get_rev partition_allocator)"
clone_dep "third_party/abseil-cpp"             "$G/chromium/src/third_party/abseil-cpp.git" "$(get_rev abseil)"
clone_dep "third_party/fast_float/src"         "$G/external/github.com/fastfloat/fast_float.git" "$(get_rev fast_float)"
clone_dep "third_party/fp16/src"               "$G/external/github.com/Maratyszcza/FP16.git" "$(get_rev fp16)"
clone_dep "third_party/freetype/src"           "$G/chromium/src/third_party/freetype2.git" "$(get_rev freetype)"
clone_dep "third_party/harfbuzz/src"           "$G/external/github.com/harfbuzz/harfbuzz.git" "$(get_rev harfbuzz)"
clone_dep "third_party/icu"                    "$G/chromium/deps/icu.git"                "$(get_rev icu)"
# zlib + libpng are unvendored — provided by conda host deps via use_system_* GN args.
clone_dep "third_party/libjpeg_turbo"          "$G/chromium/deps/libjpeg_turbo.git"      "$(get_rev jpeg_turbo)"
clone_dep "third_party/brotli"                 "$G/chromium/src/third_party/brotli.git"  "$(get_rev brotli)"
clone_dep "third_party/jinja2"                 "$G/chromium/src/third_party/jinja2.git"  "$(get_rev jinja2)"
clone_dep "third_party/markupsafe"             "$G/chromium/src/third_party/markupsafe.git" "$(get_rev markupsafe)"
clone_dep "third_party/libc++/src"             "$G/external/github.com/llvm/llvm-project/libcxx.git" "$(get_rev libcxx)"
clone_dep "third_party/libc++abi/src"          "$G/external/github.com/llvm/llvm-project/libcxxabi.git" "$(get_rev libcxxabi)"
clone_dep "third_party/googletest/src"         "$G/external/github.com/google/googletest.git" "$(get_rev gtest)"
clone_dep "third_party/clang-format/script"    "$G/external/github.com/llvm/llvm-project/clang/tools/clang-format.git" "$(get_rev clang_format)"
clone_dep "third_party/nasm"                   "$G/chromium/deps/nasm.git"               "$(get_rev nasm_source)"

echo "=== Dependencies fetched ==="

# --- 2. Acquire GN (Generate Ninja) build tool ---
# conda-forge gn is too old (v2231, need v2354+). Try CIPD, fall back to source build.
GN_REV=$(grep "'gn_version'" DEPS | head -1 | sed "s/.*git_revision:\([a-f0-9]*\).*/\1/")
if [[ "$(uname)" == "Darwin" ]]; then
    GN_PLATFORM="mac-$([[ "$(uname -m)" == "arm64" ]] && echo arm64 || echo amd64)"
else
    GN_PLATFORM="linux-$([[ "$(uname -m)" == "aarch64" ]] && echo arm64 || echo amd64)"
fi

GN_DOWNLOADED=false
python3 -c "
import urllib.request, time, sys
url = 'https://chrome-infra-packages.appspot.com/dl/gn/gn/${GN_PLATFORM}/+/git_revision:${GN_REV}'
for attempt in range(3):
    try:
        urllib.request.urlretrieve(url, 'gn.zip')
        sys.exit(0)
    except Exception as e:
        print(f'CIPD attempt {attempt+1} failed: {e}')
        if attempt < 2: time.sleep(5 * (attempt + 1))
sys.exit(1)
" && GN_DOWNLOADED=true || true

if [[ "$GN_DOWNLOADED" == "true" ]]; then
    unzip -oq gn.zip -d gn_bin && chmod +x gn_bin/gn
else
    echo "CIPD unavailable, building GN from source..."
    git clone https://gn.googlesource.com/gn.git gn_src
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i.bak "s/-mmacosx-version-min=14/-mmacosx-version-min=11.0/" gn_src/build/gen.py
    fi
    (cd gn_src && CC="${CC:-cc}" CXX="${CXX:-c++}" AR="${AR:-ar}" \
        python3 build/gen.py --allow-warnings && ninja -C out gn)
    mkdir -p gn_bin && cp gn_src/out/gn gn_bin/gn && chmod +x gn_bin/gn
fi
GN="$(pwd)/gn_bin/gn"
echo "GN version: $($GN --version)"

# --- 3. Build system stubs ---
mkdir -p build/config
cat > build/config/gclient_args.gni <<'GNI'
build_with_chromium = false
checkout_android = false
checkout_skia = false
GNI

mkdir -p third_party/test_fonts
echo 'group("test_fonts") { testonly = true }' > third_party/test_fonts/BUILD.gn
mkdir -p third_party/simdutf
echo 'group("simdutf") {}' > third_party/simdutf/BUILD.gn

# --- 4. Compiler integration ---
CLANG_MAJOR=$(${CC:-clang} -dumpversion 2>/dev/null | cut -d. -f1 || echo "17")
echo "Compiler: $(${CC:-clang} --version 2>&1 | head -1) (major: $CLANG_MAJOR)"

CLANG_DIR="third_party/llvm-build/Release+Asserts"
mkdir -p "${CLANG_DIR}/bin" "${CLANG_DIR}/lib"
echo "llvmorg-${CLANG_MAJOR}-init-0-0" > "${CLANG_DIR}/cr_build_revision"
mkdir -p tools/clang/scripts
cat > tools/clang/scripts/update.py <<PYEOF
CLANG_REVISION = 'llvmorg-${CLANG_MAJOR}-init-0'
CLANG_SUB_REVISION = 0
PYEOF

# Wrapper scripts for compiler (symlinks break conda clang's resource dir lookup)
CC_REAL=$(which ${CC:-clang}) CXX_REAL=$(which ${CXX:-clang++})
for pair in "clang:$CC_REAL" "clang++:$CXX_REAL"; do
    name="${pair%%:*}" real="${pair#*:}"
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$real" > "${CLANG_DIR}/bin/${name}"
    chmod +x "${CLANG_DIR}/bin/${name}"
done

# Wrapper scripts for LLVM tools
for tool in llvm-ar llvm-nm llvm-readelf llvm-objcopy llvm-strip llvm-readobj; do
    TOOL_REAL=$(which ${tool} 2>/dev/null || which ar 2>/dev/null || true)
    if [[ -n "$TOOL_REAL" ]]; then
        printf '#!/bin/bash\nexec "%s" "$@"\n' "$TOOL_REAL" > "${CLANG_DIR}/bin/${tool}"
        chmod +x "${CLANG_DIR}/bin/${tool}"
    fi
done

# Link compiler runtime libraries
CLANG_LIB_DIR=$(find "${BUILD_PREFIX}/lib/clang" "${PREFIX}/lib/clang" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1 || true)
if [[ -n "$CLANG_LIB_DIR" ]]; then
    mkdir -p "${CLANG_DIR}/lib/clang/${CLANG_MAJOR}"
    # Symlink the entire lib tree (covers both linux/<triple>/ and darwin/ layouts)
    ln -sf "$CLANG_LIB_DIR/lib" "${CLANG_DIR}/lib/clang/${CLANG_MAJOR}/lib" 2>/dev/null || true

    if [[ "$(uname)" == "Linux" ]]; then
        # Linux: also create triple-specific dir with arch-less builtins symlink
        TRIPLE=$(echo "$($CC -dumpmachine)" | sed 's/-conda-/-unknown-/')
        BUILTINS_DIR="${CLANG_DIR}/lib/clang/${CLANG_MAJOR}/lib/${TRIPLE}"
        mkdir -p "$BUILTINS_DIR"
        BUILTINS=$(find "${BUILD_PREFIX}/lib" "${PREFIX}/lib" -name "libclang_rt.builtins*.a" -path "*/clang/*" 2>/dev/null | head -1 || true)
        if [[ -n "$BUILTINS" ]]; then
            ln -sf "$BUILTINS" "${BUILTINS_DIR}/libclang_rt.builtins.a"
            for lib in "$(dirname "$BUILTINS")"/libclang_rt.*.a; do
                ln -sf "$lib" "${BUILTINS_DIR}/$(basename "$lib")" 2>/dev/null || true
            done
        fi
    fi
fi

# --- 5. Apply build system patches ---
echo "=== Applying patches ==="

# macOS: SDK detection for CLI-tools-only (no Xcode.app)
if [[ "$(uname)" == "Darwin" ]]; then
    python3 << 'PATCH_MACOS'
# find_sdk.py: fallback to SDKs/ when Platforms/ doesn't exist
with open('build/mac/find_sdk.py', 'r') as f:
    c = f.read()
c = c.replace(
    "  if not os.path.isdir(sdk_dir):\n    raise SdkError('Install Xcode",
    "  if not os.path.isdir(sdk_dir):\n    sdk_dir = os.path.join(dev_dir, 'SDKs')\n  if not os.path.isdir(sdk_dir):\n    raise SdkError('Install Xcode"
)
with open('build/mac/find_sdk.py', 'w') as f:
    f.write(c)

# sdk_info.py: handle xcodebuild not available
with open('build/config/apple/sdk_info.py', 'r') as f:
    c = f.read()
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
c = c.replace(old, new)
with open('build/config/apple/sdk_info.py', 'w') as f:
    f.write(c)
PATCH_MACOS
fi

# All platforms: compiler flags, HarfBuzz, visibility, libatomic
python3 << 'PATCH_BUILD'
import os

# compiler/BUILD.gn: remove flags our conda clang doesn't accept
#  - -fno-lifetime-dse: GCC-only, not in LLVM clang
#  - -fdiagnostics-show-inlining-chain: trunk-clang flag (added in chromium/7891)
with open('build/config/compiler/BUILD.gn', 'r') as f:
    c = f.read()
c = c.replace('cflags += [ "-fno-lifetime-dse" ]', '# Patched: -fno-lifetime-dse removed')
c = c.replace('cflags += [ "-fdiagnostics-show-inlining-chain" ]', '# Patched: -fdiagnostics-show-inlining-chain removed')
with open('build/config/compiler/BUILD.gn', 'w') as f:
    f.write(c)

# sanitizers.gni: remove -fsanitize-ignore-for-ubsan-feature (clang 23+ trunk)
with open('build/config/sanitizers/sanitizers.gni', 'r') as f:
    c = f.read()
c = c.replace('"-fsanitize-ignore-for-ubsan-feature=${invoker.sanitizer}",',
              '# Patched: removed (requires trunk clang)')
with open('build/config/sanitizers/sanitizers.gni', 'w') as f:
    f.write(c)

# harfbuzz/BUILD.gn: fix CFF2 hidden symbol + enable subsetting
with open('third_party/harfbuzz/BUILD.gn', 'r') as f:
    c = f.read()
c = c.replace('if (is_component_build) {',
              'if (true) {  # Patched: export HarfBuzz symbols for shared lib', 1)
c = c.replace('"HB_NO_SUBSET_CFF",\n', '')  # enable CFF2 code
c = c.replace('defines -= [ "HB_NO_SUBSET_CFF" ]', '# Patched: HB_NO_SUBSET_CFF removed')
c = c.replace('"HAVE_OT",', '"HAVE_OT", "HB_NO_VISIBILITY=1", "HB_INTERNAL=",')
with open('third_party/harfbuzz/BUILD.gn', 'w') as f:
    f.write(c)

# gcc/BUILD.gn: default symbol visibility for shared lib export
with open('build/config/gcc/BUILD.gn', 'r') as f:
    c = f.read()
c = c.replace('cflags = [ "-fvisibility=hidden" ]',
              'cflags = [ "-fvisibility=default" ]  # Patched for shared lib')
with open('build/config/gcc/BUILD.gn', 'w') as f:
    f.write(c)

# linux/BUILD.gn: remove -latomic (not available in conda clang env)
if os.uname().sysname == 'Linux':
    with open('build/config/linux/BUILD.gn', 'r') as f:
        c = f.read()
    c = c.replace('    libs = [ "atomic" ]', '    # Patched: -latomic removed')
    with open('build/config/linux/BUILD.gn', 'w') as f:
        f.write(c)

print('All patches applied')
PATCH_BUILD

# --- 6. Configure GN ---
echo "=== Configuring build ==="
mkdir -p out/Release
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
use_llvm_libatomic = false
clang_version = "${CLANG_MAJOR}"
# Unvendor zlib + libpng — use the conda host packages. GN's hermetic compiles
# don't see conda's prefix, so point them at it explicitly.
use_system_zlib = true
use_system_libpng = true
extra_cflags = [ "-I${PREFIX}/include" ]
extra_ldflags = [ "-L${PREFIX}/lib" ]
ARGS
if [[ "$(uname)" == "Darwin" ]]; then
    echo 'mac_sdk_min = "11.0"' >> out/Release/args.gn
fi

$GN gen out/Release

# --- 7. Build ---
echo "=== Building pdfium (-j${CPU_COUNT:-4}) ==="
ninja -C out/Release pdfium -j${CPU_COUNT:-4}
ls -lh out/Release/obj/libpdfium.a

# --- 8. Create shared library ---
echo "=== Creating shared library ==="

# Note: chromium/7776 needed a C++ stub for OT::cff2::accelerator_t::get_extents
# (it was hidden via HB_INTERNAL). At 7891 our harfbuzz BUILD.gn visibility patches
# compile that symbol into libpdfium.a with a real definition, so the stub is now a
# duplicate and must NOT be re-added (multiple-definition link error).

if [[ "$(uname)" == "Darwin" ]]; then
    SDK_PATH=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
    ${CXX:-clang++} -shared -all_load \
        -Wl,-install_name,@rpath/libpdfium.dylib \
        -isysroot "$SDK_PATH" \
        -framework AppKit -framework CoreFoundation \
        -L"$PREFIX/lib" -lpng -lz \
        -o out/Release/libpdfium.dylib \
        out/Release/obj/libpdfium.a 2>&1
    LIBFILE="libpdfium.dylib"
else
    ${CXX:-clang++} -shared -Wl,--whole-archive \
        out/Release/obj/libpdfium.a \
        -Wl,--no-whole-archive \
        -Wl,-soname,libpdfium.so \
        -L"$PREFIX/lib" -lpng -lz \
        -lpthread -lm -ldl \
        -o out/Release/libpdfium.so 2>&1
    LIBFILE="libpdfium.so"
fi
ls -lh out/Release/${LIBFILE}

# --- 9. Install ---
echo "=== Installing ==="
mkdir -p "$PREFIX/lib" "$PREFIX/include"
install -m 0755 "out/Release/${LIBFILE}" "$PREFIX/lib/"
for header in public/fpdf*.h; do
    install -m 0644 "$header" "$PREFIX/include/"
done
echo "=== Done: $(ls $PREFIX/include/fpdf*.h | wc -l) headers + ${LIBFILE} ==="
