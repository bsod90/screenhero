# ScreenHero

A low-latency screen sharing application for macOS, built with Swift and leveraging hardware-accelerated video encoding/decoding.

## Features

- **Hardware-accelerated encoding/decoding** using VideoToolbox (H.264/HEVC)
- **Low-latency streaming** via QUIC protocol
- **Bonjour discovery** for automatic host detection on local networks
- **Secure pairing** with PIN-based authentication
- **Native macOS UI** built with SwiftUI

## Requirements

- macOS 14.0 (Sonoma) or later
- Screen Recording permission (for host)

## Building

```bash
# Build release binaries
./bin/build.sh

# Or build manually
swift build -c release
```

## Running

### Host (share your screen)

```bash
./bin/ScreenHeroHost
```

Grant Screen Recording permission when prompted (System Settings → Privacy & Security → Screen Recording).

### Viewer (view remote screen)

```bash
./bin/ScreenHeroViewer
```

The viewer will automatically discover hosts on the local network via Bonjour.

## Architecture

```
ScreenHero/
├── Sources/
│   ├── ScreenHeroCore/     # Shared library
│   │   ├── Capture/        # Screen capture (ScreenCaptureKit)
│   │   ├── Encoding/       # Video encoding (VideoToolbox)
│   │   ├── Decoding/       # Video decoding (VideoToolbox)
│   │   ├── Transport/      # QUIC networking
│   │   ├── Discovery/      # Bonjour service discovery
│   │   └── Auth/           # Pairing and authentication
│   ├── ScreenHeroHost/     # Host application
│   └── ScreenHeroViewer/   # Viewer application
└── Tests/
```

## Security Note

The built binaries are not code-signed. On first run, macOS Gatekeeper may block execution. To allow:

1. Open **System Settings** → **Privacy & Security**
2. Click **Open Anyway** next to the blocked app warning

Or remove the quarantine attribute:
```bash
xattr -cr ./bin/ScreenHeroHost ./bin/ScreenHeroViewer
```

## License

MIT
