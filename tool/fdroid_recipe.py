#!/usr/bin/env python3
"""Render the F-Droid recipe for one release from fdroid/com.xprs.app.yml.

The template's single build block becomes one block per ABI, each stamped with
the release's version, commit and per-ABI versionCode (ABI digit x 1,000,000 +
the pubspec build number, the scheme android/app/build.gradle.kts applies).

    python3 tool/fdroid_recipe.py --version 1.2.17 --code 362 --commit <sha>
        > metadata/com.xprs.app.yml         # the recipe for fdroiddata

    python3 tool/fdroid_recipe.py --out DIR --no-binary [--repo /xprs/app]
        # DIR/metadata/com.xprs.app.yml and DIR/srclibs/xprs-*.yml, for
        # `fdroid build` (release.yml, or a local test against local clones)

--no-binary drops the `binary:` lines, for a build that MAKES the release APK:
with them, `fdroid build` downloads the published APK and fails unless its
build matches it, which is F-Droid's check, not ours. Keep them to rebuild a
published release the way F-Droid will.

Without --version/--code/--commit, the values come from pubspec.yaml and HEAD.
See docs/f-droid.md.
"""

import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ABI: (versionCode digit, Rust target, flutter --target-platform). The
# digits are Flutter's (android/app/build.gradle.kts), in versionCode order.
ABIS = {
    'armeabi-v7a': (1, 'armv7-linux-androideabi', 'android-arm'),
    'arm64-v8a': (2, 'aarch64-linux-android', 'android-arm64'),
    'x86_64': (4, 'x86_64-linux-android', 'android-x64'),
}


def vercode(abi, code):
    return ABIS[abi][0] * 1_000_000 + code


def pubspec_version():
    with open(os.path.join(ROOT, 'pubspec.yaml')) as f:
        m = re.search(r'^version:\s*(\S+)\+(\d+)\s*$', f.read(), re.M)
    if not m:
        sys.exit('pubspec.yaml has no version: X.Y.Z+N line')
    return m.group(1), int(m.group(2))


def pin(name):
    with open(os.path.join(ROOT, name)) as f:
        return f.read().strip()


def render(version, code, commit, repo=None, binary=True):
    with open(os.path.join(ROOT, 'fdroid', 'com.xprs.app.yml')) as f:
        text = f.read()
    # Drop the template's own comment header.
    text = re.sub(r'\A(#[^\n]*\n)+', '', text)
    head, rest = text.split('Builds:\n', 1)
    block, tail = rest.split('\n\n', 1)
    blocks = []
    for abi, (_, rust, platform) in ABIS.items():
        b = block
        for key, val in (('@ABI@', abi), ('@RUST_TARGET@', rust),
                         ('@FLUTTER_PLATFORM@', platform),
                         ("'@VERSION@'", version),
                         ("'@VERCODE@'", str(vercode(abi, code))),
                         ("'@COMMIT@'", commit),
                         # fdroid lint wants a commit, not a branch. A later
                         # build block keeps these (F-Droid's auto-update
                         # copies the last one); its prebuild checks out the
                         # release's own pins, which a full clone holds.
                         ('@RD_PIN@', pin('.reticulum-dart-commit')),
                         ('@WAPPS_PIN@', pin('.wapps-commit'))):
            b = b.replace(key, val)
        blocks.append(b)
    tail = (tail.replace("'@VERSION@'", version)
                .replace("'@CURRENT_VERCODE@'", str(max(vercode(a, code) for a in ABIS))))
    out = head + 'Builds:\n' + '\n\n'.join(blocks) + '\n\n' + tail
    if repo:
        out = re.sub(r'^Repo: .*$', 'Repo: ' + repo, out, flags=re.M)
    if not binary:
        out = re.sub(r'^    binary: .*\n', '', out, flags=re.M)
    left = re.findall(r'@[A-Z_]+@', out)
    if left:
        sys.exit('unfilled placeholders: ' + ', '.join(sorted(set(left))))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--version', help='versionName (default: pubspec.yaml)')
    ap.add_argument('--code', type=int, help='build number N (default: pubspec.yaml)')
    ap.add_argument('--commit', help='commit hash (default: HEAD)')
    ap.add_argument('--out', help='write DIR/metadata and DIR/srclibs instead of stdout')
    ap.add_argument('--repo', help="override the app's Repo: (local test)")
    ap.add_argument('--srclib-repo', action='append', default=[], metavar='NAME=URL',
                    help='override a srclib Repo: (local test), e.g. xprs-wapps=/xprs/wapps')
    ap.add_argument('--no-binary', action='store_true',
                    help='drop binary: (a build that makes the release APK)')
    ap.add_argument('--print-vercode', metavar='ABI',
                    help='print the versionCode of ABI and exit')
    a = ap.parse_args()

    pv, pc = pubspec_version()
    version = a.version or pv
    code = a.code if a.code is not None else pc
    if a.print_vercode:
        print(vercode(a.print_vercode, code))
        return
    commit = a.commit or subprocess.check_output(
        ['git', '-C', ROOT, 'rev-parse', 'HEAD'], text=True).strip()
    recipe = render(version, code, commit, a.repo, binary=not a.no_binary)

    if not a.out:
        sys.stdout.write(recipe)
        return
    os.makedirs(os.path.join(a.out, 'metadata'), exist_ok=True)
    os.makedirs(os.path.join(a.out, 'srclibs'), exist_ok=True)
    with open(os.path.join(a.out, 'metadata', 'com.xprs.app.yml'), 'w') as f:
        f.write(recipe)
    overrides = dict(s.split('=', 1) for s in a.srclib_repo)
    src = os.path.join(ROOT, 'fdroid', 'srclibs')
    for name in sorted(os.listdir(src)):
        with open(os.path.join(src, name)) as f:
            text = f.read()
        lib = name[:-len('.yml')]
        if lib in overrides:
            text = re.sub(r'^Repo: .*$', 'Repo: ' + overrides[lib], text, flags=re.M)
        with open(os.path.join(a.out, 'srclibs', name), 'w') as f:
            f.write(text)


if __name__ == '__main__':
    main()
