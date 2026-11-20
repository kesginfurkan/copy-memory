#!/usr/bin/env bash
# End-to-end test: real Docker backend + real agent + real macOS pasteboard.
# Uses its own port, data dir and compose project, so your real history is not touched.
# Your current clipboard text is saved and restored at the end.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=5099
API="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"
PROJECT=copy-memory-e2e
AGENT_PID=""
PASS=0

export PORT DATA_DIR="$WORK/data"

cleanup() {
  [[ -n "$AGENT_PID" ]] && kill "$AGENT_PID" 2>/dev/null || true
  docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml" down >/dev/null 2>&1 || true
  [[ -f "$WORK/clipboard.bak" ]] && pbcopy < "$WORK/clipboard.bak"
  rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; echo "--- agent log ---"; cat "$WORK/agent.log" || true; exit 1; }

# Writes to the pasteboard with arbitrary UTIs (pbcopy can only do plain text).
jxa() { osascript -l JavaScript -e "ObjC.import('AppKit'); var pb = \$.NSPasteboard.generalPasteboard; $1" >/dev/null; }

# search <query> -> prints JSON of first match (or empty)
search() { curl -sf "$API/api/items?q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")" ; }
field()  { python3 -c "import sys,json; d=json.load(sys.stdin); it=d['items']; print(it[0]['$1'] if it else '')"; }

wait_for() {  # wait_for <query> -> waits until an item matching query exists
  for _ in $(seq 1 40); do
    [[ -n "$(search "$1" | field id)" ]] && return 0
    sleep 0.25
  done
  return 1
}

pbpaste > "$WORK/clipboard.bak" || true

echo "▸ building agent"
(cd "$ROOT/agent" && swift build -q)
AGENT="$ROOT/agent/.build/debug/copy-memory-agent"

echo "▸ starting backend on :$PORT"
mkdir -p "$DATA_DIR"
docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml" up -d --build >/dev/null 2>&1
for _ in $(seq 1 60); do curl -sf "$API/api/health" >/dev/null && break; sleep 0.5; done
curl -sf "$API/api/health" >/dev/null || fail "backend did not become healthy"

echo "▸ starting agent"
COPY_MEMORY_API="$API" COPY_MEMORY_AUTO_PASTE=0 COPY_MEMORY_HOTKEY="ctrl+option+cmd+0" COPY_MEMORY_POLL_INTERVAL=0.2 \
  "$AGENT" >"$WORK/agent.log" 2>&1 &
AGENT_PID=$!
sleep 1

echo "▸ scenarios"
TAG="e2e$RANDOM$RANDOM"

printf 'düz metin %s' "$TAG" | pbcopy
wait_for "duz metin $TAG" || fail "plain text was not recorded"
[[ "$(search "duz metin $TAG" | field kind)" == "text" ]] || fail "plain text kind"
ok "plain text recorded (diacritic-insensitive search works)"

jxa "pb.clearContents; pb.setStringForType(\$('<b>zengin $TAG</b>'), \$('public.html')); pb.setStringForType(\$('zengin $TAG'), \$('public.utf8-plain-text'));"
wait_for "zengin $TAG" || fail "rich text was not recorded"
RICH_ID="$(search "zengin $TAG" | field id)"
[[ "$(search "zengin $TAG" | field kind)" == "rich" ]] || fail "rich kind"
ok "rich text (HTML + plain) recorded"

python3 -c "import base64,sys; open(sys.argv[1],'wb').write(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='))" "$WORK/px.png"
BEFORE="$(curl -sf "$API/api/stats" | python3 -c 'import sys,json; print(json.load(sys.stdin)["kinds"].get("image",0))')"
jxa "pb.clearContents; pb.setDataForType(\$.NSData.dataWithContentsOfFile('$WORK/px.png'), \$('public.png'));"
for _ in $(seq 1 40); do
  NOW="$(curl -sf "$API/api/stats" | python3 -c 'import sys,json; print(json.load(sys.stdin)["kinds"].get("image",0))')"
  [[ "$NOW" -gt "$BEFORE" ]] && break; sleep 0.25
done
[[ "$NOW" -gt "$BEFORE" ]] || fail "image was not recorded"
IMG_ID="$(curl -sf "$API/api/items?kind=image" | field id)"
curl -sf -o /dev/null "$API/api/items/$IMG_ID/thumbnail" || fail "image thumbnail missing"
ok "image recorded with thumbnail"

touch "$WORK/dosya-$TAG.txt"
jxa "pb.clearContents; pb.writeObjects(\$([\$.NSURL.fileURLWithPath('$WORK/dosya-$TAG.txt')]));"
wait_for "dosya-$TAG" || fail "file was not recorded"
[[ "$(search "dosya-$TAG" | field kind)" == "file" ]] || fail "file kind"
ok "copied file recorded as path"

jxa "pb.clearContents; pb.setStringForType(\$('gizli $TAG'), \$('public.utf8-plain-text')); pb.setStringForType(\$(''), \$('org.nspasteboard.ConcealedType'));"
sleep 1.5
[[ -z "$(search "gizli $TAG" | field id)" ]] || fail "concealed (password) copy was recorded"
ok "concealed/password copies are ignored"

printf 'düz metin %s' "$TAG" | pbcopy
sleep 1
[[ "$(search "duz metin $TAG" | field copy_count)" == "2" ]] || fail "duplicate was not de-duplicated"
ok "duplicate copy bumps the existing item"

echo "x" | pbcopy
COPY_MEMORY_API="$API" "$AGENT" restore "$RICH_ID" || fail "restore command failed"
[[ "$(pbpaste)" == "zengin $TAG" ]] || fail "restored plain text mismatch"
TYPES="$(osascript -l JavaScript -e "ObjC.import('AppKit'); JSON.stringify(ObjC.deepUnwrap(\$.NSPasteboard.generalPasteboard.types))")"
[[ "$TYPES" == *public.html* ]] || fail "restored item lost its HTML representation: $TYPES"
ok "restore puts every representation back on the clipboard"

echo "▸ all $PASS end-to-end scenarios passed"
