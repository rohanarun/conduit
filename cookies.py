#!/usr/bin/env python3
"""conduit cookies — export YOUR OWN browser cookies for specific sites, so a
browser or agent on a cloud sandbox can be signed in as you.

This decrypts cookies on your machine (macOS asks for Keychain permission for
Chrome-family browsers) and writes two files:
  - storage_state.json   (Playwright / Puppeteer `storageState`)
  - cookies.txt          (Netscape format: curl --cookie, yt-dlp, etc.)

It NEVER dumps everything: you must name each domain with --domain. Driven by
the `conduit cookies` subcommand, which copies the result to the sandbox.

SECURITY: an exported cookie is as good as your logged-in session for that site
(often past 2FA). Anyone with access to the sandbox can use it. Export only the
sites you need, delete the file when done, and expect sites that pin a session
to a device or location (Google, banks) to reject it from a cloud IP.
"""
import argparse, base64, binascii, glob, http.cookiejar, json, os, sqlite3, struct, subprocess, sys, tempfile, time

def eprint(*a): print(*a, file=sys.stderr)

def aes_cbc_decrypt(key, iv, data):
    """AES-CBC decrypt via whatever's installed: cryptography, then pycryptodome."""
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        d = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
        return d.update(data) + d.finalize()
    except ImportError:
        pass
    try:
        from Crypto.Cipher import AES  # pycryptodome
        return AES.new(key, AES.MODE_CBC, iv).decrypt(data)
    except ImportError:
        raise SystemExit(
            "Chrome-family cookies are encrypted and need an AES library.\n"
            "  install one:   pip install cryptography    (or: pip install pycryptodome)\n"
            "  or use Firefox, which needs no library:   conduit cookies ... --browser firefox")

def domain_matches(host, wanted):
    host = host.lstrip('.')
    for w in wanted:
        w = w.lstrip('.')
        if host == w or host.endswith('.' + w):
            return True
    return False

# ----------------------------------------------------------------- Chrome (macOS)
def chrome_key(keychain_service):
    account = keychain_service.replace(' Safe Storage', '')  # e.g. "Microsoft Edge"
    try:
        pw = subprocess.check_output(
            ['security', 'find-generic-password', '-w', '-s', keychain_service, '-a', account],
            stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        # some builds store the item without the -a account; try service-only
        try:
            pw = subprocess.check_output(
                ['security', 'find-generic-password', '-w', '-s', keychain_service],
                stderr=subprocess.DEVNULL).strip()
        except subprocess.CalledProcessError:
            raise SystemExit(f"couldn't read the '{keychain_service}' key from your Keychain "
                             "(cancelled, or this browser isn't installed)")
    from hashlib import pbkdf2_hmac
    return pbkdf2_hmac('sha1', pw, b'saltysalt', 1003, 16)

def chrome_decrypt(enc, key):
    if not enc:
        return ''
    version, enc = enc[:3], enc[3:]
    if version not in (b'v10', b'v11'):
        # v20+ = app-bound encryption; not supported here
        raise ValueError('unsupported')
    dec = aes_cbc_decrypt(key, b' ' * 16, enc)
    dec = dec[:-dec[-1]]               # strip PKCS7 padding
    if len(dec) >= 32:                 # newer Chrome prefixes a 32-byte SHA256 of the domain
        try:
            return dec[32:].decode('utf-8')
        except UnicodeDecodeError:
            pass
    return dec.decode('utf-8', 'replace')

CHROME_PATHS = {
    'chrome':   '~/Library/Application Support/Google/Chrome',
    'chrome-beta':   '~/Library/Application Support/Google/Chrome Beta',
    'chrome-canary': '~/Library/Application Support/Google/Chrome Canary',
    'brave':    '~/Library/Application Support/BraveSoftware/Brave-Browser',
    'edge':     '~/Library/Application Support/Microsoft Edge',
    'arc':      '~/Library/Application Support/Arc/User Data',
    'opera':    '~/Library/Application Support/com.operasoftware.Opera',
    'vivaldi':  '~/Library/Application Support/Vivaldi',
    'chromium': '~/Library/Application Support/Chromium',
}
CHROME_KEYCHAIN = {'chrome': 'Chrome Safe Storage', 'chrome-beta': 'Chrome Safe Storage',
                   'chrome-canary': 'Chrome Safe Storage', 'brave': 'Brave Safe Storage',
                   'edge': 'Microsoft Edge Safe Storage', 'arc': 'Arc Safe Storage',
                   'opera': 'Opera Safe Storage', 'vivaldi': 'Vivaldi Safe Storage',
                   'chromium': 'Chromium Safe Storage'}

def read_chrome(browser, domains):
    base = os.path.expanduser(CHROME_PATHS[browser])
    dbs = glob.glob(os.path.join(base, '*', 'Cookies')) + glob.glob(os.path.join(base, '*', 'Network', 'Cookies'))
    if not dbs:
        raise SystemExit(f"no {browser} cookie database under {base}")
    key = chrome_key(CHROME_KEYCHAIN[browser])
    out, skipped = [], 0
    for db in dbs:
        tmp = tempfile.mktemp(suffix='.sqlite')
        with open(db, 'rb') as a, open(tmp, 'wb') as b:   # copy: the live DB is locked
            b.write(a.read())
        try:
            con = sqlite3.connect(tmp); con.row_factory = sqlite3.Row
            for r in con.execute("SELECT host_key,name,encrypted_value,path,expires_utc,is_secure,is_httponly FROM cookies"):
                if not domain_matches(r['host_key'], domains):
                    continue
                try:
                    val = chrome_decrypt(r['encrypted_value'], key)
                except ValueError:
                    skipped += 1; continue
                # Chrome epoch: microseconds since 1601-01-01
                exp = int(r['expires_utc'] / 1_000_000 - 11644473600) if r['expires_utc'] else 0
                out.append(dict(domain=r['host_key'], name=r['name'], value=val, path=r['path'],
                                expires=exp, secure=bool(r['is_secure']), httpOnly=bool(r['is_httponly'])))
            con.close()
        finally:
            os.unlink(tmp)
    if skipped:
        eprint(f"note: skipped {skipped} app-bound-encrypted cookie(s) (Chrome v20+); "
               "those can't be exported this way")
    return out

# ----------------------------------------------------------------- Firefox
def read_firefox(domains):
    base = os.path.expanduser('~/Library/Application Support/Firefox/Profiles')
    dbs = glob.glob(os.path.join(base, '*', 'cookies.sqlite'))
    if not dbs:
        raise SystemExit(f"no Firefox cookie database under {base}")
    out = []
    for db in dbs:
        tmp = tempfile.mktemp(suffix='.sqlite')
        with open(db, 'rb') as a, open(tmp, 'wb') as b:
            b.write(a.read())
        try:
            con = sqlite3.connect(tmp); con.row_factory = sqlite3.Row
            for r in con.execute("SELECT host,name,value,path,expiry,isSecure,isHttpOnly FROM moz_cookies"):
                if not domain_matches(r['host'], domains):
                    continue
                out.append(dict(domain=r['host'], name=r['name'], value=r['value'], path=r['path'],
                                expires=int(r['expiry']) if r['expiry'] else 0,
                                secure=bool(r['isSecure']), httpOnly=bool(r['isHttpOnly'])))
            con.close()
        finally:
            os.unlink(tmp)
    return out

# ----------------------------------------------------------------- output
def write_storage_state(cookies, path):
    pc = [dict(name=c['name'], value=c['value'], domain=c['domain'], path=c['path'],
               expires=c['expires'] or -1, httpOnly=c['httpOnly'], secure=c['secure'],
               sameSite='Lax') for c in cookies]
    with open(path, 'w') as f:
        json.dump({'cookies': pc, 'origins': []}, f, indent=2)

def write_netscape(cookies, path):
    with open(path, 'w') as f:
        f.write("# Netscape HTTP Cookie File\n# exported by conduit cookies\n")
        for c in cookies:
            dom = c['domain'] if c['domain'].startswith('.') else c['domain']
            flag = 'TRUE' if dom.startswith('.') else 'FALSE'
            f.write('\t'.join([dom, flag, c['path'], 'TRUE' if c['secure'] else 'FALSE',
                               str(c['expires']), c['name'], c['value']]) + '\n')

def main():
    ap = argparse.ArgumentParser(prog='conduit cookies', description=__doc__.split('\n')[0])
    ap.add_argument('--domain', action='append', required=True, metavar='HOST',
                    help='site to export (repeatable), e.g. --domain github.com')
    ap.add_argument('--browser', default='chrome', choices=list(CHROME_PATHS) + ['firefox'])
    ap.add_argument('--out-dir', default='.', help='where to write the two files')
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args()

    if a.browser == 'firefox':
        cookies = read_firefox(a.domain)
    else:
        cookies = read_chrome(a.browser, a.domain)
    if not cookies:
        raise SystemExit(f"no cookies found for {', '.join(a.domain)} in {a.browser}")

    os.makedirs(a.out_dir, exist_ok=True)
    js = os.path.join(a.out_dir, 'storage_state.json')
    ns = os.path.join(a.out_dir, 'cookies.txt')
    write_storage_state(cookies, js); write_netscape(cookies, ns)
    os.chmod(js, 0o600); os.chmod(ns, 0o600)
    if not a.quiet:
        hosts = sorted({c['domain'] for c in cookies})
        eprint(f"exported {len(cookies)} cookie(s) for {len(hosts)} host(s): {', '.join(hosts)}")
    print(js); print(ns)   # stdout: the paths, for the bash caller

if __name__ == '__main__':
    main()
