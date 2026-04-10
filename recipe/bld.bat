@echo off
setlocal enabledelayedexpansion

echo === Building PDFium from source (Windows) ===

:: Check if pdfium source was cloned by conda-build (git_url)
:: On Windows PBP, googlesource.com may be blocked, so we clone via Python HTTPS
if not exist "DEPS" (
    echo Source not available from git_url, cloning via Python...
    python %RECIPE_DIR%\clone_source.py
    if errorlevel 1 (
        echo ERROR: Failed to clone pdfium source
        exit /b 1
    )
)

:: --- 1. Fetch dependencies ---
echo === Fetching dependencies ===
python %RECIPE_DIR%\fetch_deps.py
if errorlevel 1 exit /b 1
echo === Dependencies fetched ===

:: --- 2. Acquire GN ---
python -c "import re; d=open('DEPS').read(); m=re.search(r'git_revision:([a-f0-9]+)', d); print(m.group(1))" > _gn_rev.txt
set /p GN_REV=<_gn_rev.txt

echo Downloading GN for windows...
python %RECIPE_DIR%\download_gn.py %GN_REV%
if errorlevel 1 exit /b 1
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

:: --- 4. Compiler stubs ---
:: Windows uses MSVC via {{ compiler('c') }}, set is_clang=false in args.gn
mkdir third_party\llvm-build\Release+Asserts 2>nul
echo llvmorg-19-init-0-0 > third_party\llvm-build\Release+Asserts\cr_build_revision
mkdir tools\clang\scripts 2>nul
(
echo CLANG_REVISION = 'llvmorg-19-init-0'
echo CLANG_SUB_REVISION = 0
) > tools\clang\scripts\update.py

:: --- 5. Apply patches ---
echo === Applying patches ===
python "%RECIPE_DIR%\apply_patches.py"
if errorlevel 1 exit /b 1

:: --- 6. Ensure python3 is available (Windows has python.exe, not python3.exe) ---
where python3 >nul 2>&1
if errorlevel 1 (
    echo Creating python3 alias...
    for /f "delims=" %%P in ('where python 2^>nul') do if not exist "%%~dpPpython3.exe" copy "%%P" "%%~dpPpython3.exe" >nul
)

:: --- 7. Set up Visual Studio for GN ---
:: Skip depot_tools toolchain — use system VS directly
set "DEPOT_TOOLS_WIN_TOOLCHAIN=0"
:: GN's vs_toolchain.py needs GYP_MSVS_OVERRIDE_PATH
if defined VS2022INSTALLDIR (
    set "GYP_MSVS_OVERRIDE_PATH=%VS2022INSTALLDIR%"
    set "GYP_MSVS_VERSION=2022"
) else if defined VS2019INSTALLDIR (
    set "GYP_MSVS_OVERRIDE_PATH=%VS2019INSTALLDIR%"
    set "GYP_MSVS_VERSION=2019"
)
echo GYP_MSVS_OVERRIDE_PATH=%GYP_MSVS_OVERRIDE_PATH%

:: Also set WINDOWSSDKDIR if not already set
if not defined WINDOWSSDKDIR (
    if exist "C:\Program Files (x86)\Windows Kits\10" (
        set "WINDOWSSDKDIR=C:\Program Files (x86)\Windows Kits\10"
    )
)

:: Debug: test vs_toolchain.py directly
echo Testing vs_toolchain.py...
python build\vs_toolchain.py get_toolchain_dir 2>&1
echo vs_toolchain.py exit code: %errorlevel%

:: --- 8. Configure GN ---
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
echo clang_version = "19"
) > out\Release\args.gn

gn gen out/Release
if errorlevel 1 exit /b 1

:: --- 7. Build ---
echo === Building pdfium ===
ninja -C out/Release pdfium
if errorlevel 1 exit /b 1

:: --- 8. Create DLL ---
echo === Creating DLL ===

:: Generate DEF file from headers
python -c "import glob,re; symbols=[]; xfa={'FPDF_BStr_Init','FPDF_BStr_Set','FPDF_BStr_Clear'}; [symbols.append(m.group(1)) for h in sorted(glob.glob('public/fpdf*.h')) for line in open(h) for m in [re.match(r'FPDF_EXPORT\s+\w.*?\s+(FPDF\w+)\s*\(',line)] if m and m.group(1) not in xfa]; f=open('out/pdfium.def','w'); f.write('LIBRARY pdfium\nEXPORTS\n'); [f.write(f'    {s}\n') for s in symbols]; print(f'{len(symbols)} exports')"

:: CFF2 stub
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

:: Find static lib
set STATIC_LIB=out\Release\obj\libpdfium.lib
if not exist %STATIC_LIB% set STATIC_LIB=out\Release\obj\pdfium.lib

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
if exist out\Release\pdfium.dll.lib copy out\Release\pdfium.dll.lib "%LIBRARY_LIB%\"
if exist out\Release\pdfium.lib copy out\Release\pdfium.lib "%LIBRARY_LIB%\"

for %%h in (public\fpdf*.h) do copy "%%h" "%LIBRARY_INC%\"

echo === Done ===
