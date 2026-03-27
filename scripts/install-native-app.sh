#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/native/macos/DiskscopeNative/DiskscopeNative.xcodeproj"
SCHEME="DiskscopeNative"
APP_NAME="DiskscopeNative.app"
DERIVED_DATA_PATH="$ROOT_DIR/native/macos/DiskscopeNative/build"
CONFIGURATION="Release"
DEST_DIR="$HOME/Applications"
OPEN_AFTER_INSTALL=1
CLEAN_BUILD=0
HOST_ARCH="$(uname -m)"

print_help() {
    cat <<'EOF'
Install DiskscopeNative.app locally.

Usage:
  scripts/install-native-app.sh [options]

Options:
  --debug            Build Debug configuration instead of Release.
  --release          Build Release configuration (default).
  --clean            Remove local native build artifacts before building.
  --dest DIR         Install app bundle into DIR.
  --system           Install into /Applications.
  --no-open          Do not launch app after install.
  -h, --help         Show this help.

Examples:
  scripts/install-native-app.sh
  scripts/install-native-app.sh --clean
  scripts/install-native-app.sh --system --clean
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            CONFIGURATION="Debug"
            shift
            ;;
        --release)
            CONFIGURATION="Release"
            shift
            ;;
        --clean)
            CLEAN_BUILD=1
            shift
            ;;
        --dest)
            if [[ $# -lt 2 ]]; then
                echo "error: --dest requires a directory path" >&2
                exit 2
            fi
            DEST_DIR="$2"
            shift 2
            ;;
        --system)
            DEST_DIR="/Applications"
            shift
            ;;
        --no-open)
            OPEN_AFTER_INSTALL=0
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            print_help >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "error: native Xcode project not found at $PROJECT_PATH" >&2
    exit 1
fi

if [[ $CLEAN_BUILD -eq 1 ]]; then
    echo "cleaning native build artifacts: $DERIVED_DATA_PATH"
    rm -rf "$DERIVED_DATA_PATH"
fi

SOURCE_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
DEST_APP_PATH="$DEST_DIR/$APP_NAME"

echo "building native app ($CONFIGURATION)..."
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    ONLY_ACTIVE_ARCH=YES \
    ARCHS="$HOST_ARCH" \
    build

if [[ ! -d "$SOURCE_APP_PATH" ]]; then
    echo "error: build finished but app bundle was not found at $SOURCE_APP_PATH" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

if [[ -d "$DEST_APP_PATH" ]]; then
    rm -rf "$DEST_APP_PATH"
fi

echo "installing app to: $DEST_APP_PATH"
ditto "$SOURCE_APP_PATH" "$DEST_APP_PATH"

# Clear quarantine bit when copied from local build output.
xattr -dr com.apple.quarantine "$DEST_APP_PATH" 2>/dev/null || true

echo "installed successfully: $DEST_APP_PATH"
if [[ $OPEN_AFTER_INSTALL -eq 1 ]]; then
    echo "launching app..."
    open -a "$DEST_APP_PATH"
fi
