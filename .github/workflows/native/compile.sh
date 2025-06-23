#!/bin/bash

# Native macOS Components Compilation Script
# This script compiles both the Swift audio recorder and Objective-C microphone monitor

set -e  # Exit on any error

echo "🔨 Compiling Native macOS Components..."

# Check if we're on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ Error: This script must be run on macOS"
    exit 1
fi

# Check for required tools
if ! command -v swiftc &> /dev/null; then
    echo "❌ Error: swiftc not found. Please install Xcode Command Line Tools:"
    echo "   xcode-select --install"
    exit 1
fi

if ! command -v clang &> /dev/null; then
    echo "❌ Error: clang not found. Please install Xcode Command Line Tools:"
    echo "   xcode-select --install"
    exit 1
fi

# Compile Swift Audio Recorder
echo "📱 Compiling Swift audio recorder..."
swiftc -o audioRecorder \
    -framework AVFoundation \
    -framework ScreenCaptureKit \
    -framework Foundation \
    -framework CoreMedia \
    -framework CoreAudio \
    audioRecorder.swift

if [ $? -eq 0 ]; then
    echo "✅ Swift audio recorder compiled successfully"
    ls -la audioRecorder
else
    echo "❌ Failed to compile Swift audio recorder"
    exit 1
fi

# Compile Swift Microphone Recorder
echo "🎤 Compiling Swift microphone recorder..."
swiftc -o micRecorder \
    -framework AVFoundation \
    -framework Foundation \
    micRecorder.swift

if [ $? -eq 0 ]; then
    echo "✅ Swift microphone recorder compiled successfully"
    ls -la micRecorder
else
    echo "❌ Failed to compile Swift microphone recorder"
    exit 1
fi

# Compile Objective-C Microphone Monitor
echo "🎤 Compiling Objective-C microphone monitor..."
clang -o MicMonitor \
    -framework Foundation \
    -framework CoreAudio \
    -framework AudioToolbox \
    MicMonitor.m

if [ $? -eq 0 ]; then
    echo "✅ Objective-C microphone monitor compiled successfully"
    ls -la MicMonitor
else
    echo "❌ Failed to compile Objective-C microphone monitor"
    exit 1
fi

# Make binaries executable
chmod +x audioRecorder micRecorder MicMonitor

echo ""
echo "🎉 Compilation completed successfully!"
echo ""
echo "📋 Usage:"
echo "  ./audioRecorder --check-permissions     # Check screen recording permissions"
echo "  ./audioRecorder --check-all-permissions # Check all permissions"
echo "  ./micRecorder start                     # Start streaming microphone audio"
echo "  ./micRecorder stop                      # Stop streaming (if running)"
echo "  ./MicMonitor                            # Monitor microphone activity"
echo ""
echo "⚠️  Note: All applications require appropriate permissions in System Preferences > Security & Privacy" 