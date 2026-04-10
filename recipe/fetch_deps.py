"""Fetch pdfium dependencies from DEPS file (cross-platform helper)."""
import os, re, subprocess, sys

CHROMIUM_GIT = "https://chromium.googlesource.com"

DEPS_MAP = {
    "build":                              "{G}/chromium/src/build.git",
    "buildtools":                         "{G}/chromium/src/buildtools.git",
    "base/allocator/partition_allocator":  "{G}/chromium/src/base/allocator/partition_allocator.git",
    "third_party/abseil-cpp":             "{G}/chromium/src/third_party/abseil-cpp.git",
    "third_party/fast_float/src":         "{G}/external/github.com/fastfloat/fast_float.git",
    "third_party/fp16/src":               "{G}/external/github.com/Maratyszcza/FP16.git",
    "third_party/freetype/src":           "{G}/chromium/src/third_party/freetype2.git",
    "third_party/harfbuzz/src":           "{G}/external/github.com/harfbuzz/harfbuzz.git",
    "third_party/icu":                    "{G}/chromium/deps/icu.git",
    "third_party/libpng":                 "{G}/chromium/src/third_party/libpng.git",
    "third_party/libjpeg_turbo":          "{G}/chromium/deps/libjpeg_turbo.git",
    "third_party/zlib":                   "{G}/chromium/src/third_party/zlib.git",
    "third_party/brotli":                 "{G}/chromium/src/third_party/brotli.git",
    "third_party/jinja2":                 "{G}/chromium/src/third_party/jinja2.git",
    "third_party/markupsafe":             "{G}/chromium/src/third_party/markupsafe.git",
    "third_party/libc++/src":             "{G}/external/github.com/llvm/llvm-project/libcxx.git",
    "third_party/libc++abi/src":          "{G}/external/github.com/llvm/llvm-project/libcxxabi.git",
    "third_party/googletest/src":         "{G}/external/github.com/google/googletest.git",
    "third_party/clang-format/script":    "{G}/external/github.com/llvm/llvm-project/clang/tools/clang-format.git",
    "third_party/nasm":                   "{G}/chromium/deps/nasm.git",
}

# Map dep name to DEPS key
REV_KEYS = {
    "build": "build", "buildtools": "buildtools",
    "base/allocator/partition_allocator": "partition_allocator",
    "third_party/abseil-cpp": "abseil", "third_party/fast_float/src": "fast_float",
    "third_party/fp16/src": "fp16", "third_party/freetype/src": "freetype",
    "third_party/harfbuzz/src": "harfbuzz", "third_party/icu": "icu",
    "third_party/libpng": "libpng", "third_party/libjpeg_turbo": "jpeg_turbo",
    "third_party/zlib": "zlib", "third_party/brotli": "brotli",
    "third_party/jinja2": "jinja2", "third_party/markupsafe": "markupsafe",
    "third_party/libc++/src": "libcxx", "third_party/libc++abi/src": "libcxxabi",
    "third_party/googletest/src": "gtest", "third_party/clang-format/script": "clang_format",
    "third_party/nasm": "nasm_source",
}

def get_rev(deps_content, key):
    m = re.search(rf"'{key}_revision': '([a-f0-9]{{40}})'", deps_content)
    return m.group(1) if m else None

def clone_dep(dest, url, rev):
    if os.path.isdir(dest):
        return
    print(f"  CLONE: {dest} @ {rev[:12]}")
    r = subprocess.run(["git", "clone", "--depth", "1", url, dest],
                       capture_output=True)
    if r.returncode != 0:
        subprocess.run(["git", "clone", url, dest], check=True)
        subprocess.run(["git", "checkout", rev], cwd=dest, check=True)

def main():
    with open("DEPS") as f:
        deps = f.read()

    for dest, url_template in DEPS_MAP.items():
        url = url_template.replace("{G}", CHROMIUM_GIT)
        rev_key = REV_KEYS[dest]
        rev = get_rev(deps, rev_key)
        if not rev:
            print(f"  WARNING: {rev_key}_revision not found in DEPS")
            continue
        clone_dep(dest, url, rev)

    print("All dependencies fetched.")

if __name__ == "__main__":
    main()
