#!/usr/bin/env python3
"""Prepare/import a stable local CodeJump identity, or sign an app with that identity.
No system root store, TLS trust, or global keychain ACL is changed.
"""
import argparse, hashlib, json, os, pathlib, re, secrets, subprocess, tempfile

DIRECTORY = pathlib.Path.home() / 'Library/Application Support/CodeJump/Signing'
NAME = 'CodeJump Local Development'
IDENTIFIER = 'com.xiay8874.CodeJump'
CONFIG = DIRECTORY / 'identity.json'

def run(args, **kwargs):
    result = subprocess.run(args, **kwargs)
    if result.returncode: raise SystemExit(f'{pathlib.Path(args[0]).name} failed (exit {result.returncode}); command arguments withheld.')
    return result

def fingerprint(cert):
    data = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
    return hashlib.sha1(data).hexdigest().upper()

def prepare():
    DIRECTORY.mkdir(parents=True, exist_ok=True); DIRECTORY.chmod(0o700)
    cert = DIRECTORY / 'certificate.pem'
    key = DIRECTORY / 'private-key.pem'
    if CONFIG.exists():
        print('A persistent signing identity is already configured.'); return
    if cert.exists() or key.exists():
        if not (cert.exists() and key.exists()): raise SystemExit('Partial signing material exists; inspect before continuing.')
    else:
        run(['openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '3650',
             '-subj', '/CN=' + NAME, '-addext', 'basicConstraints=critical,CA:FALSE',
             '-addext', 'keyUsage=critical,digitalSignature', '-addext', 'extendedKeyUsage=critical,codeSigning',
             '-keyout', str(key), '-out', str(cert)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    key.chmod(0o600); cert.chmod(0o600)
    print(json.dumps({'prepared': str(cert), 'name': NAME, 'fingerprint': fingerprint(cert),
                      'keychainImported': False, 'trustSettingsChanged': False}, ensure_ascii=False))

def install():
    if CONFIG.exists(): raise SystemExit('Identity already configured; refusing to replace it.')
    cert = DIRECTORY / 'certificate.pem'; key = DIRECTORY / 'private-key.pem'
    if not cert.exists() or not key.exists(): raise SystemExit('Run --prepare first.')
    keychain = subprocess.check_output(['security', 'default-keychain', '-d', 'user'], text=True).strip().strip('"')
    # The PKCS12 has a random transport password and is deleted on every exit.
    # Never print command arguments: security import accepts its password only as an argument.
    with tempfile.TemporaryDirectory(prefix='import-', dir=DIRECTORY) as temporary:
        bundle = pathlib.Path(temporary) / 'identity.p12'
        password = secrets.token_urlsafe(32)
        environment = dict(os.environ, CODEJUMP_P12_PASS=password)
        run(['openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(cert),
             '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1',
             '-name', NAME, '-out', str(bundle), '-passout', 'env:CODEJUMP_P12_PASS'],
            env=environment, stdout=subprocess.DEVNULL)
        bundle.chmod(0o600)
        run(['security', 'import', str(bundle), '-k', keychain, '-f', 'pkcs12', '-P', password,
             '-x', '-T', '/usr/bin/codesign'])
    metadata = {'name': NAME, 'sha1': fingerprint(cert), 'keychain': keychain, 'identifier': IDENTIFIER}
    CONFIG.write_text(json.dumps(metadata, indent=2) + '\n'); CONFIG.chmod(0o600)
    # Only the non-extractable Keychain copy survives import.
    key.unlink()
    print('Imported the CodeJump identity into the user keychain; no trust settings changed.')

def sign(app, allow_adhoc):
    if not CONFIG.exists():
        if not allow_adhoc: raise SystemExit('No stable signing identity. Prepare/import it before replacing the installed app.')
        run(['codesign', '--force', '--sign', '-', '--identifier', IDENTIFIER, str(app)])
        return
    metadata = json.loads(CONFIG.read_text())
    sha = metadata['sha1']
    if not re.fullmatch('[0-9A-Fa-f]{40}', sha): raise SystemExit('Invalid certificate fingerprint.')
    # Pin both certificate and bundle identifier. The identity stays constant across code changes.
    requirement = f'=designated => identifier "{IDENTIFIER}" and certificate leaf = H"{sha}"'
    run(['codesign', '--force', '--sign', sha, '--keychain', metadata['keychain'], '--timestamp=none',
         '--identifier', IDENTIFIER, '--requirements', requirement, str(app)])
    run(['codesign', '--verify', '--strict', str(app)])

if __name__ == '__main__':
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare', action='store_true')
    group.add_argument('--install', action='store_true', help='Requires explicit approval to import the persistent keychain identity')
    group.add_argument('--sign', type=pathlib.Path)
    p.add_argument('--allow-adhoc', action='store_true', help='Only for disposable build-only artifacts')
    args = p.parse_args()
    if args.prepare: prepare()
    elif args.install: install()
    else: sign(args.sign, args.allow_adhoc)
