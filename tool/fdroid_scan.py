#!/usr/bin/env python3
"""Every network host, and every non-free class, inside a built APK.

    python3 tool/fdroid_scan.py [build/app/outputs/flutter-apk/app-arm64-v8a-release.apk]

Scans the APK rather than the source: constants that survive into libapp.so,
and blobs that dependencies bring in, never show up in a search over lib/.
docs/fdroid.md explains what each host is and why it may stay.

Three passes:
  1. URLs (http/https/ws/wss) in every file, and inside every bundled .wapp.
  2. Bare host names (a Reticulum hub or tracker is "host:port", no scheme)
     in libapp.so and in the wapps' own files. Vendored codec sources under
     vendor/ and bin/ are skipped here; pass 1 still covers them.
  3. Proprietary Java packages (Play Services, Firebase, ...) in the dex, and
     executables that have no business inside a wapp.

Exits 1 if pass 3 finds anything. github.com URLs are listed, not failed on:
the Flutter engine and the Kotlin runtime carry some as issue-tracker text.
"""

import collections
import io
import re
import sys
import zipfile

APK = sys.argv[1] if len(sys.argv) > 1 else \
    'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'

URL = re.compile(rb'(?:https?|wss?)://[A-Za-z0-9._~:/?#@!$&\'()*+,;=%-]{4,90}')
TLDS = (b'com|net|org|io|dev|de|fr|xyz|im|exchange|me|es|band|lol|sh|app|eu|'
        b'info|us|uk|ch|nl|club|network|to|cc|ru|se|fi|is|pw|link|one|space|'
        b'social|chat|world|tech|cloud|zone|systems|au|br|at|be|pl|it|cz')
HOST = re.compile(rb'\b(?:[a-z0-9-]+\.)+(?:' + TLDS + rb')\b(?::\d{2,5})?')
NONFREE = re.compile(rb'L(com/google/(?:android/gms|firebase|android/play|'
                     rb'android/datatransport|mlkit)|com/google/mlkit|'
                     rb'com/crashlytics|com/android/billingclient|com/facebook|'
                     rb'com/onesignal|com/huawei/hms)/')
# Magic numbers of native executables: ELF, PE, Mach-O. A static library
# (ar archive) is reported separately: in a wapp it usually holds wasm objects,
# still a prebuilt binary as far as F-Droid is concerned.
EXEC_MAGIC = (b'\x7fELF', b'MZ', b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
              b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce')
AR_MAGIC = b'!<arch>\n'
SKIP_EXT = ('.png', '.jpg', '.webp', '.ttf', '.otf', '.svg')
# Package names, wapp ids, channel names and source files that merely look
# like hosts (".cc" and ".sh" are TLDs as well as file extensions).
NOT_HOSTS = re.compile(r'^(com\.xprs\.|tools\.xprs\.|plugins\.flutter\.io|'
                       r'flutter\.baseflow\.com|dart\.io|flutter\.io|ui\.chat|'
                       r'system\.app|pos\.to)|^[a-z0-9-]+\.(cc|sh)$')


def host_of(url):
    return re.sub(r'^\w+://', '', url).split('/')[0].split(':')[0]


def main():
    apk = zipfile.ZipFile(APK)
    urls = collections.defaultdict(set)     # host -> {file}
    bare = collections.defaultdict(set)     # host[:port] -> {file}
    problems = []

    def scan(label, data, want_bare):
        for m in URL.findall(data):
            urls[host_of(m.decode())].add(label)
        if want_bare:
            for m in HOST.findall(data):
                h = m.decode()
                if not NOT_HOSTS.match(h):
                    bare[h].add(label)

    for name in apk.namelist():
        if name.endswith(SKIP_EXT):
            continue
        data = apk.read(name)
        if name.endswith('.wapp'):
            wapp = name.rsplit('/', 1)[-1]
            inner = zipfile.ZipFile(io.BytesIO(data))
            for f in inner.namelist():
                if f.endswith('/') or f.endswith(SKIP_EXT):
                    continue
                body = inner.read(f)
                label = f'{wapp}:{f}'
                vendored = f.startswith(('vendor/', 'bin/'))
                scan(label, body, not vendored)
                if body.startswith(EXEC_MAGIC):
                    problems.append(f'native executable inside a wapp: {label}')
                elif body.startswith(AR_MAGIC):
                    problems.append(f'prebuilt static library inside a wapp: {label}')
            continue
        scan(name, data, name.endswith('libapp.so'))
        if name.endswith('.dex'):
            found = sorted({m.decode() for m in NONFREE.findall(data)})
            for pkg in found:
                problems.append(f'proprietary classes in {name}: {pkg}')

    print('== URL hosts')
    for h in sorted(urls):
        files = ', '.join(sorted(urls[h]))
        print(f'{h:34} {files[:150]}')
    print('\n== Bare host names (libapp.so and wapp files)')
    for h in sorted(bare):
        print(f'{h:34} {", ".join(sorted(bare[h]))[:150]}')
    print('\n== Native libraries')
    for n in apk.namelist():
        if n.startswith('lib/'):
            print(n)

    gh = sorted(f for f in urls.get('github.com', ())
                if not f.split(':', 1)[-1].startswith(('vendor/', 'bin/')))
    print('\n== github.com as a URL, outside vendored sources')
    print('\n'.join(gh) if gh else '(none)')

    print('\n== Problems')
    print('\n'.join(problems) if problems else '(none)')
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
