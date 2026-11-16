#!/bin/bash
# Stage 2 (accepts the Android SDK license, run by a human decision): adb, emulator, arm64 image, AVD "spike".
set -euo pipefail
. "$(dirname "$0")/android-env.sh"; mkdir -p "$ANDROID_USER_HOME" "$ANDROID_AVD_HOME"
yes | sdkmanager --licenses >/dev/null
sdkmanager platform-tools emulator "system-images;android-34;google_apis;arm64-v8a"
echo no | avdmanager create avd -n spike -k "system-images;android-34;google_apis;arm64-v8a" --force
# boot: emulator -avd spike -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect &
