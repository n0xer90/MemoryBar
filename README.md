# MemoryBar

A lightweight macOS menu bar app that shows real-time memory and CPU usage.

![macOS](https://img.shields.io/badge/macOS-12%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange) ![Size](https://img.shields.io/badge/size-~90KB-green)

## Features

- **Dual sparkline graphs** in the menu bar (memory + CPU)
- **Memory pressure** indicator using the same kernel metric as Activity Monitor (`kern.memorystatus_vm_pressure_level`)
- **Top 5 processes** by memory usage
- **Swap usage** monitoring
- **Collapsible sections** with smooth animations in the dropdown
- **Text mode** alternative (`M:77% C:23%`)
- **Launch at Login** support
- ~90KB binary, no dependencies, no Electron

## Screenshots

Click the menu bar graphs to open the detail popover:

| Menu Bar | Popover |
|----------|---------|
| Two sparkline graphs (memory green, CPU cyan) | Collapsible sections with memory breakdown, CPU, top processes |

## Building

Requires Xcode command line tools on macOS 12+.

```bash
# Compile
swiftc -O -o MemoryBar main.swift -framework Cocoa

# Create app bundle
mkdir -p MemoryBar.app/Contents/MacOS
mkdir -p MemoryBar.app/Contents/Resources
cp MemoryBar MemoryBar.app/Contents/MacOS/
cp Info.plist MemoryBar.app/Contents/
cp AppIcon.icns MemoryBar.app/Contents/Resources/

# Launch
open MemoryBar.app
```

Or use the included build script:

```bash
./build.sh
```

## How It Works

- **Memory stats**: `host_statistics64()` Mach API with `HOST_VM_INFO64` for active, wired, compressed, inactive, and free memory
- **Memory pressure**: `kern.memorystatus_vm_pressure_level` sysctl (Normal / Warning / Critical)
- **CPU usage**: `host_statistics()` with `HOST_CPU_LOAD_INFO`, computed from tick deltas
- **Swap**: `vm.swapusage` sysctl
- **Top processes**: `ps -Ao rss=,comm= -m`
- **Menu bar**: `NSStatusItem` with custom `NSImage` drawing
- **Popover**: Custom `NSPopover` with `NSStackView` layout and animated collapsible sections

## Graph Colors

**Memory** reflects kernel memory pressure:
- Green = Normal
- Yellow = Warning
- Red = Critical

**CPU** reflects current usage:
- Cyan = < 50%
- Orange = 50-80%
- Red = > 80%

## License

MIT
