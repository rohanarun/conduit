#!/usr/bin/env bash
# Safe on-camera proof that conduit delivered working cookies to a sandbox.
#   examples/cookie-proof.sh TARGET [--domain github.com]
#
# It exports your cookie to the sandbox, then prints a proof that is SAFE TO SHOW
# ON VIDEO: it proves you're authenticated (your public username) and shows the
# cookies are present but REDACTED (name, length, short hash only — never the
# value). It never cats the cookie file. The raw value is the credential; keep it
# off screen. Finally it deletes the cookie from the sandbox.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=${1:?usage: cookie-proof.sh TARGET [--domain HOST ...]}; shift
DOMS=("$@"); [ ${#DOMS[@]} -gt 0 ] || DOMS=(--domain github.com)

"$HERE/conduit" cookies "$T" "${DOMS[@]}" --yes

ssh -t "$T" 'python3 - <<"PY"
import hashlib, os, subprocess, json, re
d = os.path.expanduser("~/.conduit/cookies")
print("")
print("==================== CONDUIT COOKIE PROOF ====================")
print("sandbox:", os.uname().nodename)

# 1) authenticated? fetch github with the exported cookies, show only the username
try:
    out = subprocess.check_output(["curl","-s","--cookie",d+"/cookies.txt","https://github.com"], text=True)
    m = re.search(r"login.:.([A-Za-z0-9-]+)", out)
    print("1) Authenticated to github.com as:", m.group(1) if m else "(no session - a site may reject a cloud IP)")
except Exception as e:
    print("1) auth check skipped:", e)

# 2) cookies are really here, but values are redacted (safe to show on camera)
print("2) Cookies on this sandbox (VALUES REDACTED - safe to show on video):")
try:
    cj = json.load(open(d+"/storage_state.json"))["cookies"]
except Exception:
    cj = []
for c in cj:
    v = c.get("value","")
    h = hashlib.sha256(v.encode()).hexdigest()[:10]
    name = c.get("name","")[:28]
    print("   %-28s len=%-5d sha256:%s...  [value hidden]" % (name, len(v), h))
print("   -> the actual secret was never printed; only its length and hash.")
print("==============================================================")
print("")
PY
rm -rf ~/.conduit/cookies && echo "cookie deleted from the sandbox."'
