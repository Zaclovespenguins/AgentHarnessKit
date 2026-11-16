# source this: everything Android lives in .android-env/ (delete that folder to uninstall).
E="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/.android-env"
export JAVA_HOME="$E/jdk/Contents/Home" ANDROID_HOME="$E/sdk" ANDROID_USER_HOME="$E/user" ANDROID_AVD_HOME="$E/avd"
export ANDROID_NDK_HOME="$E/android-ndk-r30" SWIFT_SDKS="$E/swift-sdks"
export PATH="$E/swift-toolchain/usr/bin:$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
