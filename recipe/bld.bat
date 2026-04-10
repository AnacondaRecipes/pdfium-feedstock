@echo off
setlocal enabledelayedexpansion

echo === Building PDFium from source (Windows) ===

:: --- 1. Fetch dependencies from DEPS file ---
echo === Fetching dependencies ===

:: Helper: extract revision from DEPS
:: We use Python since batch can't easily parse DEPS
python -c "import re; d=open('DEPS').read(); print(re.search(r\"'build_revision': '([a-f0-9]+)'\", d).group(1))" > _rev.txt
set /p BUILD_REV=<_rev.txt

:: Clone all deps using Python script for reliability
python %RECIPE_DIR%\fetch_deps.py
if errorlevel 1 exit /b 1

echo === Dependencies fetched ===

:: --- 2. Acquire GN ---
python -c "import re; d=open('DEPS').read(); m=re.search(r\"git_revision:([a-f0-9]+)\", d); print(m.group(1))" > _gn_rev.txt
set /p GN_REV=<_gn_rev.txt

echo Downloading GN for windows...
python -c "import urllib.request,time,sys;^
url='https://chrome-infra-packages.appspot.com/dl/gn/gn/windows-amd64/+/git_revision:%GN_REV%';^
[urllib.request.urlretrieve(url,'gn.zip') or sys.exit(0) for _ in ''] if True else None" 2>nul
if exist gn.zip (
    mkdir gn_bin 2>nul
    python -c "import zipfile; zipfile.ZipFile('gn.zip').extractall('gn_bin')"
) else (
    echo CIPD unavailable, building GN from source...
    git clone https://gn.googlesource.com/gn.git gn_src
    cd gn_src
    python build\gen.py --allow-warnings
    ninja -C out gn
    cd ..
    mkdir gn_bin 2>nul
    copy gn_src\out\gn.exe gn_bin\gn.exe
)
set PATH=%CD%\gn_bin;%PATH%
gn --version

:: --- 3. Build system stubs ---
mkdir build\config 2>nul
(
echo build_with_chromium = false
echo checkout_android = false
echo checkout_skia = false
) > build\config\gclient_args.gni

mkdir third_party\test_fonts 2>nul
echo group("test_fonts") { testonly = true } > third_party\test_fonts\BUILD.gn
mkdir third_party\simdutf 2>nul
echo group("simdutf") {} > third_party\simdutf\BUILD.gn

:: --- 4. Compiler integration ---
:: On Windows, GN uses MSVC (cl.exe) by default via {{ compiler('c') }}
:: No clang wrappers needed — GN detects MSVC from environment
:: But we need the clang version stubs for consistency checks
for /f %%i in ('cl 2^>^&1 ^| findstr /C:"Version"') do set CL_VER=%%i
echo Compiler version: %CL_VER%

mkdir third_party\llvm-build\Release+Asserts 2>nul
echo llvmorg-19-init-0-0 > third_party\llvm-build\Release+Asserts\cr_build_revision
mkdir tools\clang\scripts 2>nul
(
echo CLANG_REVISION = 'llvmorg-19-init-0'
echo CLANG_SUB_REVISION = 0
) > tools\clang\scripts\update.py

:: --- 5. Apply patches ---
echo === Applying patches ===
python -c "^
# Patch compiler flags and HarfBuzz^
with open('build/config/compiler/BUILD.gn','r') as f: c=f.read()^
c=c.replace('cflags += [ \"-fno-lifetime-dse\" ]','# Patched')^
with open('build/config/compiler/BUILD.gn','w') as f: f.write(c)^
^
with open('build/config/sanitizers/sanitizers.gni','r') as f: c=f.read()^
c=c.replace('\"-fsanitize-ignore-for-ubsan-feature=${invoker.sanitizer}\",','# Patched')^
with open('build/config/sanitizers/sanitizers.gni','w') as f: f.write(c)^
^
with open('third_party/harfbuzz/BUILD.gn','r') as f: c=f.read()^
c=c.replace('if (is_component_build) {','if (true) {',1)^
c=c.replace('\"HB_NO_SUBSET_CFF\",\n','')^
c=c.replace('defines -= [ \"HB_NO_SUBSET_CFF\" ]','# Patched')^
c=c.replace('\"HAVE_OT\",','\"HAVE_OT\", \"HB_NO_VISIBILITY=1\", \"HB_INTERNAL=\",')^
with open('third_party/harfbuzz/BUILD.gn','w') as f: f.write(c)^
^
print('Patches applied')^
"
if errorlevel 1 exit /b 1

:: --- 6. Configure GN ---
echo === Configuring build ===
mkdir out\Release 2>nul
(
echo is_debug = false
echo pdf_is_standalone = true
echo pdf_enable_v8 = false
echo pdf_enable_xfa = false
echo pdf_use_skia = false
echo pdf_use_partition_alloc = false
echo pdf_bundle_freetype = true
echo is_component_build = false
echo treat_warnings_as_errors = false
echo use_custom_libcxx = false
echo clang_use_chrome_plugins = false
echo use_thin_lto = false
echo pdf_is_complete_lib = true
echo use_lld = false
echo use_glib = false
echo use_llvm_libatomic = false
echo is_clang = false
) > out\Release\args.gn

gn gen out/Release
if errorlevel 1 exit /b 1

:: --- 7. Build ---
echo === Building pdfium ===
ninja -C out/Release pdfium
if errorlevel 1 exit /b 1

echo Static library:
dir out\Release\obj\libpdfium.lib 2>nul || dir out\Release\obj\pdfium.lib 2>nul

:: --- 8. Create DLL ---
echo === Creating DLL ===

:: On Windows with MSVC, create DLL from static lib using a .def file
:: Generate exports from headers
python -c "^
import glob, re^
symbols = []^
xfa_only = {'FPDF_BStr_Init','FPDF_BStr_Set','FPDF_BStr_Clear'}^
for h in sorted(glob.glob('public/fpdf*.h')):^
    for line in open(h):^
        m = re.match(r'FPDF_EXPORT\s+\w.*?\s+(FPDF\w+)\s*\(', line)^
        if m and m.group(1) not in xfa_only:^
            symbols.append(m.group(1))^
with open('out/pdfium.def','w') as f:^
    f.write('LIBRARY pdfium\nEXPORTS\n')^
    for s in symbols: f.write(f'    {s}\n')^
print(f'Generated DEF file with {len(symbols)} exports')^
"

:: Find the static lib
set STATIC_LIB=out\Release\obj\libpdfium.lib
if not exist %STATIC_LIB% set STATIC_LIB=out\Release\obj\pdfium.lib

:: Create HarfBuzz CFF2 stub
(
echo struct hb_font_t;
echo struct hb_glyph_extents_t;
echo namespace OT { namespace cff2 {
echo struct accelerator_t {
echo     bool get_extents^(hb_font_t*, unsigned int, hb_glyph_extents_t*^) const;
echo };
echo bool accelerator_t::get_extents^(hb_font_t*, unsigned int, hb_glyph_extents_t*^) const {
echo     return false;
echo }
echo }}
) > out\hb_cff2_stub.cpp
cl /c /EHsc /Fo:out\hb_cff2_stub.obj out\hb_cff2_stub.cpp
if errorlevel 1 exit /b 1

:: Link DLL
link /DLL /DEF:out\pdfium.def /OUT:out\Release\pdfium.dll ^
    %STATIC_LIB% out\hb_cff2_stub.obj ^
    advapi32.lib gdi32.lib user32.lib
if errorlevel 1 exit /b 1

echo DLL created:
dir out\Release\pdfium.dll

:: --- 9. Install ---
echo === Installing ===
mkdir "%LIBRARY_BIN%" 2>nul
mkdir "%LIBRARY_LIB%" 2>nul
mkdir "%LIBRARY_INC%" 2>nul

copy out\Release\pdfium.dll "%LIBRARY_BIN%\"
copy out\Release\pdfium.dll.lib "%LIBRARY_LIB%\pdfium.dll.lib" 2>nul
copy out\Release\pdfium.lib "%LIBRARY_LIB%\pdfium.lib" 2>nul

for %%h in (public\fpdf*.h) do copy "%%h" "%LIBRARY_INC%\"

echo === Done ===
