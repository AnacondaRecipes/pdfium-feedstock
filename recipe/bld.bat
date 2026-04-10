@echo off

echo === Building PDFium from source (Windows) ===

:: --- 0. Clone source if git_url failed ---
if not exist "DEPS" (
    echo Source not available, cloning via Python HTTPS...
    python "%RECIPE_DIR%\clone_source.py"
    if errorlevel 1 exit /b 1
)

:: --- 1. Fetch dependencies ---
echo === Fetching dependencies ===
python "%RECIPE_DIR%\fetch_deps.py"
if errorlevel 1 exit /b 1
echo === Dependencies fetched ===

:: --- 2. Acquire GN ---
echo === Acquiring GN ===
python -c "import re; d=open('DEPS').read(); m=re.search(r'git_revision:([a-f0-9]+)', d); print(m.group(1))" > _gn_rev.txt
set /p GN_REV=<_gn_rev.txt
python "%RECIPE_DIR%\download_gn.py" %GN_REV%
if errorlevel 1 exit /b 1
set "PATH=%CD%\gn_bin;%PATH%"
gn --version
if errorlevel 1 (
    echo ERROR: GN not found
    exit /b 1
)

:: --- 3. Build system stubs ---
echo === Creating build stubs ===
mkdir build\config 2>nul
echo build_with_chromium = false> build\config\gclient_args.gni
echo checkout_android = false>> build\config\gclient_args.gni
echo checkout_skia = false>> build\config\gclient_args.gni

mkdir third_party\test_fonts 2>nul
echo group("test_fonts") { testonly = true }> third_party\test_fonts\BUILD.gn
mkdir third_party\simdutf 2>nul
echo group("simdutf") {}> third_party\simdutf\BUILD.gn

:: --- 4. Compiler stubs ---
mkdir third_party\llvm-build\Release+Asserts 2>nul
echo llvmorg-19-init-0-0> third_party\llvm-build\Release+Asserts\cr_build_revision
mkdir tools\clang\scripts 2>nul
echo CLANG_REVISION = 'llvmorg-19-init-0'> tools\clang\scripts\update.py
echo CLANG_SUB_REVISION = 0>> tools\clang\scripts\update.py

:: --- 5. Ensure python3 available ---
where python3 >nul 2>&1
if errorlevel 1 (
    echo Creating python3 alias...
    for /f "delims=" %%P in ('where python 2^>nul') do if not exist "%%~dpPpython3.exe" copy "%%P" "%%~dpPpython3.exe" >nul
)

:: --- 6. Visual Studio setup ---
set "DEPOT_TOOLS_WIN_TOOLCHAIN=0"
if defined VS2022INSTALLDIR set "GYP_MSVS_OVERRIDE_PATH=%VS2022INSTALLDIR%"
if defined VS2022INSTALLDIR set "GYP_MSVS_VERSION=2022"
if not defined WINDOWSSDKDIR if exist "C:\Program Files (x86)\Windows Kits\10" set "WINDOWSSDKDIR=C:\Program Files (x86)\Windows Kits\10"
echo GYP_MSVS_OVERRIDE_PATH=%GYP_MSVS_OVERRIDE_PATH%

:: --- 7. Apply patches ---
echo === Applying patches ===
python "%RECIPE_DIR%\apply_patches.py"
if errorlevel 1 exit /b 1

:: --- 8. Configure GN ---
echo === Configuring build ===
mkdir out\Release 2>nul
echo is_debug = false> out\Release\args.gn
echo pdf_is_standalone = true>> out\Release\args.gn
echo pdf_enable_v8 = false>> out\Release\args.gn
echo pdf_enable_xfa = false>> out\Release\args.gn
echo pdf_use_skia = false>> out\Release\args.gn
echo pdf_use_partition_alloc = false>> out\Release\args.gn
echo pdf_bundle_freetype = true>> out\Release\args.gn
echo is_component_build = false>> out\Release\args.gn
echo treat_warnings_as_errors = false>> out\Release\args.gn
echo use_custom_libcxx = false>> out\Release\args.gn
echo clang_use_chrome_plugins = false>> out\Release\args.gn
echo use_thin_lto = false>> out\Release\args.gn
echo pdf_is_complete_lib = true>> out\Release\args.gn
echo use_lld = false>> out\Release\args.gn
echo use_glib = false>> out\Release\args.gn
echo use_llvm_libatomic = false>> out\Release\args.gn
echo is_clang = false>> out\Release\args.gn

gn gen out/Release
if errorlevel 1 (
    echo ERROR: gn gen failed
    exit /b 1
)

:: --- 9. Build ---
echo === Building pdfium ===
ninja -C out/Release pdfium
if errorlevel 1 (
    echo ERROR: ninja build failed
    exit /b 1
)

:: --- 10. Create DLL ---
echo === Creating DLL ===

:: Generate DEF file
python -c "import glob,re; syms=[]; xfa={'FPDF_BStr_Init','FPDF_BStr_Set','FPDF_BStr_Clear'}; [syms.append(m.group(1)) for h in sorted(glob.glob('public/fpdf*.h')) for line in open(h) for m in [re.match(r'FPDF_EXPORT\s+\w.*?\s+(FPDF\w+)\s*\(',line)] if m and m.group(1) not in xfa]; f=open('out/pdfium.def','w'); f.write('LIBRARY pdfium\nEXPORTS\n'); [f.write(f'    {s}\n') for s in syms]; print(f'{len(syms)} exports')"
if errorlevel 1 exit /b 1

:: CFF2 stub
echo struct hb_font_t;> out\hb_cff2_stub.cpp
echo struct hb_glyph_extents_t;>> out\hb_cff2_stub.cpp
echo namespace OT { namespace cff2 {>> out\hb_cff2_stub.cpp
echo struct accelerator_t {>> out\hb_cff2_stub.cpp
echo     bool get_extents(hb_font_t*, unsigned int, hb_glyph_extents_t*) const;>> out\hb_cff2_stub.cpp
echo };>> out\hb_cff2_stub.cpp
echo bool accelerator_t::get_extents(hb_font_t*, unsigned int, hb_glyph_extents_t*) const {>> out\hb_cff2_stub.cpp
echo     return false;>> out\hb_cff2_stub.cpp
echo }>> out\hb_cff2_stub.cpp
echo }}>> out\hb_cff2_stub.cpp

cl /c /EHsc /Fo:out\hb_cff2_stub.obj out\hb_cff2_stub.cpp
if errorlevel 1 exit /b 1

:: Find static lib
set "STATIC_LIB=out\Release\obj\libpdfium.lib"
if not exist "%STATIC_LIB%" set "STATIC_LIB=out\Release\obj\pdfium.lib"

:: Link DLL
link /DLL /DEF:out\pdfium.def /OUT:out\Release\pdfium.dll %STATIC_LIB% out\hb_cff2_stub.obj advapi32.lib gdi32.lib user32.lib
if errorlevel 1 exit /b 1

echo DLL created:
dir out\Release\pdfium.dll

:: --- 11. Install ---
echo === Installing ===
mkdir "%LIBRARY_BIN%" 2>nul
mkdir "%LIBRARY_LIB%" 2>nul
mkdir "%LIBRARY_INC%" 2>nul

copy out\Release\pdfium.dll "%LIBRARY_BIN%\"
if exist out\Release\pdfium.dll.lib copy out\Release\pdfium.dll.lib "%LIBRARY_LIB%\"
if exist out\Release\pdfium.lib copy out\Release\pdfium.lib "%LIBRARY_LIB%\"

for %%h in (public\fpdf*.h) do copy "%%h" "%LIBRARY_INC%\"

echo === Done ===
