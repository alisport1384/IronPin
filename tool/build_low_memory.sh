#!/usr/bin/env bash
# Builds one release APK on a small host (2 GB RAM, no swap).
#
# The Dart compiler and the Gradle JVM do not fit in that memory together: the
# first attempt of 0.9.3 stalled the whole machine for 40 minutes. So the AOT
# step runs first, alone, with exactly the arguments the Flutter Gradle plugin
# passes (flutter.groovy `buildBundle`); Gradle then finds it up to date and only
# packages. A guard stops the build instead of letting the host hang.
#
#   bash tool/build_low_memory.sh android-arm     # armeabi-v7a
#   bash tool/build_low_memory.sh android-arm64   # arm64-v8a
#
# Flutter 3.24.5, JDK 17 and the Android SDK must already be on PATH /
# JAVA_HOME / ANDROID_SDK_ROOT (see docs/BUILD.fa.md). Never use --split-per-abi.
set -uo pipefail
PLATFORM=${1:-android-arm}
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/build/app/intermediates/flutter/release"
mkdir -p "$OUT"

echo "[1/2] Dart AOT for $PLATFORM (no Gradle running)"
flutter --quiet assemble --no-version-check \
  --depfile "$OUT/flutter_build.d" --output "$OUT" \
  -dTargetFile=lib/main.dart -dTargetPlatform=android -dBuildMode=release \
  -dTrackWidgetCreation=true -dTreeShakeIcons=true -dFlavor= \
  "-dAndroidArchs=$PLATFORM" -dMinSdkVersion=21 \
  "android_aot_bundle_release_$PLATFORM" || exit 1

echo "[2/2] Gradle packaging"
( low=0
  while sleep 5; do
    free_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    if [ "$free_mb" -lt 70 ]; then low=$((low + 1)); else low=0; fi
    if [ "$low" -ge 4 ]; then
      echo "[guard] memory exhausted; stopping the build"
      pkill -9 java
      break
    fi
  done ) &
GUARD=$!
flutter build apk --release --target-platform "$PLATFORM" --no-pub
STATUS=$?
kill "$GUARD" 2>/dev/null
[ "$STATUS" -eq 0 ] && ls -la build/app/outputs/flutter-apk/app-release.apk
exit "$STATUS"
