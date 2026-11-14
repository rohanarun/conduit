#!/usr/bin/env bash
# conduit benchmark: how long sandboxes take to read laptop files through conduit,
# for 1 sandbox and for N sandboxes at once, versus plain ssh copies.
#
#   bench/bench.sh targets.txt [BIG_MB=50] [SMALL_FILES=500] [SMALL_KB=10]
#
# targets.txt: one ssh target per line. Results are printed as Markdown.
set -euo pipefail
cd "$(dirname "$0")/.."
TFILE=$1 BIG=${2:-50} NSMALL=${3:-500} SKB=${4:-10}
TARGETS=(); while IFS= read -r l; do [ -n "$l" ] && TARGETS+=("$l"); done < "$TFILE"
N=${#TARGETS[@]}
O=(-o ControlMaster=auto -o "ControlPath=/tmp/conduit-%C" -o ControlPersist=300 -o StrictHostKeyChecking=accept-new)
rs()  { local t=$1; shift; ssh -T "${O[@]}" "$t" "$@"; }
now() { python3 -c 'import time;print(time.time())'; }
f2()  { python3 -c "print('%.2f' % ($1))"; }
log() { echo "# $*" >&2; }

DATA=$(cd "$(mktemp -d /tmp/cbench.XXXX)" && pwd -P); LOGS=$DATA.logs; mkdir -p "$LOGS"   # pwd -P: conduit mounts the resolved path
PIDS=()
cleanup() {
  set +e
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -TERM "$p" 2>/dev/null; done
  for p in ${PIDS[@]+"${PIDS[@]}"}; do while kill -0 "$p" 2>/dev/null; do sleep 1; done; done
  rm -rf "$DATA" "$LOGS"
}
trap cleanup EXIT
log "creating test data in $DATA (${BIG}MB file, ${NSMALL}x${SKB}KB files) for each scenario"
for d in single multi base; do
  mkdir -p "$DATA/$d/src"
  dd if=/dev/urandom of="$DATA/$d/big.bin" bs=1048576 count="$BIG" 2>/dev/null
  i=0; while [ $i -lt "$NSMALL" ]; do head -c $((SKB*1024)) /dev/urandom > "$DATA/$d/src/f$i.txt"; i=$((i+1)); done
done
SMALL_MB=$(python3 -c "print(round($NSMALL*$SKB/1024,1))")

for t in "${TARGETS[@]}"; do rs "$t" true; done   # warm ssh control connections

# ---- baseline: raw ssh upload bandwidth (laptop -> sandbox)
log "baseline: plain ssh upload"
s=$(now); cat "$DATA/base/big.bin" | rs "${TARGETS[0]}" 'cat > /dev/null'; e=$(now)
BW1=$(python3 -c "print('%.0f' % ($BIG*8/($e-$s)))"); RAW1=$(f2 "$e-$s")
s=$(now); COPYFILE_DISABLE=1 tar --no-xattrs -C "$DATA/base" -cf - src | rs "${TARGETS[0]}" 'mkdir -p /tmp/cb && tar -C /tmp/cb -xf - && rm -rf /tmp/cb'; e=$(now)
RAWSMALL=$(f2 "$e-$s")
s=$(now); for t in "${TARGETS[@]}"; do (cat "$DATA/base/big.bin" | rs "$t" 'cat > /dev/null') & done; wait; e=$(now)
RAWN=$(f2 "$e-$s"); BWN=$(python3 -c "print('%.0f' % ($N*$BIG*8/($e-$s)))")

# ---- start conduit on every sandbox
log "starting conduit on $N sandboxes"
s=$(now)
i=0; for t in "${TARGETS[@]}"; do
  ./conduit up "$t" --path "$DATA" --no-default-hide > "$LOGS/$i.log" 2>&1 & PIDS+=($!); i=$((i+1))
done
for i in $(seq 0 $((N-1))); do
  for _ in $(seq 300); do grep -qE "mirroring|conduit: " "$LOGS/$i.log" && break; sleep 1; done
  grep -q mirroring "$LOGS/$i.log" || { cat "$LOGS/$i.log" >&2; echo "sandbox $i failed to mount" >&2; exit 1; }
done
e=$(now); SETUP=$(f2 "$e-$s")

# remote timer: prints seconds taken by a shell snippet on the sandbox
rtime() { rs "$1" "s=\$(date +%s.%N); $2; e=\$(date +%s.%N); awk -v s=\$s -v e=\$e 'BEGIN{printf \"%.2f\", e-s}'"; }
P="$DATA"

log "single sandbox reads"
T0=${TARGETS[0]}
C_BIG=$(rtime "$T0" "cat '$P/single/big.bin' >/dev/null")
W_BIG=$(rtime "$T0" "cat '$P/single/big.bin' >/dev/null")
C_LS=$(rtime "$T0" "ls -lR '$P/single/src' >/dev/null")
C_SMALL=$(rtime "$T0" "cat '$P/single/src/'* >/dev/null")
C_TPUT=$(python3 -c "print('%.0f' % ($BIG*8/$C_BIG))")

log "$N sandboxes reading at once"
par() { # $1 = snippet; prints wall time; per-sandbox times to $LOGS/par
  : > "$LOGS/par"; local s e
  s=$(now)
  for t in "${TARGETS[@]}"; do (rtime "$t" "$1" >> "$LOGS/par"; echo >> "$LOGS/par") & done; wait
  e=$(now); f2 "$e-$s"
}
M_BIG=$(par "cat '$P/multi/big.bin' >/dev/null"); M_BIG_PER=$(sort -n "$LOGS/par" | sed '/^$/d' | awk '{a[NR]=$1} END{printf "%.2f / %.2f", a[int((NR+1)/2)], a[NR]}')
M_SMALL=$(par "cat '$P/multi/src/'* >/dev/null"); M_SMALL_PER=$(sort -n "$LOGS/par" | sed '/^$/d' | awk '{a[NR]=$1} END{printf "%.2f / %.2f", a[int((NR+1)/2)], a[NR]}')
M_TPUT=$(python3 -c "print('%.0f' % ($N*$BIG*8/$M_BIG))")

cat <<EOF
## Results ($(date -u +%Y-%m-%d), $N sandboxes)

Measured laptop uplink: **~$BW1 Mbit/s** to one sandbox over plain ssh, **~$BWN Mbit/s** total when uploading to $N at once.
Data: one ${BIG} MB file + ${NSMALL} × ${SKB} KB files (${SMALL_MB} MB). "Cold" = first read through conduit.

| scenario | conduit | plain ssh copy (baseline) |
|---|---|---|
| \`conduit up\` on $N sandboxes in parallel (incl. helper install) | ${SETUP}s | — |
| 1 sandbox: read ${BIG} MB file, cold | ${C_BIG}s (~${C_TPUT} Mbit/s) | ${RAW1}s (\`cat \| ssh\`) |
| 1 sandbox: read ${BIG} MB file, warm (page cache) | ${W_BIG}s | — |
| 1 sandbox: \`ls -lR\` of ${NSMALL} files | ${C_LS}s | — |
| 1 sandbox: read ${NSMALL} small files, cold | ${C_SMALL}s | ${RAWSMALL}s (\`tar \| ssh tar\`) |
| $N sandboxes at once: read ${BIG} MB file each (wall) | ${M_BIG}s (~${M_TPUT} Mbit/s total) | ${RAWN}s |
| ↳ per sandbox, median / slowest | ${M_BIG_PER}s | — |
| $N sandboxes at once: read ${NSMALL} small files each (wall) | ${M_SMALL}s | — |
| ↳ per sandbox, median / slowest | ${M_SMALL_PER}s | — |
EOF
