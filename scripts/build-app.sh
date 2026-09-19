#!/usr/bin/env bash
# Builds "To Do MCP.app" (menu-bar app + a private Python with the MCP server) into dist/.
#
# Needs: macOS 13+, Swift (Xcode or the Command Line Tools) and uv. Output is unsigned
# (ad-hoc signed) and for this Mac's architecture only.
#
# Everything is built under a neutral /tmp path, so no file inside the app records the
# builder's home folder or username (compiled Swift and Python bytecode embed build paths).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="To Do MCP"
BUNDLE_ID="io.github.qingyaoai.todo-mcp"
PY_VERSION="3.12"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$REPO/pyproject.toml" | head -1)"
ARCH="$(uname -m)"
STAGE="/tmp/todo-mcp-build"
SRC="$STAGE/src"
APP="$STAGE/$APP_NAME.app"
PYDIR="$APP/Contents/Resources/python"

step() { printf '\n==> %s\n' "$*"; }

step "Staging sources in $STAGE"
rm -rf "$STAGE"
mkdir -p "$SRC" "$APP/Contents/MacOS" "$APP/Contents/Resources/skills"
for item in Package.swift Sources pyproject.toml uv.lock .python-version src skills README.md LICENSE; do
    cp -R "$REPO/$item" "$SRC/"
done
find "$SRC" -name __pycache__ -prune -exec rm -rf {} +

step "Building the Swift menu-bar app"
swift build -c release --package-path "$SRC" --scratch-path "$STAGE/swift-build"
cp "$STAGE/swift-build/release/ToDoMCP" "$APP/Contents/MacOS/ToDoMCP"

step "Installing a private Python $PY_VERSION"
uv python install "$PY_VERSION" --install-dir "$STAGE/py" --no-bin --quiet
PYBASE="$(find "$STAGE/py" -mindepth 1 -maxdepth 1 -type d -name 'cpython-*' | head -1)"
mv "$PYBASE" "$PYDIR"
PY="$PYDIR/bin/python3"
# Drop parts of the standard library the server never uses (GUI toolkits, tests, installers).
rm -rf "$PYDIR"/lib/python3.*/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3} \
       "$PYDIR"/lib/python3.*/lib-dynload/_tkinter* \
       "$PYDIR"/lib/{tcl,tk,itcl,thread}* "$PYDIR"/share "$PYDIR"/include

step "Installing the server and its pinned dependencies"
(cd "$SRC" && uv export --frozen --no-dev --no-emit-project --no-hashes --quiet -o "$STAGE/requirements.txt")
uv pip install --python "$PY" --break-system-packages --quiet -r "$STAGE/requirements.txt"
uv pip install --python "$PY" --break-system-packages --quiet --no-deps "$SRC"
# Console scripts carry absolute build-path shebangs and aren't needed: the launcher below
# runs `python -m mstodo_mcp`.
find "$PYDIR/bin" -mindepth 1 ! -name python ! -name python3 ! -name 'python3.[0-9]*' -delete
find "$PYDIR/bin" -name '*-config' -delete
"$PY" -m compileall -q -j 0 --invalidation-mode unchecked-hash "$PYDIR/lib" || true

step "Adding the launcher, skill and Info.plist"
cat > "$APP/Contents/MacOS/mstodo-mcp" <<'EOF'
#!/bin/sh
# Microsoft To Do MCP server (stdio) and its CLI: mstodo-mcp [serve|login|logout|status|...]
HERE="$(cd "$(dirname "$0")" && pwd -P)"
exec "$HERE/../Resources/python/bin/python3" -I -B -m mstodo_mcp "$@"
EOF
chmod +x "$APP/Contents/MacOS/mstodo-mcp"
cp -R "$SRC/skills/ms-todo" "$APP/Contents/Resources/skills/"
cp "$SRC/LICENSE" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>ToDoMCP</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
EOF

step "Signing (ad hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

step "Checking the app for personal paths"
if grep -rl --binary-files=text -F "$HOME" "$APP" >/dev/null 2>&1; then
    echo "error: the app contains the builder's home path; not packaging:" >&2
    grep -rl --binary-files=text -F "$HOME" "$APP" >&2
    exit 1
fi

step "Smoke test"
"$APP/Contents/MacOS/mstodo-mcp" status --json || true

step "Packaging"
mkdir -p "$REPO/dist"
rm -rf "$REPO/dist/$APP_NAME.app"
ditto "$APP" "$REPO/dist/$APP_NAME.app"
ZIP="$REPO/dist/To-Do-MCP-$VERSION-macos-$ARCH.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
du -sh "$REPO/dist/$APP_NAME.app" "$ZIP"
echo "Done: $REPO/dist/$APP_NAME.app"
