#!/bin/bash
# Stage 1: no license click-through. JDK, cmdline-tools, NDK, OSS Swift toolchain, Android Swift SDK.
set -euo pipefail
. "$(dirname "$0")/android-env.sh"; mkdir -p "$E/dl"; cd "$E"
get() { [ -f "dl/$1" ] || curl -fL --retry 3 -o "dl/$1" "$2"; }
get jdk.tgz "https://api.adoptium.net/v3/binary/latest/21/ga/mac/aarch64/jdk/hotspot/normal/eclipse"
get cmdline.zip https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip
get ndk.zip https://dl.google.com/android/repository/android-ndk-r30-Darwin.zip
get swift.pkg https://download.swift.org/swift-6.4.2-release/xcode/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE-osx.pkg
[ -d jdk ] || { mkdir jdk; tar xzf dl/jdk.tgz -C jdk --strip-components=1; }
[ -d sdk/cmdline-tools/latest ] || { mkdir -p sdk/t; unzip -q dl/cmdline.zip -d sdk/t; mkdir -p sdk/cmdline-tools; mv sdk/t/cmdline-tools sdk/cmdline-tools/latest; rmdir sdk/t; }
[ -d android-ndk-r30 ] || unzip -q dl/ndk.zip
# expand-full unpacks the pkg payload into a folder; nothing is installed system-wide
[ -d pkgx ] || pkgutil --expand-full dl/swift.pkg pkgx
[ -e swift-toolchain ] || ln -s "$(ls -d pkgx/*/Payload | head -1)" swift-toolchain
swift --version 2>&1 | head -2
swift sdk install https://download.swift.org/swift-6.4.2-release/android-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_android.artifactbundle.tar.gz \
  --checksum 4d6ad63ea74becd58e123ff58b1b48c3be5ec0db0dff0ea5abe37ac007dd3233 --swift-sdks-path "$SWIFT_SDKS"
swift sdk list --swift-sdks-path "$SWIFT_SDKS"
echo STAGE1-DONE
