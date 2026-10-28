#!/usr/bin/python3
"""Validate, package and optionally sign the exact Harflow product bundle."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

# Explicit path import also works with /usr/bin/python3 -I.
_spec = importlib.util.spec_from_file_location('apple_preflight', Path(__file__).with_name('apple_signing_preflight.py'))
preflight = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(preflight)
Commands = preflight.Commands
ReleaseError = preflight.PreflightError
RUNTIME_PATH = Path('macos/HfCore/MonitorCore/Sources/MonitorCore/Resources/ManagedRuntime.json')
PLIST_PATH = Path('macos/Harflow/Resources/Info.plist')
PACKAGED_RUNTIME_PATH = Path('Contents/Resources/MonitorCore_MonitorCore.bundle/ManagedRuntime.json')


def exact_version(value):
    if not isinstance(value, str) or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        raise ReleaseError()
    return value


def validate_runtime(path):
    data = json.loads(Path(path).read_text())
    engine = exact_version(data['engineVersion'])
    if type(data['schema']) is not int or data['schema'] != 1 or engine != '0.0.4' or data['pythonVersion'] != '3.13.16' or data['python']['version'] != data['pythonVersion'] or not data['dependencies']:
        raise ReleaseError()
    if not isinstance(data['provenance'], str) or not data['provenance'] or len({item['name'] for item in data['dependencies']}) != len(data['dependencies']) or len({item['filename'] for item in data['dependencies']}) != len(data['dependencies']):
        raise ReleaseError()
    for index, artifact in enumerate([data['python']] + data['dependencies']):
        url = urllib.parse.urlsplit(artifact['url'])
        if url.scheme != 'https' or not url.hostname or url.username or url.password or not re.fullmatch('[a-f0-9]{64}', artifact['sha256']) or type(artifact['size']) is not int or not 0 < artifact['size'] <= 64 << 20 or Path(artifact['filename']).name != artifact['filename'] or '\n' in artifact['filename'] or not artifact['name'] or not artifact['version']:
            raise ReleaseError()
        if index and (url.hostname != 'files.pythonhosted.org' or not artifact['filename'].endswith('.whl') or Path(url.path).name != artifact['filename'] or not re.fullmatch('[A-Za-z0-9_.-]+', artifact['name']) or not re.fullmatch('[A-Za-z0-9.+]+', artifact['version'])):
            raise ReleaseError()
    return engine


def validate_plist(path):
    with Path(path).open('rb') as handle:
        info = plistlib.load(handle)
    version = exact_version(info['CFBundleShortVersionString'])
    if info['CFBundleIdentifier'] != 'dev.harflow.mac' or info['CFBundleVersion'] != '1' or info['CFBundleExecutable'] != 'Harflow' or info['LSMinimumSystemVersion'] != '26.0':
        raise ReleaseError()
    return version


def validate_source(root, tag=None, sha=None):
    root = Path(root)
    version = validate_plist(root / PLIST_PATH)
    engine = validate_runtime(root / RUNTIME_PATH)
    if tag is not None:
        if tag != 'v' + version or not sha or not re.fullmatch('[0-9a-f]{40}', sha):
            raise ReleaseError()
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        tagged = subprocess.check_output(['git', 'rev-parse', 'refs/tags/' + tag + '^{commit}'], cwd=root, text=True).strip()
        if head != sha or tagged != sha:
            raise ReleaseError()
    return version, engine


def code_paths(app):
    """Inventory known bundle code by Mach-O magic, rejecting unexpected code placement."""
    app = Path(app)
    result = []
    for path in app.rglob('*'):
        if path.is_symlink():
            if not path.resolve().is_relative_to(app.resolve()):
                raise ReleaseError()
            continue
        if path.is_file():
            with path.open('rb') as handle:
                magic = handle.read(4)
            if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
                if path != app / 'Contents/MacOS/Harflow':
                    # The current product embeds resource-only SwiftPM bundles.
                    raise ReleaseError()
                result.append(path)
    if result != [app / 'Contents/MacOS/Harflow']:
        raise ReleaseError()
    return result


def verify_signature(path, commands, signed=False, team=None):
    commands.run([preflight.CODESIGN, '--verify', '--strict', '--verbose=2', str(path)])
    details = commands.run([preflight.CODESIGN, '--display', '--verbose=4', str(path)], include_stderr=True)
    if signed:
        if not re.search(r'^Authority=Developer ID Application: ', details, re.M) or not re.search(r'^TeamIdentifier=' + re.escape(team or '') + r'$', details, re.M) or not re.search(r'flags=.*\bruntime\b', details) or not re.search(r'^Timestamp=', details, re.M):
            raise ReleaseError()
    elif not re.search(r'^Signature=adhoc$', details, re.M):
        raise ReleaseError()


def validate_packaged_startup(app, version, engine, process=None):
    """Check resource startup before any app or managed-runtime initialization."""
    executable = (Path(app) / 'Contents/MacOS/Harflow').resolve()
    process = process or subprocess.run
    try:
        with tempfile.TemporaryDirectory(prefix='harflow-startup-') as temporary:
            scratch = Path(temporary)
            home, tmp = scratch / 'home', scratch / 'tmp'
            home.mkdir(mode=0o700)
            tmp.mkdir(mode=0o700)
            result = process(
                [str(executable), '--check-packaged-startup'],
                cwd=scratch,
                env={'HOME': str(home), 'TMPDIR': str(tmp), 'PATH': '/usr/bin:/bin'},
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=10, check=False,
            )
        if result.returncode != 0 or not isinstance(result.stdout, bytes) or len(result.stdout) > 4096 or result.stderr:
            raise ReleaseError()
        # Reject duplicate keys as well as additional/missing fields or trailing output.
        def unique_object(pairs):
            value = {}
            for key, item in pairs:
                if key in value:
                    raise ReleaseError()
                value[key] = item
            return value
        payload = json.loads(result.stdout, object_pairs_hook=unique_object)
        if payload != {'appVersion': version, 'engineVersion': engine, 'status': 'ok'}:
            raise ReleaseError()
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        raise ReleaseError() from None


def validate_bundle(app, root, commands=None, signed=False, team=None, startup_process=None):
    commands = commands or Commands(os.environ)
    app, root = Path(app), Path(root)
    version, engine = validate_source(root)
    if app.name != 'Harflow.app' or validate_plist(app / 'Contents/Info.plist') != version:
        raise ReleaseError()
    resources = app / 'Contents/Resources'
    for name in ('AppIcon.icns', 'menubarTemplate.png', 'menubarTemplate@2x.png'):
        if not (resources / name).is_file():
            raise ReleaseError()
    specification = app / PACKAGED_RUNTIME_PATH
    specs = list(app.rglob('ManagedRuntime.json'))
    if specs != [specification] or not specification.is_file() or specification.read_bytes() != (root / RUNTIME_PATH).read_bytes() or validate_runtime(specification) != engine:
        raise ReleaseError()
    for code in code_paths(app):
        archs = commands.run(['/usr/bin/lipo', '-archs', str(code)]).strip().split()
        if archs != ['arm64']:
            raise ReleaseError()
        verify_signature(code, commands, signed, team)
    verify_signature(app, commands, signed, team)
    validate_packaged_startup(app, version, engine, startup_process)
    return version, engine


def validate_pypi_metadata(data, version):
    exact_version(version)
    name = 'harflow_mcp-' + version + '-py3-none-any.whl'
    if data['info']['name'] != 'harflow-mcp' or data['info']['version'] != version:
        raise ReleaseError()
    wheels = [item for item in data['urls'] if item['filename'] == name and item['packagetype'] == 'bdist_wheel']
    if len(wheels) != 1:
        raise ReleaseError()
    wheel = wheels[0]
    url = urllib.parse.urlsplit(wheel['url'])
    if url.scheme != 'https' or url.netloc != 'files.pythonhosted.org' or not url.path.endswith('/' + name) or url.query or url.fragment or type(wheel['size']) is not int or not 0 < wheel['size'] <= 64 << 20 or not re.fullmatch('[a-f0-9]{64}', wheel['digests']['sha256']):
        raise ReleaseError()
    return wheel


def wait_for_pypi(version, fetch=None, sleep=time.sleep, attempts=12):
    exact_version(version)
    def default_fetch():
        with urllib.request.urlopen('https://pypi.org/pypi/harflow-mcp/' + version + '/json', timeout=30) as response:
            return json.load(response)
    for attempt in range(attempts):
        try:
            return validate_pypi_metadata((fetch or default_fetch)(), version)
        except (ReleaseError, ValueError, KeyError, TypeError, OSError):
            if attempt + 1 == attempts:
                raise ReleaseError() from None
            sleep(10)


def validate_signing_runner(env):
    # Reuse preflight input/host checks without changing its main-only guard.
    ref = env.get('GITHUB_REF', '')
    if ref != 'refs/heads/main' and not re.fullmatch(r'refs/tags/v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', ref):
        raise ReleaseError()
    if env.get('GITHUB_EVENT_NAME') not in ('release', 'workflow_dispatch'):
        raise ReleaseError()
    normalized = dict(env, GITHUB_REF='refs/heads/main')
    return preflight.validate_runner(normalized)


def create_zip(app, destination, commands):
    if Path(destination).exists():
        raise ReleaseError()
    commands.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(destination)])


def verify_zip(archive, root, commands, signed=False, team=None):
    with tempfile.TemporaryDirectory(prefix='harflow-extract-') as temporary:
        commands.run(['/usr/bin/ditto', '-x', '-k', str(archive), temporary])
        validate_bundle(Path(temporary) / 'Harflow.app', root, commands, signed, team)
        if signed:
            assess(Path(temporary) / 'Harflow.app', commands)


def assess(app, commands):
    commands.run([preflight.XCRUN, 'stapler', 'validate', str(app)])
    commands.run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)])


def sign_product(app, root, output, env=None, commands=None):
    """Emit final assets only after signing, accepted notarization and successful cleanup."""
    env = dict(os.environ if env is None else env)
    commands = commands or Commands(env)
    scratch = keychain = snapshot = None
    created = False
    failed = False
    stage = 'runner-validation'
    final_zip = final_sum = None
    try:
        temporary_root = validate_signing_runner(env)
        version, _ = validate_bundle(app, root, commands)
        output = Path(output)
        if output.exists() and any(output.iterdir()):
            raise ReleaseError()
        data = preflight.decode_p12(env['HARFLOW_DEVELOPER_ID_P12_BASE64'])
        scratch = Path(tempfile.mkdtemp(prefix='harflow-product-', dir=str(temporary_root)))
        scratch.chmod(0o700)
        product = scratch / 'Harflow.app'
        commands.run(['/usr/bin/ditto', str(app), str(product)])
        keychain = scratch / 'ephemeral.keychain-db'
        p12 = scratch / 'identity.p12'
        with os.fdopen(os.open(str(p12), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as handle:
            handle.write(data)
        del data
        password = secrets.token_urlsafe(32)
        stage = 'keychain-preparation'
        snapshot = shlex.split(commands.run([preflight.SECURITY, 'list-keychains', '-d', 'user']))
        if any(not Path(path).is_absolute() for path in snapshot):
            snapshot = None
            raise ReleaseError()
        commands.run([preflight.SECURITY, 'create-keychain', '-p', password, str(keychain)])
        created = True
        commands.run([preflight.SECURITY, 'unlock-keychain', '-p', password, str(keychain)])
        commands.run([preflight.SECURITY, 'set-keychain-settings', '-lut', '1200', str(keychain)])
        commands.run([preflight.SECURITY, 'list-keychains', '-d', 'user', '-s', str(keychain)] + snapshot)
        stage = 'identity-import'
        try:
            commands.run([preflight.SECURITY, 'import', str(p12), '-k', str(keychain), '-P', env['HARFLOW_DEVELOPER_ID_P12_PASSWORD'], '-T', preflight.CODESIGN])
        finally:
            p12.unlink(missing_ok=True)
        commands.run([preflight.SECURITY, 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, str(keychain)])
        identity = preflight.signing_identity(commands.run([preflight.SECURITY, 'find-identity', '-v', '-p', 'codesigning', str(keychain)]), env['HARFLOW_APPLE_TEAM_ID'])
        stage = 'product-signing'
        # The executable is signed before its enclosing app; resource bundles contain no code.
        for path in code_paths(product) + [product]:
            commands.run([preflight.CODESIGN, '--force', '--sign', identity, '--keychain', str(keychain), '--timestamp', '--options', 'runtime', str(path)])
        validate_bundle(product, root, commands, True, env['HARFLOW_APPLE_TEAM_ID'])
        profile = 'harflow-product-' + secrets.token_hex(16)
        stage = 'notary-credentials'
        commands.run([preflight.XCRUN, 'notarytool', 'store-credentials', profile, '--apple-id', env['HARFLOW_NOTARY_APPLE_ID'], '--password', env['HARFLOW_NOTARY_APP_PASSWORD'], '--team-id', env['HARFLOW_APPLE_TEAM_ID'], '--keychain', str(keychain), '--validate'])
        archive = scratch / 'notary.zip'
        create_zip(product, archive, commands)
        stage = 'notary-submit'
        response = commands.run([preflight.XCRUN, 'notarytool', 'submit', str(archive), '--keychain-profile', profile, '--keychain', str(keychain), '--wait', '--timeout', '20m', '--output-format', 'json'], timeout=1260)
        stage = 'notary-response'
        try:
            accepted = json.loads(response)
        except (ValueError, TypeError):
            raise ReleaseError() from None
        if not isinstance(accepted, dict) or accepted.get('status') != 'Accepted' or not isinstance(accepted.get('id'), str) or not accepted['id']:
            raise ReleaseError()
        stage = 'staple-assessment'
        commands.run([preflight.XCRUN, 'stapler', 'staple', str(product)])
        assess(product, commands)
        validate_bundle(product, root, commands, True, env['HARFLOW_APPLE_TEAM_ID'])
        stage = 'final-package'
        name = 'Harflow-' + version + '-arm64.zip'
        final_zip = scratch / name
        create_zip(product, final_zip, commands)
        verify_zip(final_zip, root, commands, True, env['HARFLOW_APPLE_TEAM_ID'])
        final_sum = scratch / (name + '.sha256')
        final_sum.write_text(hashlib.sha256(final_zip.read_bytes()).hexdigest() + '  ' + name + '\n')
        # Retain only the public pair outside private scratch until cleanup succeeds.
        output.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(final_zip, output / name)
        shutil.copyfile(final_sum, output / final_sum.name)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        failed = True
        category = preflight.notary_failure_category(error) if stage.startswith('notary-') else 'command-failed'
        print('release ' + stage + ' failed: ' + category, flush=True)
    except Exception:
        failed = True
        print('release ' + stage + ' failed', flush=True)
    finally:
        cleanup_failed = False
        if snapshot is not None:
            try: commands.run([preflight.SECURITY, 'list-keychains', '-d', 'user', '-s'] + snapshot)
            except Exception: cleanup_failed = True
        if keychain is not None and (created or keychain.exists()):
            try: commands.run([preflight.SECURITY, 'delete-keychain', str(keychain)])
            except Exception: cleanup_failed = True
        if scratch is not None:
            try: shutil.rmtree(scratch)
            except Exception: cleanup_failed = True
        if cleanup_failed:
            failed = True
            print('release cleanup failed', flush=True)
        if failed and final_zip is not None:
            for name in (final_zip.name, final_sum.name if final_sum else ''):
                if name:
                    try: (Path(output) / name).unlink(missing_ok=True)
                    except Exception: print('release asset-cleanup failed', flush=True)
    if not failed:
        print('release signed-package ok', flush=True)
    return 1 if failed else 0


def unsigned_package(app, root, output, commands=None):
    commands = commands or Commands(os.environ)
    version, _ = validate_bundle(app, root, commands)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    name = 'Harflow-' + version + '-unsigned-arm64.zip'
    owned = []
    try:
        with tempfile.TemporaryDirectory(prefix='.harflow-package-', dir=str(output)) as temporary:
            archive = Path(temporary) / name
            create_zip(app, archive, commands)
            verify_zip(archive, root, commands)
            checksum = Path(temporary) / (name + '.sha256')
            checksum.write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + name + '\n')
            for source in (archive, checksum):
                destination = output / source.name
                # Exclusive creation preserves preexisting files even if another
                # invocation publishes between validation and this operation.
                with destination.open('xb') as target:
                    identity = os.fstat(target.fileno())
                    owned.append((destination, identity.st_dev, identity.st_ino))
                    with source.open('rb') as handle:
                        shutil.copyfileobj(handle, target)
    except Exception:
        for destination, device, inode in owned:
            try:
                identity = destination.lstat()
                if (identity.st_dev, identity.st_ino) == (device, inode):
                    destination.unlink()
            except FileNotFoundError:
                pass
        raise
    print('release unsigned-package ok; PyPI availability and Gatekeeper validation skipped', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['source', 'bundle', 'unsigned', 'sign', 'pypi'])
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--app', type=Path, default=Path('macos/build/Harflow.app'))
    parser.add_argument('--output', type=Path, default=Path('release-dist'))
    parser.add_argument('--tag')
    parser.add_argument('--sha')
    args = parser.parse_args()
    try:
        version, engine = validate_source(args.root, args.tag, args.sha)
        if args.command == 'source': print(version)
        elif args.command == 'bundle': validate_bundle(args.app, args.root)
        elif args.command == 'pypi': wait_for_pypi(engine)
        elif args.command == 'unsigned': unsigned_package(args.app, args.root, args.output)
        elif args.command == 'sign':
            if os.environ.get('GITHUB_EVENT_NAME') == 'release':
                if args.tag is None or args.sha is None: raise ReleaseError()
                wait_for_pypi(engine)
            else: print('release manual validation: PyPI availability skipped', flush=True)
            return sign_product(args.app, args.root, args.output)
        return 0
    except Exception:
        print('release validation failed', flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
