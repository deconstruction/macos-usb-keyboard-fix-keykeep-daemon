#!/bin/bash
# Build keykeep into an app bundle and install it as a launch agent.
# Re-running this replaces the installed copy; the Input Monitoring grant then
# has to be toggled off and on again (macOS keys ad-hoc grants to the code hash).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/Keykeep.app"
EXEC="$APP/Contents/MacOS/keykeep"
LABEL="local.keykeep.agent"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/keykeep.log"
INTERVAL="${INTERVAL:-5}"

for tool in swiftc codesign launchctl; do
    command -v "$tool" >/dev/null || { echo "missing $tool (Xcode Command Line Tools?)" >&2; exit 1; }
done

echo "==> building $EXEC"
mkdir -p "$APP/Contents/MacOS" "$HOME/Library/LaunchAgents"
swiftc -O "$HERE/keykeep.swift" -o "$EXEC"

cat > "$APP/Contents/Info.plist" <<'INFO_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Keykeep</string>
    <key>CFBundleDisplayName</key><string>Keykeep</string>
    <key>CFBundleIdentifier</key><string>local.keykeep.app</string>
    <key>CFBundleExecutable</key><string>keykeep</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
INFO_EOF

codesign -s - -f --deep "$APP" >/dev/null 2>&1

echo "==> writing $AGENT"
cat > "$AGENT" <<AGENT_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXEC</string>
        <string>poke</string>
        <string>--interval</string>
        <string>$INTERVAL</string>
        <string>--led</string>
        <string>--log</string>
        <string>$LOG</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
AGENT_EOF

plutil -lint "$AGENT" >/dev/null

echo "==> restarting agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

sleep 1
open -a "$APP" || true   # makes the app appear in the Input Monitoring list

cat <<DONE_EOF

==> done. Now grant the permission (macOS shows no dialog to background processes):

    System Settings -> Privacy & Security -> Input Monitoring -> enable "Keykeep"

    then:  launchctl kickstart -k gui/$(id -u)/$LABEL

Log:    $LOG
Status: $EXEC status
DONE_EOF
