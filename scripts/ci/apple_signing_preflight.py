#!/usr/bin/python3
"""Validate Apple signing credentials on a protected disposable GitHub runner."""
import base64
import binascii
import json
import os
import platform
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

REQUIRED_MACOS_MAJOR = 26
MAX_ENCODED_P12_BYTES = 48 * 1024
MAX_DECODED_P12_BYTES = 36 * 1024
SECRET_NAMES = (
    'HARFLOW_DEVELOPER_ID_P12_BASE64',
    'HARFLOW_DEVELOPER_ID_P12_PASSWORD',
    'HARFLOW_NOTARY_APPLE_ID',
    'HARFLOW_NOTARY_APP_PASSWORD',
)
SECURITY = '/usr/bin/security'
CODESIGN = '/usr/bin/codesign'
XCRUN = '/usr/bin/xcrun'


class PreflightError(Exception):
    """A failure whose underlying details must remain private."""


class Commands:
    """Run only trusted tools; captured command details are never logged."""

    def __init__(self, env):
        self.env = {key: env[key] for key in ('HOME', 'TMPDIR', 'LANG') if key in env}
        self.env['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'

    def run(self, args, timeout=120, include_stderr=False):
        result = subprocess.run(args, env=self.env, capture_output=True, text=True,
                                check=True, timeout=timeout)
        return result.stdout + (result.stderr if include_stderr else '')


def validate_runner(env):
    expected = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
                'RUNNER_OS': 'macOS', 'RUNNER_ARCH': 'ARM64',
                'GITHUB_REPOSITORY': 'Harflow-Dev/HarflowMac',
                'GITHUB_REF': 'refs/heads/main'}
    if sys.version_info < (3, 9) or any(env.get(key) != value for key, value in expected.items()):
        raise PreflightError()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise PreflightError()
    if platform.mac_ver()[0].split('.')[0] != str(REQUIRED_MACOS_MAJOR):
        raise PreflightError()
    if any(not env.get(name) for name in SECRET_NAMES):
        raise PreflightError()
    if not re.fullmatch(r'[A-Z0-9]{10}', env.get('HARFLOW_APPLE_TEAM_ID', '')):
        raise PreflightError()
    root = Path(env.get('RUNNER_TEMP', ''))
    if not root.is_absolute() or root.is_symlink() or not root.is_dir() or root.resolve() != root:
        raise PreflightError()
    info = root.stat()
    if info.st_uid != os.getuid() or info.st_mode & stat.S_IWOTH:
        raise PreflightError()
    return root


def decode_p12(encoded):
    if len(encoded.encode('utf-8')) > MAX_ENCODED_P12_BYTES:
        raise PreflightError()
    compact = re.sub(r'[\t\n\r\f\v ]', '', encoded)
    try:
        data = base64.b64decode(compact, validate=True)
    except (ValueError, binascii.Error):
        raise PreflightError() from None
    if not data or len(data) > MAX_DECODED_P12_BYTES:
        raise PreflightError()
    return data


def signing_identity(output, team):
    identities = re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"\r\n]+)"\s*$', output, re.M)
    if len(identities) != 1:
        raise PreflightError()
    fingerprint, name = identities[0]
    if not name.startswith('Developer ID Application: ') or not name.endswith(' (' + team + ')'):
        raise PreflightError()
    return fingerprint


def preflight(env=None, commands=None):
    env = dict(os.environ if env is None else env)
    stage = 'runner-validation'
    scratch = None
    keychain = None
    snapshot = None
    keychain_created = False
    failed = False
    commands = commands or Commands(env)
    try:
        root = validate_runner(env)
        data = decode_p12(env['HARFLOW_DEVELOPER_ID_P12_BASE64'])
        print('preflight runner-validation ok', flush=True)
        stage = 'scratch-preparation'
        scratch = Path(tempfile.mkdtemp(prefix='harflow-signing-', dir=str(root)))
        scratch.chmod(0o700)
        keychain = scratch / 'ephemeral.keychain-db'
        p12 = scratch / 'identity.p12'
        with os.fdopen(os.open(str(p12), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as handle:
            handle.write(data)
        del data
        password = secrets.token_urlsafe(32)
        stage = 'keychain-preparation'
        # Restore whenever the snapshot exists, even if prepend fails partially.
        snapshot = shlex.split(commands.run([SECURITY, 'list-keychains', '-d', 'user']))
        if any(not Path(path).is_absolute() for path in snapshot):
            snapshot = None
            raise PreflightError()
        commands.run([SECURITY, 'create-keychain', '-p', password, str(keychain)])
        keychain_created = True
        commands.run([SECURITY, 'unlock-keychain', '-p', password, str(keychain)])
        commands.run([SECURITY, 'set-keychain-settings', '-lut', '1200', str(keychain)])
        commands.run([SECURITY, 'list-keychains', '-d', 'user', '-s', str(keychain)] + snapshot)
        stage = 'identity-import'
        try:
            commands.run([SECURITY, 'import', str(p12), '-k', str(keychain), '-P', env['HARFLOW_DEVELOPER_ID_P12_PASSWORD'], '-T', CODESIGN])
        finally:
            p12.unlink(missing_ok=True)
        commands.run([SECURITY, 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, str(keychain)])
        fingerprint = signing_identity(commands.run([SECURITY, 'find-identity', '-v', '-p', 'codesigning', str(keychain)]), env['HARFLOW_APPLE_TEAM_ID'])
        print('preflight identity-import ok', flush=True)
        stage = 'probe-signing'
        source = scratch / 'probe.c'
        probe = scratch / 'probe'
        source.write_text('int main(void) { return 0; }\n', encoding='ascii')
        commands.run([XCRUN, 'clang', str(source), '-o', str(probe)])
        commands.run([CODESIGN, '--force', '--sign', fingerprint, '--keychain', str(keychain), '--timestamp', '--options', 'runtime', str(probe)])
        commands.run([CODESIGN, '--verify', '--strict', '--verbose=2', str(probe)])
        # codesign displays signature details on stderr, captured privately below.
        details = commands.run([CODESIGN, '--display', '--verbose=4', str(probe)], include_stderr=True)
        if not re.search(r'^Authority=Developer ID Application: ', details, re.M):
            raise PreflightError()
        if not re.search(r'^TeamIdentifier=' + re.escape(env['HARFLOW_APPLE_TEAM_ID']) + r'$', details, re.M):
            raise PreflightError()
        print('preflight probe-signing ok', flush=True)
        stage = 'notary-authentication'
        profile = 'harflow-preflight-' + secrets.token_hex(16)
        commands.run([XCRUN, 'notarytool', 'store-credentials', profile, '--apple-id', env['HARFLOW_NOTARY_APPLE_ID'], '--password', env['HARFLOW_NOTARY_APP_PASSWORD'], '--team-id', env['HARFLOW_APPLE_TEAM_ID'], '--keychain', str(keychain), '--validate'])
        history = commands.run([XCRUN, 'notarytool', 'history', '--keychain-profile', profile, '--keychain', str(keychain), '--output-format', 'json'])
        with os.fdopen(os.open(str(scratch / 'history.json'), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as handle:
            handle.write(history)
        parsed = json.loads(history)
        if not isinstance(parsed, dict) or not isinstance(parsed.get('history'), list):
            raise PreflightError()
        print('preflight notary-authentication ok', flush=True)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        failed = True
        print('preflight ' + stage + ' failed', flush=True)
    except Exception:
        failed = True
        print('preflight ' + stage + ' failed', flush=True)
    finally:
        cleanup_failed = False
        if snapshot is not None:
            try:
                commands.run([SECURITY, 'list-keychains', '-d', 'user', '-s'] + snapshot)
            except Exception:
                cleanup_failed = True
                print('preflight search-list-restoration failed', flush=True)
        if keychain is not None and (keychain_created or keychain.exists()):
            try:
                commands.run([SECURITY, 'delete-keychain', str(keychain)])
            except Exception:
                cleanup_failed = True
        if scratch is not None:
            try:
                shutil.rmtree(scratch)
            except Exception:
                cleanup_failed = True
        if scratch is not None:
            print('preflight cleanup ' + ('failed' if cleanup_failed else 'ok'), flush=True)
        failed = failed or cleanup_failed
    return 1 if failed else 0


def sanitized_exception(_type, _value, _traceback):
    print('preflight internal failed', flush=True)


if __name__ == '__main__':
    sys.excepthook = sanitized_exception
    sys.exit(preflight())
