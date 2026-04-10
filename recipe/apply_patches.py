"""Apply build system patches for pdfium (cross-platform)."""
import os

# compiler/BUILD.gn: remove -fno-lifetime-dse (GCC-only, not in LLVM/MSVC)
with open('build/config/compiler/BUILD.gn', 'r') as f:
    c = f.read()
c = c.replace('cflags += [ "-fno-lifetime-dse" ]', '# Patched: removed')
with open('build/config/compiler/BUILD.gn', 'w') as f:
    f.write(c)

# sanitizers.gni: remove -fsanitize-ignore-for-ubsan-feature (trunk clang only)
with open('build/config/sanitizers/sanitizers.gni', 'r') as f:
    c = f.read()
c = c.replace('"-fsanitize-ignore-for-ubsan-feature=${invoker.sanitizer}",',
              '# Patched: removed')
with open('build/config/sanitizers/sanitizers.gni', 'w') as f:
    f.write(c)

# harfbuzz/BUILD.gn: export symbols, enable CFF2
with open('third_party/harfbuzz/BUILD.gn', 'r') as f:
    c = f.read()
c = c.replace('if (is_component_build) {',
              'if (true) {  # Patched: export HarfBuzz symbols', 1)
c = c.replace('"HB_NO_SUBSET_CFF",\n', '')
c = c.replace('defines -= [ "HB_NO_SUBSET_CFF" ]', '# Patched: removed')
c = c.replace('"HAVE_OT",', '"HAVE_OT", "HB_NO_VISIBILITY=1", "HB_INTERNAL=",')
with open('third_party/harfbuzz/BUILD.gn', 'w') as f:
    f.write(c)

# gcc/BUILD.gn: default visibility (needed for shared lib on unix)
if os.name != 'nt':
    with open('build/config/gcc/BUILD.gn', 'r') as f:
        c = f.read()
    c = c.replace('cflags = [ "-fvisibility=hidden" ]',
                  'cflags = [ "-fvisibility=default" ]  # Patched')
    with open('build/config/gcc/BUILD.gn', 'w') as f:
        f.write(c)

# linux/BUILD.gn: remove -latomic (linux only)
if os.uname().sysname == 'Linux' if hasattr(os, 'uname') else False:
    with open('build/config/linux/BUILD.gn', 'r') as f:
        c = f.read()
    c = c.replace('    libs = [ "atomic" ]', '    # Patched: removed')
    with open('build/config/linux/BUILD.gn', 'w') as f:
        f.write(c)


print('All patches applied')
