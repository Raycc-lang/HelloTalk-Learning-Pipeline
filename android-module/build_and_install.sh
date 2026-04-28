#!/bin/bash
set -e

# Configuration (customize these for your environment)
DEVICE="192.168.1.13:5555"
APK_PATH="app/build/outputs/apk/debug/app-debug.apk"

# Set your Android SDK path
export ANDROID_HOME=${ANDROID_HOME:-$HOME/Android/Sdk}

echo "=== Building HelloTalkCapture ==="
./gradlew assembleDebug

echo ""
echo "=== Installing on device ==="
adb -s "$DEVICE" install -r "$APK_PATH"

echo ""
echo "=== Installed successfully ==="
echo ""
echo "NEXT STEPS:"
echo "1. Open LSPosed Manager on your device"
echo "2. Go to Modules → Enable 'HelloTalk Capture'"
echo "3. Set scope to 'com.hellotalk'"
echo "4. Force-stop HelloTalk and reopen"
echo "5. Check /sdcard/HelloTalkCapture/ for captured audio"
