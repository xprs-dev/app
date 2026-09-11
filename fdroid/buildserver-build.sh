#!/usr/bin/env bash
# =============================================================================
# Build one XPRS APK exactly the way F-Droid does, then sign it.
#
# Runs as root INSIDE registry.gitlab.com/fdroid/fdroidserver:buildserver-trixie
# (F-Droid's buildserver image). The steps are those of the "fdroid build" job
# in fdroiddata's .gitlab-ci.yml: the app is cloned and built by fdroidserver
# itself, as user vagrant, in /home/vagrant/build/com.xprs.app, the path
# F-Droid's own buildserver uses. That is what makes the result reproducible:
# F-Droid rebuilds the same recipe and publishes our APK only if its own build
# is identical once our signature is copied onto it.
#
#   docker run --rm -v "$PWD":/src -v "$OUT":/out \
#     -e BUILD=com.xprs.app:2000362 -e RECIPE=/src/<rendered> \
#     [-e KEYSTORE=/keys/xprs-release.jks -e KEY_ALIAS -e KS_PASS -e KEY_PASS \
#      -e SIGNED_NAME=xprs-1.2.17-android-arm64-v8a.apk] \
#     registry.gitlab.com/fdroid/fdroidserver:buildserver-trixie \
#     bash /src/fdroid/buildserver-build.sh
#
# RECIPE is a directory from `tool/fdroid_recipe.py --out`. The unsigned APK
# lands in /out/unsigned/; with a KEYSTORE the signed one lands in /out/ and is
# checked with fdroidserver's own verify_apks, the check F-Droid will run.
#
# SKIP_SETUP=1 skips the one-time image setup (reusing a container locally);
# LOW_MEMORY=1 caps Gradle for a 16 GB laptop (it does not change the output).
# See docs/f-droid.md.
# =============================================================================
set -euo pipefail
: "${BUILD:?com.xprs.app:<versionCode>}" "${RECIPE:?rendered recipe directory}"
OUT=${OUT:-/out}
appid=${BUILD%:*}
vercode=${BUILD#*:}

test -n "${fdroidserver:-}" || source /etc/profile.d/bsenv.sh
export GRADLE_USER_HOME=$home_vagrant/.gradle

if [[ "${SKIP_SETUP:-}" != 1 ]]; then
  apt-get update
  apt-get -y dist-upgrade
  # "These packages are needed to make this env like the production buildserver."
  sdkmanager "platform-tools" "build-tools;31.0.0"
  rm -rf "$fdroidserver" && mkdir "$fdroidserver"
  git ls-remote https://gitlab.com/fdroid/fdroidserver.git master
  curl -fsSL https://gitlab.com/fdroid/fdroidserver/-/archive/master/fdroidserver-master.tar.gz \
    | tar -xz --directory="$fdroidserver" --strip-components=1
  git -c safe.directory="$home_vagrant/gradlew-fdroid" -C "$home_vagrant/gradlew-fdroid" pull
  apt-get install -y sudo openjdk-21-jdk-headless
  update-alternatives --set java /usr/lib/jvm/java-21-openjdk-amd64/bin/java
fi

for d in logs tmp unsigned .android .gradle metadata; do
  rm -f "$home_vagrant/$d" 2>/dev/null || true      # a symlink from an earlier setup
  mkdir -p "$home_vagrant/$d"
done
if [[ "${LOW_MEMORY:-}" == 1 ]]; then
  printf '%s\n' 'org.gradle.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=512m' \
    'kotlin.compiler.execution.strategy=in-process' 'org.gradle.workers.max=2' \
    > "$home_vagrant/.gradle/gradle.properties"
fi

# A fresh tree, as on the buildserver (fdroiddata CI deletes build/ between
# builds). Only the Flutter clone survives a local rerun: it is large, and the
# recipe checks out its pinned version with -f anyway.
rm -rf "$home_vagrant/build/$appid" "$home_vagrant/build/reticulum-dart" \
  "$home_vagrant"/build/srclib/{xprs-wapps,xprs-reticulum-dart,dav1d} \
  "$home_vagrant/tmp/${appid}_$vercode.apk"
# The recipe and every srclib it names. flutter and dav1d are fdroiddata's.
rm -rf "$home_vagrant/srclibs"
mkdir -p "$home_vagrant/srclibs"
cp "$RECIPE/metadata/$appid.yml" "$home_vagrant/metadata/"
for lib in flutter dav1d; do
  curl -fsSL "https://gitlab.com/fdroid/fdroiddata/-/raw/master/srclibs/$lib.yml" \
    -o "$home_vagrant/srclibs/$lib.yml"
done
cp "$RECIPE"/srclibs/*.yml "$home_vagrant/srclibs/"
chown -R vagrant "$home_vagrant"

# `fdroid build --on-server` uninstalls sudo when it is done, even on failure.
command -v sudo >/dev/null || apt-get install -y sudo
fdroid() {
  sudo --preserve-env --user vagrant \
    env PATH="$fdroidserver:$PATH" PYTHONPATH="$fdroidserver:$fdroidserver/examples" \
    PYTHONUNBUFFERED=true HOME="$home_vagrant" fdroid "$@"
}
cd "$home_vagrant"
# fdroiddata CI fetches with the production host's hardened git config; the
# build itself runs without it, as on the buildserver.
curl -fsSL https://gitlab.com/fdroid/fdroid-bootstrap-buildserver/-/raw/master/roles/production_hardening/files/gitconfig \
  > "$home_vagrant/.gitconfig"
chown vagrant "$home_vagrant/.gitconfig"
fdroid fetchsrclibs "$BUILD" --verbose
rm -f "$home_vagrant/.gitconfig"
rc=0
(unset CI; fdroid build --verbose --test --refresh-scanner --on-server --no-tarball "$BUILD") || rc=$?
command -v sudo >/dev/null || apt-get install -y sudo
[[ $rc == 0 ]] || exit $rc

unsigned="$home_vagrant/tmp/${appid}_$vercode.apk"
mkdir -p "$OUT/unsigned"
cp "$unsigned" "$OUT/unsigned/"
echo "built: $OUT/unsigned/${appid}_$vercode.apk"

[[ -n "${KEYSTORE:-}" ]] || exit 0
: "${KEY_ALIAS:?}" "${KS_PASS:?}" "${KEY_PASS:?}" "${SIGNED_NAME:?}"
apksigner=$(ls "$ANDROID_HOME"/build-tools/*/apksigner | sort -V | tail -1)
# The layout must stay exactly as Gradle wrote it: apksigcopier rebuilds
# F-Droid's APK entry by entry and only pastes our signature block on. So no
# re-alignment (apksigner re-pads every stored entry otherwise) and no v1 JAR
# signature (extra META-INF files; minSdk 24 does not need it).
"$apksigner" sign --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" \
  --ks-pass env:KS_PASS --key-pass env:KEY_PASS \
  --alignment-preserved --v1-signing-enabled false \
  --v2-signing-enabled true --v3-signing-enabled true \
  --out "$OUT/$SIGNED_NAME" "$unsigned"
rm -f "$OUT/$SIGNED_NAME.idsig"
# F-Droid's check, verbatim: strip any signature from its own build, copy ours
# onto it, and verify. None means the two are the same APK.
PYTHONPATH="$fdroidserver" python3 - "$OUT/$SIGNED_NAME" "$unsigned" <<'EOF'
import sys, tempfile
from fdroidserver import common
common.config = common.read_config()
with tempfile.TemporaryDirectory() as tmp:
    err = common.verify_apks(sys.argv[1], sys.argv[2], tmp)
if err:
    sys.exit('verify_apks: ' + err)
print('verify_apks: signed APK matches the F-Droid build')
EOF
