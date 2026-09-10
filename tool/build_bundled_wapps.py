#!/usr/bin/env python3
"""Rebuild every wasm module the app bundles, from the wapps source.

    python3 tool/build_bundled_wapps.py <wapps-checkout>          # rebuild + swap in
    python3 tool/build_bundled_wapps.py <wapps-checkout> --check  # compare only

The app ships compiled wapps: assets/wapps/*.wapp (and desktop/wapps/*.wapp)
carry app.wasm, plus tests.wasm for some, and assets/editor/app-creator/ carries
the editor's app.wasm. F-Droid builds everything from source, so its recipe
runs this against a checkout of xprs-dev/wapps (a srclib) before
`flutter build`. Every other file in those packages (manifest, screens, lang,
icons, the C source itself) is text and is left alone. Only the binaries are
replaced by fresh builds, and `licenses/` (the notices of third-party code
linked into the module, which have to match it) is taken from source too.
See docs/fdroid.md.

The toolchain is whatever the wapps' sdk/toolchain.mk picks from the
environment. With WASI_SDK_PATH (the default, ~/wasi-sdk) a clean build is
byte-identical to what is committed here, which --check verifies. With
WASI_SYSROOT=/usr, Debian's clang, lld and wasi-libc build the same modules
with no download, e.g. on trixie:

    apt install make clang-19 lld-19 llvm-19 wasi-libc libclang-rt-19-dev-wasm32 \\
        libc++-19-dev-wasm32 libc++abi-19-dev-wasm32 meson ninja-build
    WASI_SYSROOT=/usr WASM_CLANG=clang-19 WASM_CLANGXX=clang++-19 \\
        WASM_AR=llvm-ar-19 DAV1D_SRC=<dav1d 1.4.3> python3 tool/build_bundled_wapps.py <wapps>

DAV1D_SRC, when set, first rebuilds mp4player's libdav1d.a from dav1d source
(`make dav1d`), instead of linking the prebuilt copy committed in the wapps repo.

Builds happen in the checkout, like running `make` there: `make -B` forces
every object to be rebuilt, so a committed app.wasm (or mp4player's committed
.o files) is never reused. SOURCE_DATE_EPOCH defaults to the checkout's last
commit time: FDK-AAC stamps __DATE__ and __TIME__ into mp4player, and clang
takes both from it, so a rebuild of the same commit is byte-identical.
"""

import io
import json
import os
import subprocess
import sys
import zipfile

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARCHIVE_DIRS = ['assets/wapps', 'desktop/wapps']
EDITOR = 'assets/editor/app-creator'
# Module files a package may carry, and the make target that builds each.
TARGETS = {'app.wasm': 'all', 'tests.wasm': 'tests'}
JOBS = os.environ.get('JOBS', '4')


def make(src, *args):
    # Compiler warnings are noise here (mp4player's vendored codecs print
    # hundreds); show the output only when the build fails.
    r = subprocess.run(['make', '-C', src, '-B', f'-j{JOBS}', '--no-print-directory', *args],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0:
        print(r.stdout[-6000:])
        sys.exit(f'make failed in {src}')


def source_licenses(src):
    """{'licenses/<file>': bytes} for a wapp's licenses/ directory."""
    d = os.path.join(src, 'licenses')
    if not os.path.isdir(d):
        return {}
    out = {}
    for fn in sorted(os.listdir(d)):
        with open(os.path.join(d, fn), 'rb') as f:
            out[f'licenses/{fn}'] = f.read()
    return out


def check_same_wapp(name, src, bundled_manifest):
    """The source dir must be the wapp the package came from. A version that
    differs is only reported: the bundle's manifest is what ships."""
    with open(os.path.join(src, 'manifest.json')) as f:
        m = json.load(f)
    if m.get('id') != bundled_manifest.get('id'):
        sys.exit(f'{name}: {src} is {m.get("id")}, the bundle is {bundled_manifest.get("id")}')
    if m.get('version') != bundled_manifest.get('version'):
        print(f'  note: {name} source manifest is v{m.get("version")}, '
              f'the bundled one v{bundled_manifest.get("version")}')


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    check = '--check' in sys.argv
    if len(args) != 1:
        sys.exit(__doc__)
    wapps = os.path.abspath(args[0])
    if 'SOURCE_DATE_EPOCH' not in os.environ:
        try:
            r = subprocess.run(['git', '-C', wapps, 'log', '-1', '--format=%ct'],
                               capture_output=True, text=True)
        except OSError:  # no git: the stamp is today's date, not reproducible
            r = None
        if r and r.returncode == 0 and r.stdout.strip():
            os.environ['SOURCE_DATE_EPOCH'] = r.stdout.strip()

    if os.environ.get('DAV1D_SRC') and not check:
        print('dav1d: rebuilding libdav1d.a from', os.environ['DAV1D_SRC'])
        subprocess.run(['make', '-C', os.path.join(wapps, 'mp4player'), 'dav1d',
                        f'DAV1D_SRC={os.environ["DAV1D_SRC"]}'], check=True)

    built = {}  # (name, module) -> bytes; mp4player is bundled twice

    def build(name, module):
        key = (name, module)
        if key not in built:
            src = os.path.join(wapps, name)
            make(src, TARGETS[module])
            with open(os.path.join(src, module), 'rb') as f:
                built[key] = f.read()
        return built[key]

    differs = []

    def report(label, old, new):
        same = old == new
        print(f'  {label:44} {"identical" if same else "rebuilt"} '
              f'({len(old)} -> {len(new)} bytes)')
        if not same:
            differs.append(label)

    for d in ARCHIVE_DIRS:
        for fn in sorted(os.listdir(os.path.join(APP, d))):
            if not fn.endswith('.wapp'):
                continue
            name = fn[:-len('.wapp')]
            path = os.path.join(APP, d, fn)
            with zipfile.ZipFile(path) as z:
                infos = z.infolist()
                entries = {i.filename: z.read(i.filename) for i in infos}
            modules = [m for m in TARGETS if m in entries]
            print(f'{d}/{fn}')
            check_same_wapp(name, os.path.join(wapps, name),
                            json.loads(entries['manifest.json']))
            fresh = {m: build(name, m) for m in modules}
            for m in modules:
                report(f'{name}/{m}', entries[m], fresh[m])
            notices = source_licenses(os.path.join(wapps, name))
            old_notices = {k: v for k, v in entries.items()
                           if k.startswith('licenses/') and not k.endswith('/')}
            if notices != old_notices:
                print(f'  {name}/licenses/{"":35} updated from source')
                differs.append(f'{name}/licenses')
            if check or (notices == old_notices and
                         all(entries[m] == fresh[m] for m in modules)):
                continue
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, 'w') as out:
                for i in infos:
                    if i.filename.startswith('licenses/'):
                        continue
                    data = fresh.get(i.filename, entries[i.filename])
                    out.writestr(i, data, compress_type=zipfile.ZIP_DEFLATED)
                for k in sorted(notices):
                    out.writestr(k, notices[k], compress_type=zipfile.ZIP_DEFLATED)
            with open(path, 'wb') as f:
                f.write(buf.getvalue())

    print(EDITOR)
    with open(os.path.join(APP, EDITOR, 'manifest.json')) as f:
        check_same_wapp('app-creator', os.path.join(wapps, 'app-creator'), json.load(f))
    editor_wasm = os.path.join(APP, EDITOR, 'app.wasm')
    with open(editor_wasm, 'rb') as f:
        old = f.read()
    new = build('app-creator', 'app.wasm')
    report('app-creator/app.wasm (editor)', old, new)
    if not check and old != new:
        with open(editor_wasm, 'wb') as f:
            f.write(new)

    if check and differs:
        sys.exit(f'{len(differs)} module(s) differ from their source build')
    print('done' if not check else 'every bundled module matches its source build')


if __name__ == '__main__':
    main()
