# conduit

**Relay your laptop's files, read-only, into all your cloud VMs and sandboxes. One command.**

```bash
npx conduit-fs up me@my-vm
```

Your folder appears on the VM **at the same path** (`/Users/you/...`), live: edits on
your laptop show up in the sandbox right away. The sandbox can never change your
laptop's files. Optionally it can write in the same folders on its own copy, and
optionally the *new* files it creates can be copied back.

## Install

```bash
npx conduit-fs up me@my-vm             # no install (needs Node)
npm i -g conduit-fs                    # or install the `conduit` command globally
curl -fsSL https://raw.githubusercontent.com/rohanarun/conduit/main/install.sh | sh   # no Node
```

It's a single bash script with no dependencies on your Mac. Copy `conduit` anywhere
on your `PATH` and that works too.

## Usage

```bash
conduit up me@my-vm                         # share ~ read-only (Ctrl-C to stop)
conduit up me@my-vm --path ~/code           # share just one folder (recommended)
conduit up me@my-vm --writable              # sandbox may write; changes stay on the sandbox
conduit up me@my-vm --write-back-new        # …and files it *creates* are copied back
conduit up --exec 'docker exec -i box'      # any transport that pipes stdin/stdout
conduit up --exec 'kubectl exec -i pod --'

conduit diff me@my-vm                       # A/M/D list of the sandbox's changes
conduit pull me@my-vm                       # copy them into ./conduit-pull for review
conduit status me@my-vm
conduit down me@my-vm
```

| mode | sandbox can… | laptop files |
|---|---|---|
| default | read | never modified |
| `--writable` | read, create, edit, delete (copy-on-write, kept on the sandbox) | never modified |
| `--write-back-new` | same as `--writable` | files the sandbox **creates** are copied back; existing files are never overwritten or deleted |

## Cookies (sign a sandbox browser in as you)

Export **your own** login cookies for **named sites** so a browser or agent on the
sandbox is signed in as you:

```bash
conduit cookies me@my-vm --domain github.com --domain news.ycombinator.com
conduit cookies me@my-vm --domain app.example.com --browser firefox
```

It decrypts the cookies on your Mac (macOS prompts for Keychain access on
Chrome-family browsers), filters to the sites you named, and copies two files to
`~/.conduit/cookies` on the sandbox:

- `storage_state.json` — load with Playwright/Puppeteer `storageState`
- `cookies.txt` — Netscape format for `curl --cookie`, `yt-dlp`, etc.

Browsers: `chrome` (default), `chrome-beta`, `chrome-canary`, `brave`, `edge`, `arc`,
`opera`, `vivaldi`, `chromium`, and `firefox`. Chrome-family browsers need an AES
library (`pip install cryptography`, or `pycryptodome`); Firefox needs none. Chrome's
newer app-bound-encrypted cookies (v20+) can't be exported and are skipped with a note.
Safari isn't supported yet (its cookies are in Apple's binarycookies format behind
Full Disk Access).

### Borrow a residential IP (Tailscale)

Some sites (banks especially) pin a session to your usual IP and reject a cookie
used from a datacenter. Put the sandbox on your tailnet and route its traffic out
through your Mac or home network, so the site sees a residential IP:

```bash
conduit tailscale me@my-vm --authkey tskey-... --exit-node my-mac
```

Make an auth key at <https://login.tailscale.com/admin/settings/keys>, and advertise
your Mac/home as an exit node (`tailscale up --advertise-exit-node`, approved in the
admin console). The key is sent over your ssh connection, never on the command line.
Needs root on the sandbox; without `/dev/net/tun` it uses Tailscale userspace mode
and prints a local SOCKS5/HTTP proxy for apps to use. `--tailscale-down` stops it.

> IP is only one signal. This fixes the datacenter-IP flag, but a strict site may
> still fingerprint the *device* (TLS/JA3, User-Agent, fonts), so pair it with a
> browser on the sandbox whose User-Agent matches yours. Automating around a bank's
> device checks may violate its terms — your account, your call.

> **This is the one thing in conduit that sends secrets off your machine.** An
> exported cookie is a logged-in session, usually past 2FA — treat the file like a
> password. It is **opt-in and per-domain** (there's no "export everything"), asks
> for confirmation, and writes `600` files into a `700` dir. Export only what you
> need, delete it when done (`rm -rf ~/.conduit/cookies` on the sandbox), and
> expect sites that pin a session to a device or location to reject it from a cloud IP.

## How it works

```
 laptop (macOS: no FUSE, no kext)                 sandbox (Linux)
┌────────────────────────────────┐  your ssh  ┌──────────────────────────────────────────┐
│ /usr/libexec/sftp-server -R    │◀══════════▶│ sshfs -o passive  (read-only lower)       │
│ (ships with macOS; read-only)  │ one stream │ overlayfs: hide list + optional writes    │
└────────────────────────────────┘            │   → mounted at /Users/you/… (same path)   │
                                              └──────────────────────────────────────────┘
```

- **FUSE runs on the sandbox, not on your Mac.** That means no macFUSE, no kernel
  extension, and no Recovery-mode approval. Your Mac only runs the `sftp-server` binary
  that ships with macOS.
- **Reverse sshfs.** The laptop's `sftp-server` is piped through the ssh connection *you*
  open into `sshfs -o passive` on the sandbox. The sandbox gets no credentials or network
  path to your laptop, and no ports are opened. It works behind NAT.
- **Read-only is enforced by the laptop.** `sftp-server -R` refuses every write, so
  it doesn't depend on trusting the sandbox.
- **An overlay on top** (kernel overlayfs, falling back to fuse-overlayfs) hides
  credential folders and, with `--writable`, holds the sandbox's own changes.
- **Write-back is a pull, not a push.** With `--write-back-new` the laptop polls for
  files the sandbox created and copies them over itself. Safety rules: it never
  overwrites a file conduit didn't create, never deletes, skips dot-paths (`.git/hooks`,
  `.envrc`, `.ssh`, …), `~/Library`, and symlinks, and refuses anything that would land
  outside `--path`.
- **Auto-reconnect.** If the connection drops, `up` remounts. The sandbox's changes survive.
- The sandbox helper is POSIX `sh` and installs `sshfs` itself (apt/dnf/yum/apk/pacman/zypper).

## Requirements

- **Laptop:** macOS or Linux with OpenSSH.
- **Sandbox:** Linux with `/dev/fuse`, plus root or passwordless `sudo`. Docker needs
  `--device /dev/fuse --cap-add SYS_ADMIN`. gVisor-based sandboxes usually don't expose FUSE.

Tested on: macOS 27 laptop → Daytona sandbox (Debian 13, sysbox container, kernel 6.8).

## Caveats

- **`--path` is the security boundary.** `.ssh`, `.aws`, browser profiles, Mail and so on
  are hidden by default, but that's an overlay whiteout. Root on the sandbox can still
  read the raw mount. Share a project folder, not `~`, with sandboxes you don't trust.
- **macOS privacy (TCC).** To share `~/Desktop`, `~/Documents`, `~/Downloads` or iCloud
  Drive, give your terminal app Full Disk Access.
- **Latency.** Every uncached read is a round trip to your laptop. That's fine for source
  trees and slow for huge `node_modules` scans. See [Benchmarks](#benchmarks).
- **Live updates need kernel overlayfs.** conduit uses it whenever it can. In containers
  whose root filesystem is itself an overlay, the writable layer goes on a RAM-backed tmpfs
  (`CONDUIT_TMPFS_SIZE`, default 4g), which survives reconnects but not reboots. The
  unprivileged `fuse-overlayfs` fallback caches aggressively, so laptop edits may not show
  until you remount.
- **Sysbox-based sandboxes** (e.g. Daytona) can't unmount FUSE mounts at all. conduit
  works around this (fresh internal mount per connection), but each disconnect leaves a
  small stale internal mount until the sandbox restarts.
- **Keep your laptop awake and online:** `caffeinate -i conduit up …`.

## Benchmarks

_Coming soon: time to read N files at a given bandwidth across 10 sandboxes._

## Contributing

Issues and PRs are welcome. Useful areas:

- testing on more sandbox providers (E2B, Modal, Fly, Codespaces, plain EC2/GCE VMs)
- a Homebrew tap
- the ideas in [Roadmap](#roadmap)

Before sending a PR, run `bash -n conduit` and check the sandbox helper with `dash -n`.
The laptop side must stay compatible with macOS's bash 3.2, and the helper must stay POSIX `sh`.

### Roadmap

- `conduit up a b c …`: one laptop, many sandboxes in a single command
- a filtering SFTP server, so hidden paths are enforced on the laptop, not just hidden
- a local read cache / prefetch for big trees (e.g. `--prefetch '**/*.py'`)
- `conduit exec me@vm -- cmd`: mount, run, pull results, unmount
- integrations for E2B / Modal / Daytona SDKs (no ssh config needed)

## Contributors

- **Rohan Arun** ([@rohanarun](https://github.com/rohanarun)), creator

[![contributors](https://contrib.rocks/image?repo=rohanarun/conduit)](https://github.com/rohanarun/conduit/graphs/contributors)

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE).
