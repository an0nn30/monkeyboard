#!/bin/bash
set -euo pipefail
if [[ $# != 4 ]]; then echo 'Usage: public-replay.sh SIM_UDID REPLAY_BINARY KEYBOARD_APPEX OUTPUT_JSONL' >&2; exit 2; fi
dir=$(cd "$(dirname "$0")" && pwd)
xcrun simctl spawn "$1" "$2" "$3" "$dir/public.json" > "$4"
