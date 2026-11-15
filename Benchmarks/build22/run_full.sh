#!/bin/bash
# Replay all ten prepared corpus shards through a matching simulator binary/appex.
set -euo pipefail
if [[ $# -ne 5 ]]; then
  echo "Usage: $0 SIMULATOR_UDID REPLAY_EXECUTABLE KEYBOARD_APPEX PREPARED_DIR OUTPUT_DIR" >&2
  exit 2
fi
device=$1
executable=$2
extension=$3
inputs=$4
out=$5
jobs=${JOBS:-3}
case "$jobs" in 1|2|3|4|5|6|7|8|9|10) ;; *) echo 'JOBS must be 1 through 10' >&2; exit 2;; esac
if [[ ! -x "$executable" || ! -d "$extension" || ! -f "$inputs/all.json" ]]; then
  echo 'Provide a compiled simulator replay executable, matching extension directory, and prepared all.json' >&2
  exit 2
fi
base=$(cd "$(dirname "$0")" && pwd)
executable=$(cd "$(dirname "$executable")" && pwd)/$(basename "$executable")
extension=$(cd "$extension" && pwd)
inputs=$(cd "$inputs" && pwd)
mkdir -p "$out/logs"
out=$(cd "$out" && pwd)
work=$(mktemp -d "$out/.replay.XXXXXXXX")
pids=()
cleanup() {
  if (( ${#pids[@]} )); then
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 - "$inputs" <<'PY'
from pathlib import Path
import json, sys
p = Path(sys.argv[1])
all_rows = json.loads((p/'all.json').read_bytes())
if len(all_rows) != 100_000 or len({r['id'] for r in all_rows}) != len(all_rows):
    raise SystemExit('Expected 100,000 unique row IDs in all.json')
for i in range(10):
    rows = json.loads((p/f'all{i}.json').read_bytes())
    if rows != all_rows[i*10_000:(i+1)*10_000]:
        raise SystemExit(f'all{i}.json differs from its 10,000-row slice of all.json')
PY

wait_batch() {
  local status=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then status=1; fi
  done
  pids=()
  return "$status"
}

for i in {0..9}; do
  xcrun simctl spawn "$device" "$executable" "$extension" "$inputs/all$i.json" \
    > "$work/$i.jsonl" 2> "$out/logs/$i.log" &
  pids+=("$!")
  if (( ${#pids[@]} == jobs || i == 9 )); then wait_batch; fi
done

python3 "$base/blind/score.py" "$inputs/all.json" --baseline "$work"/*.jsonl --report "$work/summary.json"
# The fixture's numeric shard order is stable. Omit filename and timestamp in gzip.
python3 - "$work" <<'PY'
import gzip, shutil, sys
from pathlib import Path
p = Path(sys.argv[1])
with (p/'replay.jsonl.gz').open('wb') as dest, gzip.GzipFile(fileobj=dest, mode='wb', filename='', mtime=0) as gz:
    for i in range(10):
        with (p/f'{i}.jsonl').open('rb') as src:
            shutil.copyfileobj(src, gz)
PY
mv "$work/summary.json" "$out/summary.json"
mv "$work/replay.jsonl.gz" "$out/replay.jsonl.gz"
