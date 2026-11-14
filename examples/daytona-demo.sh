#!/usr/bin/env bash
# End-to-end conduit demo on a fresh Daytona sandbox.
#
#   DAYTONA_API_KEY=dtn_... ./examples/daytona-demo.sh
#
# 1. makes a demo folder on your laptop with some files and lists it
# 2. creates a Daytona sandbox and runs `conduit up --write-back-new`
# 3. proves it works with commands on the sandbox:
#    same path + same files, live laptop edits, read-only laptop files,
#    sandbox-only edits, and new files flowing back to the laptop
# 4. drops you into a shell on the sandbox, in the mirrored folder
# 5. on exit: stops conduit and deletes the sandbox (KEEP=1 to keep it)
set -euo pipefail
: "${DAYTONA_API_KEY:?set DAYTONA_API_KEY=dtn_...}"
API=${DAYTONA_API_URL:-https://app.daytona.io/api}
H=(-H "Authorization: Bearer $DAYTONA_API_KEY" -H 'Content-Type: application/json')
HERE=$(cd "$(dirname "$0")/.." && pwd)
CONDUIT=${CONDUIT:-$HERE/conduit}
[ -x "$CONDUIT" ] || CONDUIT="npx -y conduit-fs"
DEMO=${DEMO_DIR:-$HOME/conduit-demo}

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
run()  { printf '\033[2m$ %s\033[0m\n' "$*"; }
json() { python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }

# ---------------------------------------------------------------- 1. local files
step "1/5  Creating demo files on your laptop in $DEMO"
rm -rf "$DEMO"; mkdir -p "$DEMO/src" "$DEMO/data"
cat > "$DEMO/README.md" <<'EOF'
# conduit demo
These files live on the laptop.
EOF
printf 'def hello():\n    return "hello from the laptop"\n' > "$DEMO/src/app.py"
printf 'id,name\n1,ada\n2,linus\n3,grace\n' > "$DEMO/data/users.csv"
run "ls -la $DEMO"; ls -la "$DEMO"
run "find $DEMO -type f"; find "$DEMO" -type f

# ---------------------------------------------------------------- 2. sandbox + conduit
step "2/5  Creating a Daytona sandbox"
ID=$(curl -fsS -m 120 -X POST "${H[@]}" "$API/sandbox" \
  -d '{"name":"conduit-demo-'$RANDOM'","labels":{"purpose":"conduit-demo"},"autoStopInterval":30,"autoDeleteInterval":60}' | json '["id"]')
for _ in $(seq 60); do
  [ "$(curl -fsS "${H[@]}" "$API/sandbox/$ID" | json '["state"]')" = started ] && break; sleep 2
done
T=$(curl -fsS -X POST "${H[@]}" "$API/sandbox/$ID/ssh-access?expiresInMinutes=120" | json '["sshCommand"].split()[-1]')
echo "sandbox $ID ready"
SSHO=(-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ControlMaster=auto -o "ControlPath=/tmp/conduit-%C" -o ControlPersist=120)
on_sandbox() { run "[sandbox] $*"; ssh -T "${SSHO[@]}" "$T" "$*"; }

LOG=$(mktemp /tmp/conduit-demo.XXXX)
cleanup() {
  [ -n "${CPID:-}" ] && { kill -TERM "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null || true; }
  if [ "${KEEP:-0}" = 1 ]; then echo "kept sandbox $ID (ssh $T)"
  else curl -fsS -o /dev/null -X DELETE "${H[@]}" "$API/sandbox/$ID" && echo "deleted sandbox $ID"; fi
  rm -f "$LOG"
}
trap cleanup EXIT

step "Starting conduit (writable on the sandbox + new files written back)"
run "conduit up $T --path $DEMO --write-back-new"
CONDUIT_SYNC_INTERVAL=2 $CONDUIT up "$T" --path "$DEMO" --write-back-new > "$LOG" 2>&1 &
CPID=$!
for _ in $(seq 150); do grep -qE "mirroring|conduit: " "$LOG" && break; sleep 1; done
cat "$LOG"; grep -q mirroring "$LOG" || { echo "conduit failed to start"; exit 1; }

# ---------------------------------------------------------------- 3. proofs
step "3/5  Proving it works, from the sandbox"
on_sandbox "hostname; uname -sr"
on_sandbox "ls -la '$DEMO'   # same absolute path as on your laptop"
on_sandbox "cat '$DEMO/README.md'; cd '$DEMO' && python3 -c 'import sys; sys.path.insert(0, \"src\"); import app; print(app.hello())'"
on_sandbox "wc -l '$DEMO/data/users.csv'; grep '$DEMO' /proc/mounts | awk '{print \$1, \$3}'"

step "Live: edit a file on the laptop, read it on the sandbox"
run "echo '4,margaret' >> $DEMO/data/users.csv   (on your laptop)"; echo '4,margaret' >> "$DEMO/data/users.csv"
sleep 1; on_sandbox "tail -2 '$DEMO/data/users.csv'"

step "Sandbox edits stay on the sandbox (laptop file untouched)"
on_sandbox "echo 'edited in the sandbox' >> '$DEMO/README.md' && tail -1 '$DEMO/README.md'"
run "tail -1 $DEMO/README.md   (on your laptop)"; tail -1 "$DEMO/README.md"

step "New files from the sandbox are written back to the laptop"
on_sandbox "mkdir -p '$DEMO/out' && python3 -c 'import csv; r=list(csv.DictReader(open(\"$DEMO/data/users.csv\"))); open(\"$DEMO/out/report.txt\",\"w\").write(f\"{len(r)} users\\n\")' && cat '$DEMO/out/report.txt'"
for _ in $(seq 15); do [ -f "$DEMO/out/report.txt" ] && break; sleep 1; done
run "cat $DEMO/out/report.txt   (on your laptop)"; cat "$DEMO/out/report.txt" 2>/dev/null || echo "(not synced yet)"

step "What the sandbox changed (conduit diff)"
run "conduit diff $T --path $DEMO"; $CONDUIT diff "$T" --path "$DEMO" 2>/dev/null

# ---------------------------------------------------------------- 4. login
step "4/5  Logging you into the sandbox, in $DEMO. Try: ls, cat, python3, touch new.txt. Type 'exit' when done."
ssh -t "${SSHO[@]}" "$T" "cd '$DEMO' && exec bash -l" || true

step "5/5  Cleaning up"
