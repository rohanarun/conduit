#!/usr/bin/env bash
# Provision / tear down Daytona sandboxes for bench.sh.
#   DAYTONA_API_KEY=... bench/daytona.sh create 10 > targets.txt   # prints ssh targets
#   DAYTONA_API_KEY=... bench/daytona.sh targets                   # ssh targets for existing ones
#   DAYTONA_API_KEY=... bench/daytona.sh delete                    # deletes label purpose=conduit-bench
set -euo pipefail
: "${DAYTONA_API_KEY:?set DAYTONA_API_KEY}"
API=${DAYTONA_API_URL:-https://app.daytona.io/api}
H=(-H "Authorization: Bearer $DAYTONA_API_KEY" -H 'Content-Type: application/json')
case "${1:-}" in
  create)
    n=${2:-10}
    for i in $(seq 1 "$n"); do
      curl -fsS -m 120 -o /dev/null -X POST "${H[@]}" "$API/sandbox" \
        -d "{\"name\":\"conduit-bench-$i-$RANDOM\",\"labels\":{\"purpose\":\"conduit-bench\"},\"autoStopInterval\":30,\"autoDeleteInterval\":60}" &
    done
    wait; sleep 5
    exec "$0" targets ;;
  targets)
    curl -fsS "${H[@]}" "$API/sandbox?labels=%7B%22purpose%22%3A%22conduit-bench%22%7D" \
      | python3 -c 'import json,sys
d=json.load(sys.stdin); d=d.get("items",d)
for s in d:
  if s.get("labels",{}).get("purpose")=="conduit-bench": print(s["id"])' |
    while read -r id; do
      for _ in $(seq 60); do
        st=$(curl -fsS "${H[@]}" "$API/sandbox/$id" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])')
        [ "$st" = started ] && break; sleep 2
      done
      curl -fsS -X POST "${H[@]}" "$API/sandbox/$id/ssh-access?expiresInMinutes=180" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["sshCommand"].split()[-1])'
    done ;;
  delete)
    curl -fsS "${H[@]}" "$API/sandbox?labels=%7B%22purpose%22%3A%22conduit-bench%22%7D" \
      | python3 -c 'import json,sys
d=json.load(sys.stdin); d=d.get("items",d)
for s in d:
  if s.get("labels",{}).get("purpose")=="conduit-bench": print(s["id"])' |
    while read -r id; do curl -fsS -o /dev/null -X DELETE "${H[@]}" "$API/sandbox/$id" && echo "deleted $id"; done ;;
  *) echo "usage: $0 create N | targets | delete" >&2; exit 1 ;;
esac
