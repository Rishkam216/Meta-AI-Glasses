#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'The native app requires macOS. Run swift test for AgentCore on Linux.' >&2
  exit 1
fi
swift build -c release --product MacAgent
agent_binary_dir="$(swift build -c release --show-bin-path)"
agent_bundle="$PWD/dist/MetaAIGlasses.app"
mkdir -p "$agent_bundle/Contents/MacOS"
cp "$agent_binary_dir/MacAgent" "$agent_bundle/Contents/MacOS/MacAgent"
cp Resources/Info.plist "$agent_bundle/Contents/Info.plist"
/usr/bin/plutil -lint "$agent_bundle/Contents/Info.plist"
# Local development only. For stable TCC identity, pass a real signing identity.
/usr/bin/codesign --force --sign "${MAC_AGENT_SIGNING_IDENTITY:--}" "$agent_bundle"
/usr/bin/codesign --verify --strict "$agent_bundle"
echo "Built $agent_bundle"
