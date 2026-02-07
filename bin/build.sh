#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Building ScreenHero (release)..."
cd "$PROJECT_DIR"

swift build -c release

echo "Copying binaries to $PROJECT_DIR..."
cp "$(swift build -c release --show-bin-path)/ScreenHeroHost" "$PROJECT_DIR/"
cp "$(swift build -c release --show-bin-path)/ScreenHeroViewer" "$PROJECT_DIR/"

# Remove quarantine attribute to avoid Gatekeeper issues
xattr -cr "$PROJECT_DIR/ScreenHeroHost" "$PROJECT_DIR/ScreenHeroViewer" 2>/dev/null || true

echo "Done!"
echo ""
echo "Binaries:"
ls -lh "$PROJECT_DIR/ScreenHeroHost" "$PROJECT_DIR/ScreenHeroViewer"
echo ""
echo "Usage:"
echo "  Host:   ./ScreenHeroHost --help"
echo "  Viewer: ./ScreenHeroViewer --help"
