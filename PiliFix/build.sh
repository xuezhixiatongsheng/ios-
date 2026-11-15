#!/bin/sh
# Builds PiliFix (the PiliPlus startup fix) as a tweak package.
set -eu
: "${APELIN_PACKAGE_DIR:?set APELIN_PACKAGE_DIR}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}"

stage="$(mktemp -d "${TMPDIR:?}stage.XXXXXX")"
trap 'rm -rf -- "${stage:?}"' EXIT

case "$APELIN_ARCHITECTURE" in
  *arm64e) arch=arm64e ;;
  *)       arch=arm64 ;;
esac

cd "$APELIN_PROJECT_ROOT"

out="$stage$APELIN_PREFIX/usr/lib/TweakInject"
mkdir -p "$out"

clang -arch "$arch" -dynamiclib -fobjc-arc -O2 -Wall \
  -DAPELIN_BUILD_ID="\"$APELIN_BUILD_ID\"" \
  -o "$out/PiliFix.dylib" src/PiliFix.m \
  -framework Foundation

ldid -S "$out/PiliFix.dylib"
cp src/PiliFix.plist "$out/PiliFix.plist"

mkdir -p "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<EOF
Package: com.xuezhixiatongsheng.pilifix
Version: 1.0.2
Architecture: $APELIN_ARCHITECTURE
Name: PiliFix
Description: Lets PiliPlus (iOS 17) load its native-asset libraries again: relative framework paths are resolved inside the app bundle.
Maintainer: xuezhixiatongsheng
Author: xuezhixiatongsheng
Section: Tweaks
EOF

dpkg-deb -b --root-owner-group "$stage" "$APELIN_PACKAGE_DIR/"
