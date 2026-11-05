#!/bin/zsh
set -eu
cd "$(dirname "$0")"
args=(-Xswiftc -warnings-as-errors)
# Recent Command Line Tools keep Swift Testing macros in a separate directory.
# Supply it explicitly when present; no package dependencies are downloaded.
TESTING_PLUGIN_DIR="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing"
if [[ -d "$TESTING_PLUGIN_DIR" ]]; then
    args+=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGIN_DIR")
fi
swift test "${args[@]}" "$@"
