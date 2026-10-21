#!/usr/bin/python3
"""Upload a validated release asset pair, with bounded best-effort rollback."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import uuid
import urllib.request

REPOSITORY = 'Harflow-Dev/HarflowMac'
API = 'https://api.github.com/repos/' + REPOSITORY


def upload_release_assets(directory, version, release_id, token, request=None):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version) or type(release_id) is not int or release_id <= 0:
        raise ValueError('invalid release identity')
    directory = Path(directory)
    name = 'Harflow-' + version + '-arm64.zip'
    names = [name, name + '.sha256']
    if sorted(p.name for p in directory.iterdir()) != sorted(names):
        raise ValueError('expected exact asset pair')
    payloads = {item: (directory / item).read_bytes() for item in names}
    digest = hashlib.sha256(payloads[name]).hexdigest()
    if payloads[names[1]] != (digest + '  ' + name + '\n').encode():
        raise ValueError('asset checksum mismatch')
    def default_request(method, url, data=None, content_type='application/json'):
        headers = {'Accept': 'application/vnd.github+json', 'Authorization': 'Bearer ' + token,
                   'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': content_type}
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=120) as response:
            body = response.read()
            return json.loads(body) if body else None
    request = request or default_request
    release_url = API + '/releases/' + str(release_id)
    release = request('GET', release_url)
    if release['tag_name'] != 'v' + version or release.get('draft'):
        raise ValueError('release tag mismatch')
    # List rather than trusting the first embedded page of assets.
    assets_url = release_url + '/assets?per_page=100'
    existing = request('GET', assets_url)
    if len(existing) >= 100 or any(asset['name'] in names for asset in existing):
        raise ValueError('preexisting release assets; owner recovery required')
    original_ids = {asset['id'] for asset in existing}
    uploaded = []
    invocation = 'harflow-' + uuid.uuid4().hex
    try:
        for item in names:
            url = 'https://uploads.github.com/repos/' + REPOSITORY + '/releases/' + str(release_id) + '/assets?name=' + item + '&label=' + invocation
            asset = request('POST', url, payloads[item], 'application/zip' if item == name else 'text/plain')
            uploaded.append(asset['id'])
        current = request('GET', assets_url)
        for item in names:
            matches = [asset for asset in current if asset['name'] == item and asset['id'] in uploaded]
            if len(matches) != 1 or matches[0].get('state') != 'uploaded' or matches[0]['size'] != len(payloads[item]) or matches[0].get('digest') != 'sha256:' + hashlib.sha256(payloads[item]).hexdigest():
                raise ValueError('remote asset verification failed')
        # Invocation labels support ownership recovery while uploads are pending.
        # Clear them before completion because GitHub renders labels publicly.
        for asset_id in uploaded:
            request('PATCH', API + '/releases/assets/' + str(asset_id), json.dumps({'label': ''}).encode())
        current = request('GET', assets_url)
        for item in names:
            matches = [asset for asset in current if asset['name'] == item and asset['id'] in uploaded]
            if len(matches) != 1 or matches[0].get('state') != 'uploaded' or matches[0]['size'] != len(payloads[item]) or matches[0].get('digest') != 'sha256:' + hashlib.sha256(payloads[item]).hexdigest() or matches[0].get('label') not in (None, ''):
                raise ValueError('final public asset verification failed')
    except Exception:
        cleanup_failed = False
        candidates = set(uploaded)
        try:
            # A lost upload response can hide an ID. Discover only this invocation's labels.
            current = request('GET', assets_url)
            candidates.update(asset['id'] for asset in current if asset['name'] in names and asset['id'] not in original_ids and asset.get('label') == invocation)
        except Exception:
            cleanup_failed = True
        # Known uploaded IDs remain owned even if discovery fails or labels were cleared.
        for asset_id in candidates:
            try: request('DELETE', API + '/releases/assets/' + str(asset_id))
            except Exception: cleanup_failed = True
        if cleanup_failed:
            print('release assets partial upload: owner recovery required', flush=True)
        raise ValueError('asset pair upload failed') from None
    print('release assets verified', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path('release-dist'))
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    try:
        if os.environ.get('GITHUB_EVENT_NAME') != 'release' or os.environ.get('GITHUB_REPOSITORY') != REPOSITORY:
            raise ValueError()
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        if event['action'] != 'published' or event['release']['tag_name'] != 'v' + args.version:
            raise ValueError()
        upload_release_assets(args.directory, args.version, event['release']['id'], os.environ['GH_TOKEN'])
        return 0
    except Exception:
        print('release asset-upload failed', flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
