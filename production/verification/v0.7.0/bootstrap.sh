#!/usr/bin/env bash
# Recreate non-persisted tooling. No signing keys or credentials are created.
set -euo pipefail
CACHE=/home/user/.cache
mkdir -p "$CACHE"
cd "$CACHE"
git clone --depth 1 --branch 3.24.5 https://github.com/flutter/flutter.git flutter
[ "$(git -C flutter rev-parse HEAD)" = dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668 ]
curl -fL --retry 3 -o java.tar.gz https://cdn.azul.com/zulu/bin/zulu17.54.21-ca-jdk17.0.13-linux_x64.tar.gz
mkdir -p java
tar -xf java.tar.gz -C java --strip-components=1
rm java.tar.gz
curl -fL --retry 3 -o commandline.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
mkdir -p android-sdk/cmdline-tools
unzip -q commandline.zip -d commandline-unpacked
mv commandline-unpacked/cmdline-tools android-sdk/cmdline-tools/latest
rm -rf commandline-unpacked commandline.zip
export PATH="$CACHE/flutter/bin:$CACHE/java/bin:$CACHE/android-sdk/cmdline-tools/latest/bin:$PATH"
export JAVA_HOME="$CACHE/java" ANDROID_HOME="$CACHE/android-sdk" ANDROID_SDK_ROOT="$CACHE/android-sdk" GRADLE_USER_HOME="$CACHE/gradle" PUB_CACHE="$CACHE/pub-cache"
# sdkmanager exits once all prompts have been accepted; yes can receive SIGPIPE.
set +o pipefail
yes | sdkmanager --licenses > "$CACHE/licenses.log" 2>&1
set -o pipefail
sdkmanager 'platforms;android-35' 'build-tools;35.0.0' 'build-tools;33.0.1' 'platform-tools'
flutter config --no-analytics
flutter config --jdk-dir="$JAVA_HOME"
cd /home/user/IronPin
flutter pub get
printf '\nSDK_READY\n'
