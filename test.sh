#!/usr/bin/env bash
# Runs the automated tests: ./test.sh   (extra arguments go to `swift test`, e.g. ./test.sh --filter Rename)
set -euo pipefail
cd "$(dirname "$0")"

flags=()
# With only the Command Line Tools (no Xcode), Swift Testing lives outside the default search paths.
if [[ "$(xcode-select -p)" == */CommandLineTools ]]; then
    frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    libs=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
    flags+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks"
            -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libs")
fi
swift test "${flags[@]}" "$@"
