# ScreenHero

A low-latency screen sharing application for macOS, built with Swift and leveraging hardware-accelerated video encoding/decoding.

## Features

- **Hardware-accelerated encoding/decoding** using VideoToolbox (H.264/HEVC)
- **Low-latency streaming** via UDP
- **Pure CLI interface** - all parameters controllable via command line
- **1440p @ 60fps** default (adjustable up to 4K)

## Requirements

- macOS 14.0 (Sonoma) or later
- Screen Recording permission (for host)

## Building

```bash
# Build release binaries into ./bin
./build.sh

# Pull latest changes and rebuild
./update.sh

# Or build manually
swift build -c release
cp .build/release/ScreenHeroHost ./bin/
cp .build/release/ScreenHeroViewer ./bin/
```

## Running

### Host (share your screen)

```bash
# Default settings (1920x1080 @ 60fps, H.264, port 5000)
./bin/ScreenHeroHost

# 1440p @ 60fps with HEVC (recommended)
./bin/ScreenHeroHost -w 2560 -h 1440 -b 30 -c hevc

# 4K @ 60fps with HEVC
./bin/ScreenHeroHost -w 3840 -h 2160 -b 50 -c hevc

# Show all options
./bin/ScreenHeroHost --help
```

Grant Screen Recording permission when prompted (System Settings → Privacy & Security → Screen Recording).

**Host options:**
```
-p, --port <port>       Port to listen on (default: 5000)
-w, --width <pixels>    Stream width (default: 1920)
-h, --height <pixels>   Stream height (default: 1080)
-f, --fps <fps>         Frames per second (default: 60)
-b, --bitrate <mbps>    Bitrate in Mbps (default: 20)
-c, --codec <codec>     h264 or hevc (default: h264)
-k, --keyframe <frames> Keyframe interval (default: 30)
-d, --display <index>   Display index (default: 0)
```

### Viewer (view remote screen)

```bash
# Connect to host IP
./bin/ScreenHeroViewer -h 192.168.1.100

# With custom port
./bin/ScreenHeroViewer -h 192.168.1.100 -p 5000

# Fullscreen mode
./bin/ScreenHeroViewer -h 192.168.1.100 -f

# Show all options
./bin/ScreenHeroViewer --help
```

**Viewer options:**
```
-h, --host <ip>         Host IP address (required)
-p, --port <port>       Port number (default: 5000)
-w, --width <pixels>    Window width (default: 1920)
-H, --height <pixels>   Window height (default: 1080)
-f, --fullscreen        Run in fullscreen mode
```

## Architecture

```
ScreenHero/
├── Sources/
│   ├── ScreenHeroCore/     # Shared library
│   │   ├── Capture/        # Screen capture (ScreenCaptureKit)
│   │   ├── Encoding/       # Video encoding (VideoToolbox)
│   │   ├── Decoding/       # Video decoding (VideoToolbox)
│   │   ├── Network/        # UDP streaming
│   │   ├── Discovery/      # Bonjour service discovery
│   │   └── Auth/           # Pairing and authentication
│   ├── ScreenHeroHost/     # Host CLI application
│   └── ScreenHeroViewer/   # Viewer CLI application
└── Tests/
```

## Security Note

The built binaries are not code-signed. On first run, macOS Gatekeeper may block execution. To allow:

1. Open **System Settings** → **Privacy & Security**
2. Click **Open Anyway** next to the blocked app warning

Or remove the quarantine attribute:
```bash
xattr -cr ./ScreenHeroHost ./ScreenHeroViewer
```

## License

MIT
