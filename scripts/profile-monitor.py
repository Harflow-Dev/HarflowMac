#!/usr/bin/env python3
"""Profile an isolated built Monitor without installation or production registration.

Requires a synthetic HOME created by benchmark-monitor.py, including its restricted
CLI wrappers. Copies the app to a private bundle with a unique identifier, removes
URL registration, and ad-hoc signs only that copy. HOME and argument-domain settings
isolate history, drafts, and defaults; no existing app is stopped. Samples RSS using
ps: the observed maximum is a lower bound, not a true resident-memory high-water
mark. Launch duration is observation time, not UI readiness. Monitor timing JSONL
on stderr measures internal boundaries, not displayed frames. --sample collects
stacks in a separate launch because sampling perturbs latency. No UI automation
or model calls are performed; interact with the isolated window for detail flows.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid


def observe(binary: Path, home: Path, output: Path, seconds: float, sample: bool) -> dict:
    env = {key: value for key, value in os.environ.items() if not key.startswith('PB_')}
    env.update(HOME=str(home), POLYBRIDGE_MONITOR_METRICS='1')
    command = [str(binary), '-toolDirectory', str(home / '.local/bin'),
               '-notifyOnFinish', 'NO', '-openWindowOnStart', 'YES']
    rows = []
    start = time.monotonic()
    started_monotonic_ns = time.monotonic_ns()
    with (output / 'stdout.log').open('wb') as stdout, (output / 'stderr.jsonl').open('wb') as stderr:
        process = subprocess.Popen(command, env=env, stdout=stdout, stderr=stderr)
        alive_at_end = False
        try:
            if sample:
                time.sleep(min(2.0, seconds / 2))
                if process.poll() is None:
                    with (output / 'sample-command.log').open('wb') as log:
                        capture = subprocess.run(['/usr/bin/sample', str(process.pid),
                                                  str(max(1, int(seconds))), '10', '-file',
                                                  str(output / 'stacks.txt')], stdout=log, stderr=log)
                    sample_exit = capture.returncode
                else:
                    sample_exit = None
            else:
                while process.poll() is None and time.monotonic() - start < seconds:
                    result = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(process.pid)],
                                            capture_output=True, text=True)
                    value = result.stdout.strip()
                    if result.returncode == 0 and value.isdigit():
                        rows.append({'elapsed_ms': (time.monotonic() - start) * 1000,
                                     'rss_bytes': int(value) * 1024})
                    time.sleep(.1)
            alive_at_end = process.poll() is None
            natural_exit = process.poll()
        finally:
            # Popen owns exactly this PID; never use pkill, bundle matching, or a process group.
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    result = {'pid': process.pid, 'started_monotonic_ns': started_monotonic_ns,
              'observation_ms': (time.monotonic() - start) * 1000,
              'alive_at_observation_end': alive_at_end, 'natural_exit_code': natural_exit,
              'observed_peak_rss_bytes': max((row['rss_bytes'] for row in rows), default=None),
              'rss_samples': rows, 'sampled_run': sample,
              'limitations': 'Observation duration is not readiness latency. Sampled RSS is a lower-bound peak. Stack sampling is a separate perturbed run.'}
    metrics = []
    for line in (output / 'stderr.jsonl').read_text(errors='replace').splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if (isinstance(record, dict) and record.get('monitor_metric_version') == 1
                and all(type(record.get(key)) in (int, float) for key in
                        ('monotonic_ns', 'stdout_bytes', 'stderr_bytes'))):
            metrics.append(record)
    ready = [r for r in metrics if r.get('stage') == 'sidebarContentReady']
    result['first_useful_state_ms'] = ((ready[0]['monotonic_ns'] - started_monotonic_ns) / 1e6) if ready else None
    result['readiness_boundary'] = 'First populated sidebar state published; not pixels displayed or complete catalog history.'
    result['transport_attempts'] = sum(r.get('stage') == 'transport' for r in metrics)
    result['transport_bytes'] = sum(r.get('stdout_bytes', 0) + r.get('stderr_bytes', 0)
                                    for r in metrics if r.get('stage') == 'transport')
    if sample:
        result['sample_exit_code'] = sample_exit
    (output / 'metrics.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path, help='Built .app to copy; never modified')
    parser.add_argument('--home', required=True, type=Path, help='Synthetic fixture home with restricted .local/bin wrappers')
    parser.add_argument('--output', required=True, type=Path, help='New or empty directory for numeric results and local logs')
    parser.add_argument('--seconds', type=float, default=15, help='RSS observation duration (default: 15)')
    parser.add_argument('--sample', action='store_true', help='Also capture stacks in a separate app launch')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Actual Monitor profiling requires macOS')
    if not 1 <= args.seconds <= 300:
        parser.error('--seconds must be between 1 and 300')
    app, home, output = args.app.resolve(), args.home.resolve(), args.output.resolve()
    if not (app / 'Contents/Info.plist').is_file():
        parser.error('--app must be a built .app bundle')
    try:
        manifest = json.loads((home / 'monitor-benchmark-fixture.json').read_text())
    except (OSError, ValueError):
        parser.error('--home requires monitor-benchmark-fixture.json; production homes are refused')
    if not isinstance(manifest, dict) or manifest.get('version') != 1:
        parser.error('--home fixture manifest must have version 1')
    if not (home / '.polybridge').is_dir() or not all(
        os.access(home / '.local/bin' / tool, os.X_OK)
        for tool in ('polybridge-ctl', 'polybridge-setup')
    ):
        parser.error('--home must contain synthetic history and both restricted benchmark CLI wrappers')
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error('--output must be a new or empty directory')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='pb-monitor-profile-') as temporary:
        private_app = Path(temporary) / 'Polybridge Benchmark.app'
        shutil.copytree(app, private_app, symlinks=True)
        info_file = private_app / 'Contents/Info.plist'
        with info_file.open('rb') as handle:
            info = plistlib.load(handle)
        identifier = 'dev.polybridge.benchmark.' + uuid.uuid4().hex
        info.update(CFBundleIdentifier=identifier, CFBundleName='Polybridge Benchmark',
                    CFBundleDisplayName='Polybridge Benchmark')
        info.pop('CFBundleURLTypes', None)
        with info_file.open('wb') as handle:
            plistlib.dump(info, handle)
        subprocess.run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(private_app)],
                       check=True, capture_output=True)
        binary = private_app / 'Contents/MacOS' / info['CFBundleExecutable']
        normal = output / 'observation'
        normal.mkdir()
        observe(binary, home, normal, args.seconds, False)
        if args.sample:
            sampled = output / 'sampling'
            sampled.mkdir()
            observe(binary, home, sampled, args.seconds, True)
        (output / 'environment.json').write_text(json.dumps({
            'platform': platform.platform(), 'source_app': str(app),
            'fixture_home': str(home), 'bundle_identifier': identifier,
            'seconds': args.seconds, 'rss_interval_seconds': .1,
            'launch': 'direct executable, unique copied bundle; no installation or URL registration',
        }, indent=2) + '\n')
    print(json.dumps({'output': str(output), 'sampled_run': args.sample}))


if __name__ == '__main__':
    main()
