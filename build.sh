#!/bin/bash
set -e

echo "Compiling MemoryBar..."
swiftc -O -o MemoryBar main.swift -framework Cocoa

echo "Building app bundle..."
mkdir -p MemoryBar.app/Contents/MacOS
mkdir -p MemoryBar.app/Contents/Resources
cp MemoryBar MemoryBar.app/Contents/MacOS/
cp Info.plist MemoryBar.app/Contents/
cp AppIcon.icns MemoryBar.app/Contents/Resources/

echo "Done. Run: open MemoryBar.app"
