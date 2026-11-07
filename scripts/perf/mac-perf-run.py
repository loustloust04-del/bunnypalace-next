#!/usr/bin/env python3
"""Isolated macV1 runner (no iOS runner, build, HID query when waived, or hashes).

Run only after the parent has approved a live window and supplied a current GREEN
isolation proof for this exact package/host:
  python3 scripts/perf/mac-perf-run.py run --app /path/Bench.app \
    --source-sha <40-hex> --isolation-proof /tmp/proof.json \
    --window-approved --deadline '2026-10-20T15:56:37-07:00' --waive-hid
  ... aa --aa-levels L0,L1b          # 12 processes/arm, 3 windows/level/arm
  ... baseline                     # 12 processes/scenario, 3 windows/6 levels
  ... resume --state /tmp/mp-macperf-sol/bench-ID-batch/state.json <same gates>
  ... analyze /tmp/mp-macperf-sol/bench-ID-batch

未显式豁免HID时，只在批次起跑前等闲置至少600秒，通过立即继续。
起跑后，自有进程启动/Cua激活/收尾以及bench前台的输入不算窗口外活动；
只在非自注入时发现新HID归零且前台不是自有bench才中断，原生前台断言不放宽。

All raw reports stay in the owned /tmp batch. summary.json is bounded (<1 MiB).
A deadline leaves INCOMPLETE_WINDOW, never a completed baseline. The runner takes
its own mac lease and holds the shared compilation flock for <=15 minutes. Default
policy retains the eight-block/two-hour quota and rest; an explicit expiring live-window
authorization makes that ledger record-only and skips the artificial rest. Compilation
yields always release for queued work and never accept partial runs.
Smoke/new-behavior checks for the integration owner: CLI --help; rejected expired
window/proof/package and symlink paths; seed/freeze/restore at the SAME path;
worker append ABI/cadence and actual PTY progress; interrupted/resumed ledger;
Poisson zero/nonzero intervals. Do not repeat previously passed isolation tests.
"""
import argparse
import contextlib
import ctypes
import datetime as dt
import fcntl
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
PARENT = Path('/tmp/mp-macperf-sol')
TEMPLATES = PARENT / 'template'
LIMIT = 1024 * 1024 - 1
NOISE = os.environ.get('MP_PERF_NOISE_NOTE', '键鼠与负载状态见本窗门控记录；未测量的后台噪声未排除')
LEVELS = ['L0', 'L1a', 'L1b', 'L1c', 'L-term', 'background', 'L-io', 'L2']
BUDGET = {'M1': 45, 'M2': 180, 'M3': 90, 'M4': 180, 'M5': 240,
          'M6': 180, 'M7': 120, 'M8': 180, 'M9': 720}


class Stop(Exception):
    def __init__(self, message, status='RED', code=70):
        super().__init__(message)
        self.status, self.code = status, code


def need(ok, message, status='RED', code=70):
    if not ok:
        raise Stop(message, status, code)


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_json(path, limit=LIMIT):
    path = Path(path)
    need(not path.is_symlink() and path.stat().st_size <= limit, 'JSON symlink/size rejected: ' + str(path))
    with path.open('rb') as handle:
        return json.load(handle)


def atomic_json(path, value):
    raw = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode()
    need(len(raw) <= LIMIT, 'summary/state exceeds evidence bound; not truncated to GREEN')
    path = Path(path)
    temporary = path.with_name(path.name + '.new')
    with temporary.open('wb') as handle:
        os.fchmod(handle.fileno(), 0o600)
        handle.write(raw)
    os.replace(temporary, path)


def command(argv, timeout=15, env=None):
    try:
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        raise Stop('helper timeout: ' + Path(argv[0]).name) from None
    need(result.returncode == 0, 'helper failed: ' + Path(argv[0]).name)
    need(len(result.stdout) + len(result.stderr) <= LIMIT, 'helper output exceeds bound')
    return result.stdout


def metadata(path):
    path = Path(path).resolve(strict=True)
    value = path.stat()
    return {'path': str(path), 'size': value.st_size, 'mtime_ns': value.st_mtime_ns}


def capture(value):
    need(isinstance(value, dict) and value.get('status') == 'ok' and 'value' in value,
         'missing/failed mac capture')
    return value['value']


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def validate_run(report, requested=None):
    """Validate collection; timed-out operations remain failed measurements, not missing processes."""
    errors = []
    def check(ok, message):
        if not ok:
            errors.append(message)
    try:
        check(report.get('protocol') == 'macV1', 'protocol != macV1')
        check(report.get('harnessRevision') == 'macV1-r1', 'unknown harness revision')
        config = report['configuration']
        check(report.get('runID') == config.get('runID'), 'run identity differs')
        check(report.get('sourceSHA') == config.get('sourceSHA'), 'source identity differs')
        timeout_failures = [failure for sample in report['samples']
                            if sample.get('kind') == 'operation' and sample.get('outcome') == 'timeout'
                            for failure in sample.get('assertFailures', [])]
        check(report.get('assertFailures') == timeout_failures, 'non-timeout run assertions failed/missing')
        check(report.get('observerOrders') == [-9223372036854775808, 9223372036854775807], 'observer boundaries differ')
        switches = report.get('effectiveSwitches')
        check(isinstance(switches, dict) and len(switches) == 6 and all(v is True for v in switches.values()), 'isolated switches missing/differ')
        if requested:
            mapping = {'MP_PERF_RUNID': 'runID', 'MP_PERF_SOURCE_SHA': 'sourceSHA',
                       'MP_PERF_LEVEL': 'loadLevel', 'MP_PERF_CASE': 'caseName'}
            for key, field in mapping.items():
                if key in requested:
                    check(config.get(field) == requested[key], 'requested ' + field + ' differs')
            check(config.get('scenarios') == requested['MP_PERF_SCENARIOS'].split(','), 'scenario request differs')
        before = capture(report['fixtureBefore'])
        after = capture(report['fixtureAfter'])
        profiles = before['profiles']
        check(len(profiles) >= 2 and sum(p['conversations'] for p in profiles) >= 2700
              and sum(p['messages'] for p in profiles) >= 250000, 'bulk fixture counts below contract')
        check(bool(before.get('codingPages')) and bool(before.get('files')) and len(before.get('longTexts', [])) >= 3,
              'fixture file/long-text/dbstat evidence absent')
        expected_profiles = [dict(p) for p in profiles]
        if 'M6' in config['scenarios']:
            for profile in expected_profiles:
                if profile['id'] == 'perf-bench-profile':
                    profile['messages'] += 2  # The real send creates user + assistant.
        check(expected_profiles == after['profiles'], 'fixture model counts drifted outside operation delta')
        check(before['longTexts'] == after['longTexts'], 'long-text lengths drifted')
        samples = report['samples']
        check(isinstance(samples, list) and bool(samples), 'empty sample denominator')
        for scenario in config['scenarios']:
            check(any(s.get('name') == scenario or s.get('name', '').startswith(scenario + '.') for s in samples),
                  'missing scenario ' + scenario)
        names = {sample['name'] for sample in samples}
        if 'M2' in config['scenarios']:
            cases = ['A', 'B', 'C'] if config['caseName'] == 'all' else [config['caseName']]
            wanted = {f'M2.{case}.{phase}' for case in cases for phase in ('cold', 'hot', 'same-id', 'sendEvent', 'hot-prerequisite')}
            check({name for name in names if name.startswith('M2.')} == wanted, 'M2 occurrence denominator differs')
        if 'M3' in config['scenarios']:
            check({name for name in names if name.startswith('M3.')} == {f'M3.{p["id"]}' for p in profiles}, 'M3 denominator differs')
        if 'M6' in config['scenarios']:
            wanted = {'M6.prepare', 'M6.final-render'} | {f'M6.{phase}.{i}' for phase in ('during', 'after') for i in range(5)}
            check({name for name in names if name.startswith('M6.')} == wanted, 'M6 occurrence denominator differs')
            check(report['driverLoadEvidence'].get('M6.deliveredCharacters') == '3000', 'M6 delivery evidence missing')
        if 'M7' in config['scenarios']:
            check(sum(name.startswith('M7.') for name in names) == 6, 'M7 occurrence denominator differs')
        check(len({s['name'] for s in samples}) == len(samples), 'duplicate sample names')
        for sample in samples:
            name = sample['name']
            timed_out = sample.get('kind') == 'operation' and sample.get('outcome') == 'timeout'
            check(sample.get('outcome') in ('ready', 'observed') or timed_out, name + ': invalid outcome')
            check(isinstance(sample.get('assertFailures'), list) and
                  (bool(sample['assertFailures']) if timed_out else sample['assertFailures'] == []),
                  name + ': assertions failed/missing')
            check(finite(sample['t0']) and finite(sample['endedAt']) and sample['endedAt'] > sample['t0'], name + ': bad duration')
            check(sample.get('callbackCount', 0) > 0 or config['loadLevel'] == 'background',
                  name + ': no display callbacks (not zero hitches)')
            for counter in ('gap25', 'hitch50', 'busyOver250'):
                check(isinstance(sample.get(counter), int) and sample[counter] >= 0, name + ': missing counter ' + counter)
            check(set(sample['countsBefore']) == set(sample['countsAfter']) == set(sample['countsDelta'])
                  and bool(sample['countsDelta']), name + ': counters missing')
            for key, delta in sample['countsDelta'].items():
                check(delta == sample['countsAfter'][key] - sample['countsBefore'][key], name + ': counter delta differs ' + key)
            resource = capture(sample['resourceDelta'])
            check(resource['sampledSeconds'] > 0 and all(finite(resource[k]) and resource[k] >= 0
                  for k in ('cpuPercent', 'logicalWriteMiBPerHour', 'diskReadBytes', 'diskWriteBytes')), name + ': resources invalid')
            window = sample['resourceWindow']
            check(window['successfulSamples'] > 0 and window['errors'] == [], name + ': resource sampler failed')
            capture(window['sampledPeakFootprintBytes'])
            if sample.get('busyMode') == 'callback-intervals-only-live-resize':
                check(sample['maximumBusySeconds'].get('status') == 'notApplicable', name + ': live resize busy metric must be NA')
            else:
                capture(sample['maximumBusySeconds'])
            for endpoint in ('environmentBefore', 'environmentAfter'):
                environment = sample[endpoint]
                check(environment['thermal'] == 'nominal' and not environment['lowPower'], name + ': thermal/low-power gate')
                check(environment['active'] or config['loadLevel'] == 'background', name + ': inactive foreground')
                check(capture(environment['refreshHz']) > 0, name + ': unknown refresh rate')
            if sample['kind'] == 'observation':
                check(sample['endedAt'] - sample['t0'] >= 600 and sample['deadline'] - sample['t0'] == 600,
                      name + ': observation shorter than 600s')
            elif timed_out:
                check(sample['deadline'] - sample['t0'] == 10 and sample['endedAt'] >= sample['deadline']
                      and sample['readyAt'].get('status') == 'error', name + ': invalid timeout boundary')
            else:
                ready = capture(sample['readyAt'])
                check(sample['t0'] <= ready <= sample['endedAt'], name + ': invalid ready endpoint')
        if 'M9' in config['scenarios']:
            check(sum(s.get('kind') == 'observation' for s in samples) == 1, 'M9 denominator != one full window')
            level = config['loadLevel']
            evidence = report['driverLoadEvidence']
            if level != 'L0':
                check(evidence.get(level + '.failure') == '', 'load failed/missing')
            if level in ('L1a', 'L1b', 'L1c', 'background'):
                check(int(evidence.get(level + '.actualWatcherBatches', '0')) > 0, 'no actual watcher batch')
            if level == 'L2':
                check(int(evidence.get(level + '.bridgeFramesDispatched', '0')) >= 4000, 'bridge replay incomplete')
    except (KeyError, TypeError, ValueError, AttributeError, Stop) as error:
        errors.append('malformed/missing macV1 evidence: ' + str(error))
    return errors


def percentile(values, q):
    values = sorted(values)
    return values[max(0, math.ceil(q * len(values)) - 1)] if values else None


def poisson_interval(count, seconds):
    """Exact equal-tail Garwood 95% Poisson CI, scaled to events/10 minutes.

    Integer-shape gamma CDF = Poisson survival; sum in log space avoids underflow.
    No scipy, normal approximation, pseudocount, or fake zero-width zero-event CI.
    """
    need(isinstance(count, int) and count >= 0 and seconds > 0, 'invalid Poisson exposure')
    def gamma_cdf(x, shape):
        if x <= 0:
            return 0.0
        logs = [-x + j * math.log(x) - math.lgamma(j + 1) for j in range(shape)]
        peak = max(logs)
        survival = math.exp(peak) * sum(math.exp(v - peak) for v in logs)
        return min(1.0, max(0.0, 1.0 - survival))
    def quantile(probability, shape):
        lo, hi = 0.0, max(1.0, float(shape))
        while gamma_cdf(hi, shape) < probability:
            hi *= 2
        for _ in range(80):
            mid = (lo + hi) / 2
            if gamma_cdf(mid, shape) < probability:
                lo = mid
            else:
                hi = mid
        return (lo + hi) / 2
    low = quantile(.025, count) if count else 0.0
    high = quantile(.975, count + 1)
    return {'events': count, 'seconds': seconds, 'per10Minutes': count * 600 / seconds,
            'ci95': [low * 600 / seconds, high * 600 / seconds], 'method': 'exact Garwood Poisson'}


def compact_samples(report):
    rows = []
    for sample in report['samples']:
        resource = capture(sample['resourceDelta'])
        peak = capture(sample['resourceWindow']['sampledPeakFootprintBytes'])
        row = {'op': sample['name'], 'kind': sample['kind'], 'outcome': sample['outcome'],
               'failed': sample['outcome'] not in ('ready', 'observed'),
               'counts': sample['countsDelta'], 'seconds': sample['endedAt'] - sample['t0'],
               'busyOver250': sample['busyOver250'],
               'footprintMiB': peak / 1048576, 'cpuPercent': resource['cpuPercent'],
               'logicalWriteMiBPerHour': resource['logicalWriteMiBPerHour'], 'gap25': sample['gap25'],
               'hitch50': sample['hitch50'], 'callbackCount': sample['callbackCount']}
        if sample['callbackCount'] == 0:
            row['gap25'] = row['hitch50'] = None
            row['callbacksUnavailable'] = True
        if sample['maximumBusySeconds']['status'] == 'ok':
            row['maximumBusyMs'] = capture(sample['maximumBusySeconds']) * 1000
            row['busyMs'] = sum(b['end'] - b['start'] for b in sample['busySegments']) * 1000
        ready = sample['readyAt']
        if ready['status'] == 'ok':
            row['readyMs'] = (ready['value'] - sample['t0']) * 1000
        elif sample['outcome'] == 'timeout':
            row['readinessUnconfirmedWithinMs'] = (sample['deadline'] - sample['t0']) * 1000
        rows.append(row)
    return rows


def summarize_records(records):
    groups = {}
    for record in records:
        if record.get('status') != 'OK' or record.get('warm'):
            continue
        for sample in record.get('samples', []):
            groups.setdefault((record['arm'], sample['op']), []).append(sample)
    result = []
    for (arm, name), samples in sorted(groups.items()):
        metrics = {}
        timeouts = sum(sample['outcome'] == 'timeout' for sample in samples)
        for field in ('readyMs', 'busyMs', 'maximumBusyMs', 'footprintMiB', 'cpuPercent', 'logicalWriteMiBPerHour'):
            if field == 'readyMs' and timeouts:
                continue
            values = [s[field] for s in samples if field in s]
            if values:
                metrics[field] = {f'p{int(q * 100)}': percentile(values, q) for q in (.5, .75, .95)}
        row = {'arm': arm, 'name': name, 'processes': len(samples), 'timeouts': timeouts,
               'failedOperations': sum(sample['failed'] for sample in samples), 'metrics': metrics}
        keys = sorted({key for sample in samples for key in sample['counts']})
        row['countsP50'] = {key: percentile([s['counts'].get(key, 0) for s in samples], .5) for key in keys}
        if samples[0]['kind'] == 'observation':
            row['busyOver250Rate'] = poisson_interval(sum(s['busyOver250'] for s in samples), sum(s['seconds'] for s in samples))
        result.append(row)
    return result


def self_test_timeout_summary():
    samples = [{'op': 'panel.open', 'kind': 'operation', 'outcome': 'ready',
                'failed': False, 'counts': {}, 'readyMs': index + 1} for index in range(12)]
    samples[-1].update(outcome='timeout', failed=True, readinessUnconfirmedWithinMs=10000)
    del samples[-1]['readyMs']
    records = [dict(status='OK', arm='A', warm=False, samples=[sample]) for sample in samples]
    summary = summarize_records(records)[0]
    need(summary['processes'] == 12 and summary['timeouts'] == summary['failedOperations'] == 1,
         'timeout dropped from process/failure denominator')
    need('readyMs' not in summary['metrics'], 'success-only readiness percentiles conceal a timeout')
    samples[0].update(outcome='timeout', failed=True, readinessUnconfirmedWithinMs=10000)
    del samples[0]['readyMs']
    need(summarize_records(records)[0]['timeouts'] == 2, 'second timeout not counted independently')
    print(json.dumps({'status': 'GREEN', 'checks': ['timeouts-retain-denominators-without-success-only-percentiles'],
                      'only_new_case': True, 'synthetic_only': True}))
    return 0


def self_test_resource_noise():
    gates = Gates.__new__(Gates)
    gates.time_only_until = time.time() + 3600
    reasons = ['load average', 'memory pressure', 'swapouts increased', 'compile/test process', 'screen locked/asleep']
    snapshot = {'failures': reasons.copy(), 'memoryPressure': 2}
    need(gates.blocking_failures(snapshot) == reasons[-2:] and snapshot['failures'] == reasons,
         'authorized warning became a stop or raw noise/control evidence was lost')
    snapshot['memoryPressure'] = 4
    need(gates.blocking_failures(snapshot) == ['memory pressure'] + reasons[-2:], 'critical pressure was relaxed')
    snapshot['memoryPressure'] = 2
    for until in (None, time.time() - 3600):
        gates.time_only_until = until
        need(gates.blocking_failures(snapshot) == reasons, 'default/expired noise policy changed')
    print(json.dumps({'status': 'GREEN', 'checks': ['authorized-resource-warning-record-only-control-and-critical-preserved'],
                      'only_new_case': True, 'synthetic_only': True}))
    return 0


def safe_inside(path, root):
    path = Path(path)
    need(path.is_absolute() and path.resolve() == path and path.is_relative_to(root), 'fixture path escapes owned stable root')
    return path


def load_worker(args):
    """Real owned producer. Heartbeats are written only AFTER successful work."""
    root = Path(args.root).resolve(strict=True)
    config = read_json(safe_inside(args.config, root))
    level = config['level']
    heartbeat = safe_inside(config['heartbeatPath'], root)
    files = [safe_inside(path, root) for path in config['files']]
    started, sequence = time.monotonic(), 0
    handles = []
    try:
        if level in ('L-term', 'L2'):
            handles = [path.open('ab', buffering=0) for path in files]
        if level == 'L-io':
            fd = os.open(files[0], os.O_RDWR)
            handles = [os.fdopen(fd, 'r+b', buffering=0)]
            # Darwin F_NOCACHE: physical IO, not cached reads misreported as dose.
            fcntl.fcntl(fd, 48, 1)
        frames = None
        if level == 'L2':
            with safe_inside(config['bridgeFramesPath'], root).open('rb') as handle:
                frames = json.load(handle)
            need(len(frames) >= 4000, 'bridge producer requires full protocol frame fixture')
        while True:
            sequence += 1
            if level in ('L1a', 'L1b', 'L1c', 'background'):
                for index, path in enumerate(files):
                    identity = f'mac-perf-live-{os.getpid()}-{sequence}-{index}'
                    row = {'type': 'assistant', 'uuid': identity, 'sessionId': files[index].stem,
                           'timestamp': dt.datetime.now(dt.timezone.utc).isoformat(), 'cwd': str(root / 'perf/code-project'),
                           'message': {'id': identity, 'role': 'assistant', 'model': 'mac-perf-fixture',
                                       'content': [{'type': 'text', 'text': f'Live append {sequence} ' + 'x' * 7500}]}}
                    raw = json.dumps(row, separators=(',', ':')).encode() + b'\n'
                    need(2048 <= len(raw) <= 20480, 'writer dose outside Driver ABI')
                    with path.open('ab', buffering=0) as handle:
                        handle.write(raw)
                delay = 3.0
            elif level == 'L-term':
                output = '\x1b[2J\x1b[H' + config['terminalMarker'] + f' frame {sequence}\r\n'
                output += ''.join(f'row {row:02d}  {sequence:08d}  ' + '#' * (20 + sequence % 40) + '\r\n' for row in range(22))
                handles[0].write(output.encode())
                delay = .15
            elif level == 'L2':
                index = sequence - 1
                if index >= len(frames):
                    # Actual trailing journal reads keep the producer alive through
                    # the app's final-apply gate; no invented dispatched count.
                    with safe_inside(config['bridgeFramesPath'], root).open('rb') as source:
                        while source.read(262144):
                            pass
                    handles[0].write(b'protocol-source-read-complete\n')
                    delay = 1.0
                else:
                    frame = frames[index]
                    delay = max(0, started + frame['offset'] - time.monotonic())
                    if delay:
                        time.sleep(delay)
                    payload = json.loads(frame['text'])
                    need(payload['type'] == 'edit' and payload['streaming'] is True, 'invalid bridge ABI')
                    handles[0].write((frame['text'] + '\n').encode())
                    delay = 0
            elif level == 'L-io':
                dose = config['ioBytesPerSecond']
                chunk = b'\x5a' * (dose // 2)
                handle = handles[0]
                offset = ((sequence - 1) * len(chunk)) % (100_000_000 - len(chunk))
                handle.seek(offset)
                handle.write(chunk)
                os.fsync(handle.fileno())
                handle.seek(offset)
                need(len(handle.read(len(chunk))) == len(chunk), 'short fixed-dose read')
                delay = max(0, started + sequence - time.monotonic())
            else:
                raise Stop('unsupported producer level')
            atomic_json(heartbeat, {'pid': os.getpid(), 'completedWorkUnits': sequence, 'elapsed': time.monotonic() - started})
            if delay:
                time.sleep(delay)
    finally:
        for handle in handles:
            handle.close()


class CompilationYield(Stop):
    def __init__(self):
        super().__init__('yielding measurement to compilation queue', 'COMPILATION_YIELD', 75)


def compilation_waiting(queue=None):
    queue = Path(queue) if queue is not None else Path(os.environ.get('MP_XCB_QUEUE', '/tmp/mp-xcodebuild.q2'))
    if not queue.exists():
        return False
    for ticket in queue.iterdir():
        if ticket.name.startswith('.'):
            continue
        probe = subprocess.run([str(REPO / 'scripts/lib/mplock'), 'probe', str(ticket)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if probe.returncode == 1:
            return True
        need(probe.returncode == 0 or not ticket.exists(), 'compilation queue probe failed')
    return False


def measurement_lock_budget(usage, reserve, time_only):
    need(reserve <= 895, 'next process exceeds one measurement block', 'INCOMPLETE_WINDOW', 124)
    if not time_only:
        need(usage['blocks'] < 8, 'daily measurement block allowance exhausted', 'INCOMPLETE_WINDOW', 124)
        need(usage['seconds'] + 900 <= 7200, 'daily measurement lock time exhausted', 'INCOMPLETE_WINDOW', 124)
    return 895, 900


def discard_for_compilation(state, task, record):
    state.setdefault('discardedRuns', []).append(dict(record, status='YIELDED'))
    task['runID'] = uuid.uuid4().hex
    state.pop('activeRun', None)
    state['compilationYield'] = True


def hid_initial_ready(seconds):
    return seconds >= 600


def hid_external_reset(previous, current, injecting, owned_pid, front_pid):
    return current + .1 < previous and not injecting and (owned_pid is None or front_pid != owned_pid)


def self_test_hid_gate():
    need(not hid_initial_ready(599.999), 'initial idle boundary accepted early')
    need(hid_initial_ready(600), 'initial idle boundary delayed')
    need(not hid_external_reset(700, .01, True, 100, 200), 'own activation counted as return')
    need(not hid_external_reset(700, .01, False, 100, 100), 'in-window synthetic input counted as return')
    need(hid_external_reset(700, .01, False, 100, 200), 'outside input was missed')
    need(hid_external_reset(700, .01, False, None, 200), 'outside input while waiting was missed')
    need(not hid_external_reset(700, 701, False, 100, 200), 'foreground alone counted as physical input')
    print(json.dumps({'status': 'GREEN', 'cases': 7, 'policy': 'initial600; own-input excluded; outside reset stops'}))
    return 0


class Gates:
    def __init__(self, args, isolation):
        self.args, self.iso = args, isolation
        self.deadline = dt.datetime.fromisoformat(args.deadline).timestamp()
        self.swap = None
        self.last = None
        self.blocked_reason = None
        self.blocked_since = None
        self.runtime_path = None
        self.last_screen = None
        self.caffeinate = None
        self.lock = None
        self.lock_started = None
        self.last_released = 0
        self.lease = False
        self.lock_allowance = 895
        self.cua_started = False
        self.hid_stop = threading.Event()
        self.hid_mutex = threading.Lock()
        self.hid_thread = None
        self.hid_process = None
        self.hid_injecting = False
        self.hid_last = None
        self.hid_initial = None
        self.hid_ignored = 0
        self.hid_failure = None
        self.hid_refs = None
        self.hid_old_signal = None
        until = getattr(args, 't4_time_only_until', None)
        self.time_only_until = None
        if until is not None:
            expiry = dt.datetime.fromisoformat(until)
            need(expiry.tzinfo is not None and self.deadline <= expiry.timestamp(),
                 'time-only T4 authorization must cover this bounded live window')
            self.time_only_until = expiry.timestamp()
        self.lease_env = dict(os.environ, MP_LEASE_SAY='0')
        self.graphics = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        self.graphics.CGMainDisplayID.argtypes = []
        self.graphics.CGMainDisplayID.restype = ctypes.c_uint32
        self.graphics.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
        self.graphics.CGDisplayIsAsleep.restype = ctypes.c_bool

    def read_hid(self):
        if self.hid_refs is None:
            io = ctypes.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
            cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
            io.IOServiceMatching.argtypes, io.IOServiceMatching.restype = [ctypes.c_char_p], ctypes.c_void_p
            io.IOServiceGetMatchingService.argtypes = [ctypes.c_uint, ctypes.c_void_p]
            io.IOServiceGetMatchingService.restype = ctypes.c_uint
            io.IORegistryEntryCreateCFProperty.argtypes = [ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint]
            io.IORegistryEntryCreateCFProperty.restype = ctypes.c_void_p
            io.IOObjectRelease.argtypes = [ctypes.c_uint]
            cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint]
            cf.CFStringCreateWithCString.restype = ctypes.c_void_p
            cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
            cf.CFNumberGetValue.restype = ctypes.c_bool
            cf.CFRelease.argtypes = [ctypes.c_void_p]
            entry = io.IOServiceGetMatchingService(0, io.IOServiceMatching(b'IOHIDSystem'))
            key = cf.CFStringCreateWithCString(None, b'HIDIdleTime', 0x08000100)
            need(entry and key, 'HID registry unavailable', 'BLOCKED', 78)
            self.hid_refs = io, cf, entry, key
        io, cf, entry, key = self.hid_refs
        prop = io.IORegistryEntryCreateCFProperty(entry, key, None, 0)
        need(prop, 'HID property unavailable', 'BLOCKED', 78)
        try:
            value = ctypes.c_int64()
            need(cf.CFNumberGetValue(prop, 4, ctypes.byref(value)), 'HID value unavailable', 'BLOCKED', 78)
            return value.value / 1e9
        finally:
            cf.CFRelease(prop)

    def own_input(self, active):
        if self.hid_thread is not None:
            with self.hid_mutex:
                if not active:
                    current = self.read_hid()
                    if current + .1 < self.hid_last:
                        self.hid_ignored += 1
                    self.hid_last = current
                self.hid_injecting = active

    def wait_initial_idle(self):
        if self.args.waive_hid:
            return
        while True:
            self.window()
            idle = self.read_hid()
            if hid_initial_ready(idle):
                break
            time.sleep(min(1, 600 - idle, max(0, self.remaining())))
        self.hid_initial = self.hid_last = idle
        his = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices')
        his.GetFrontProcess.argtypes, his.GetFrontProcess.restype = [ctypes.c_void_p], ctypes.c_int32
        his.GetProcessPID.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int32)]
        his.GetProcessPID.restype = ctypes.c_int32
        def interrupted(signum, frame):
            raise Stop('窗口外键鼠活动或HID监控中断，本窗作废', 'BLOCKED', 78)
        self.hid_old_signal = signal.signal(signal.SIGUSR1, interrupted)
        def watch():
            try:
                while not self.hid_stop.wait(1):
                    with self.hid_mutex:
                        current = self.read_hid()
                        psn, front = (ctypes.c_uint32 * 2)(), ctypes.c_int32()
                        need(not his.GetFrontProcess(ctypes.byref(psn))
                             and not his.GetProcessPID(ctypes.byref(psn), ctypes.byref(front)),
                             'foreground PID unavailable')
                        proc = self.hid_process
                        owned = proc.pid if proc is not None else None
                        injecting = self.hid_injecting or (proc is not None and proc.poll() is not None)
                        external = hid_external_reset(self.hid_last, current, injecting, owned, front.value)
                        if current + .1 < self.hid_last and not external:
                            self.hid_ignored += 1
                        previous, self.hid_last = self.hid_last, current
                    if external:
                        self.hid_failure = {'reason': 'outside HID reset', 'previous': previous,
                                            'current': current, 'ownedPID': owned, 'frontPID': front.value}
                        os.kill(os.getpid(), signal.SIGUSR1)
                        return
            except BaseException as error:
                self.hid_failure = {'reason': 'HID monitor unavailable', 'error': str(error)}
                os.kill(os.getpid(), signal.SIGUSR1)
        self.hid_thread = threading.Thread(target=watch, daemon=True)
        self.hid_thread.start()

    def stop_hid(self, state):
        self.hid_stop.set()
        if self.hid_thread is not None:
            self.hid_thread.join()
            self.hid_thread = None
            signal.signal(signal.SIGUSR1, self.hid_old_signal)
        state['hidPolicy'] = {'initialIdleSeconds': self.hid_initial, 'lastIdleSeconds': self.hid_last,
                              'ignoredOwnOrInWindowResets': self.hid_ignored, 'externalEvent': self.hid_failure}
        if self.hid_refs is not None:
            io, cf, entry, key = self.hid_refs
            cf.CFRelease(key)
            io.IOObjectRelease(entry)
            self.hid_refs = None

    def remaining(self):
        return self.deadline - time.time()

    def window(self, reserve=0):
        need(self.args.window_approved, 'explicit live window approval required', 'BLOCKED', 78)
        need(self.remaining() > reserve, 'not enough approved window for next complete process', 'INCOMPLETE_WINDOW', 124)

    def screen_state(self):
        console = plistlib.loads(command(['/usr/sbin/ioreg', '-a', '-r', '-n', 'Root', '-d', '1']))
        users = [user for user in console[0].get('IOConsoleUsers', [])
                 if user.get('kCGSSessionUserIDKey') == os.getuid() and user.get('kCGSSessionOnConsoleKey')]
        display = int(self.graphics.CGMainDisplayID())
        self.last_screen = {'currentConsole': bool(users),
                            'locked': not users or any(user.get('CGSSessionScreenIsLocked') for user in users),
                            'displayID': display,
                            'displayAsleep': not display or bool(self.graphics.CGDisplayIsAsleep(display))}
        return self.last_screen

    def wait_unlocked(self, state):
        while True:
            self.window()
            screen = self.screen_state()
            if not screen['locked'] and not screen['displayAsleep']:
                self.blocked_reason = self.blocked_since = None
                return
            if self.lock is not None:
                self.release_lock(state)
            self.blocked_reason = 'screen locked/asleep'
            time.sleep(min(300, max(0, self.remaining())))

    def acquire_lease(self):
        self.window(10)
        raw = command([str(REPO / 'scripts/device-lease.sh'), 'acquire', 'mac', '--why', 'mac-perf isolated measurement block'],
                      timeout=max(1, self.remaining()), env=self.lease_env)
        need(b'LEASED mac' in raw, 'mac lease not granted', 'BLOCKED', 78)
        self.lease = True
        self.caffeinate = subprocess.Popen(['/usr/bin/caffeinate', '-di', '-w', str(os.getpid())],
                                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL)

    def lease_alive(self):
        directory = Path(os.environ.get('MP_LEASE_DIR', '/tmp/mp-device-lease2')) / 'mac'
        fields = dict(line.split('=', 1) for line in (directory / 'info').read_text().splitlines() if '=' in line)
        owner = os.environ.get('MP_SESSION_ID') or os.environ.get('CLAUDE_CODE_SESSION_ID')
        need(owner and fields.get('owner') == owner, 'mac lease owner changed', 'RED')
        probe = subprocess.run([str(REPO / 'scripts/lib/mplock'), 'probe', str(directory / 'lease.flock')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        need(probe.returncode == 1, 'mac lease kernel lock absent')

    def snapshot(self):
        self.window()
        self.lease_alive()
        load = os.getloadavg()
        pressure = int(command(['/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level']).strip())
        vm = command(['/usr/bin/vm_stat']).decode()
        match = re.search(r'^Swapouts:\s+(\d+)', vm, re.M)
        need(match is not None, 'vm_stat swapouts unavailable')
        swap = int(match[1])
        thermal = command(['/usr/bin/pmset', '-g', 'therm']).decode()
        limits = [int(v) for v in re.findall(r'(?:CPU_Speed_Limit|CPU_Scheduler_Limit|CPU_Available_CPUs)\s*=\s*(\d+)', thermal)]
        speeds = [int(v) for v in re.findall(r'(?:CPU_Speed_Limit|CPU_Scheduler_Limit)\s*=\s*(\d+)', thermal)]
        power = command(['/usr/bin/pmset', '-g']).decode()
        lowpower = bool(re.search(r'lowpowermode\s+1', power))
        process_text = command(['/bin/ps', '-axo', 'pid=,pcpu=,comm=']).decode()
        processes = []
        for line in process_text.splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) == 3:
                processes.append({'pid': int(fields[0]), 'cpu': float(fields[1]), 'name': Path(fields[2]).name})
        compilers = [p for p in processes if p['name'] in ('xcodebuild', 'swift-frontend', 'XCTRunner', 'xctest')]
        screen = self.screen_state()
        locked, display_id, display_asleep = screen['locked'], screen['displayID'], screen['displayAsleep']
        hid = self.hid_last
        reasons = []
        if load[0] >= 3 or load[1] >= 4: reasons.append('load average')
        if pressure != 1: reasons.append('memory pressure')
        if self.swap is not None and swap > self.swap: reasons.append('swapouts increased')
        if speeds and any(v < 100 for v in speeds): reasons.append('thermal CPU throttle')
        if not speeds and 'No thermal warning level' not in thermal: reasons.append('thermal state unavailable')
        if lowpower: reasons.append('low power mode')
        if compilers: reasons.append('compile/test process')
        if locked or display_asleep: reasons.append('screen locked/asleep')
        self.swap = swap
        snap = {'at': dt.datetime.now().astimezone().isoformat(), 'loadAverage': list(load), 'memoryPressure': pressure,
                'swapouts': swap, 'thermalLimits': limits, 'lowPower': lowpower, 'locked': locked,
                'displayID': display_id, 'displayAsleep': display_asleep,
                'hidWaived': self.args.waive_hid, 'hidIdleSeconds': hid,
                'topCPU': sorted(processes, key=lambda p: p['cpu'], reverse=True)[:5],
                'simulatorGUIProcesses': sum(p['name'] == 'Simulator' for p in processes),
                'bootedSimulatorCount': None,
                'simulatorCountNote': 'mac-only run does not query or start simulator devices; GUI processes are not booted-device counts',
                'ccProcesses': sum(p['name'] in ('claude', 'Claude') for p in processes),
                'hubProcesses': sum('hub' in p['name'].lower() for p in processes),
                'dockerProcesses': sum('docker' in p['name'].lower() for p in processes), 'failures': reasons}
        self.last = snap
        return snap

    def blocking_failures(self, snapshot, preparing_seed=False):
        noise_only = preparing_seed or (self.time_only_until is not None and time.time() < self.time_only_until)
        return [reason for reason in snapshot['failures'] if not
                (noise_only and (reason in ('load average', 'swapouts increased') or
                                 (reason == 'memory pressure' and snapshot['memoryPressure'] == 2)))]

    def note_wait(self, reason):
        now = time.monotonic()
        if reason != self.blocked_reason:
            self.blocked_since = now if reason else None
        self.blocked_reason = reason
        elapsed = now - self.blocked_since if self.blocked_since is not None else 0
        if self.runtime_path is not None:
            atomic_json(self.runtime_path, {'at': dt.datetime.now().astimezone().isoformat(),
                        'blockedReason': reason, 'blockedSeconds': elapsed, 'snapshot': self.last})
        if elapsed >= 300 and reason and not any(item in reason for item in
                ('compile/test process', 'compilation', 'T4 rest')):
            raise Stop('unchanged host gate for five minutes: ' + reason, 'HOST_GATE_WAIT', 79)

    def yield_if_compilation_waiting(self):
        if self.lock is not None and compilation_waiting():
            raise CompilationYield()

    def end_cua_session(self):
        if self.cua_started:
            self.own_input(True)
            try:
                command(['cua-driver', 'call', 'end_session', json.dumps({'session': 'sol-macperf-measure'})])
                self.cua_started = False
            finally:
                self.own_input(False)

    def wait_clean(self, reserve, state):
        while True:
            self.window(reserve)
            if compilation_waiting():
                if self.lock is not None:
                    self.release_lock(state)
                    state['compilationYield'] = True
                self.note_wait('compilation queue occupied')
                time.sleep(2)
                continue
            snap = self.snapshot()
            if snap['locked'] or snap['displayAsleep']:
                self.wait_unlocked(state)
                continue
            failures = self.blocking_failures(snap)
            if failures:
                self.note_wait(', '.join(failures))
            if not failures:
                return snap
            time.sleep(min(5, max(0, self.remaining())))

    def compile_lock(self, reserve, state):
        self.window(reserve)
        if self.lock is not None and compilation_waiting():
            self.release_lock(state)
            state['compilationYield'] = True
        if self.lock is not None and time.monotonic() - self.lock_started + reserve > self.lock_allowance:
            self.release_lock(state)
        if self.lock is not None:
            return
        quota_path = PARENT.resolve() / 'mac-perf-quota.json'
        quota = read_json(quota_path) if quota_path.exists() else {'dates': {}, 'lastReleased': 0}
        time_only = self.time_only_until is not None and time.time() < self.time_only_until
        while not time_only and not state.get('compilationYield') and time.time() - quota['lastReleased'] < 900:
            self.wait_unlocked(state)
            self.note_wait('T4 rest')
            self.window(reserve + 900 - (time.time() - quota['lastReleased']))
            time.sleep(min(30, max(0, quota['lastReleased'] + 900 - time.time())))
        while True:
            self.wait_clean(reserve, state)
            if compilation_waiting():
                self.note_wait('compilation queue occupied')
                time.sleep(2)
                continue
            lock_path = Path(os.environ.get('MP_XCB_LOCK', '/tmp/mp-xcodebuild.flock'))
            lock = lock_path.open('a')
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.note_wait('compilation lock occupied')
                lock.close()
                time.sleep(2)
                continue
            try:
                self.window(reserve)
                quota = read_json(quota_path) if quota_path.exists() else {'dates': {}, 'lastReleased': 0}
                time_only = self.time_only_until is not None and time.time() < self.time_only_until
                if not time_only and not state.get('compilationYield') and time.time() - quota['lastReleased'] < 900:
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    lock.close()
                    self.note_wait('T4 rest')
                    time.sleep(min(30, max(0, quota['lastReleased'] + 900 - time.time())))
                    continue
                today = dt.date.today().isoformat()
                usage = quota['dates'].setdefault(today, {'blocks': 0, 'seconds': 0})
                self.lock_allowance, reservation = measurement_lock_budget(usage, reserve, time_only)
            except BaseException:
                if not lock.closed:
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    lock.close()
                raise
            self.lock, self.lock_started = lock, time.monotonic()
            self.note_wait(None)
            self.lock_timer = threading.Timer(self.lock_allowance, lambda: os.kill(os.getpid(), signal.SIGTERM))
            self.lock_timer.daemon = True
            self.lock_timer.start()
            usage['blocks'] += 1
            # Reserve the whole maximum block up front, including crash cases.
            usage['seconds'] += reservation
            quota['lastReleased'] = time.time() + reservation
            atomic_json(quota_path, quota)
            state['lockUsage'] = quota['dates']
            state['activeLockDate'] = today
            state['t4TimeOnlyUntil'] = getattr(self.args, 't4_time_only_until', None)
            state['activeLockReservedSeconds'] = reservation
            state.pop('compilationYield', None)
            return

    def release_lock(self, state):
        if self.lock is not None:
            self.lock_timer.cancel()
            elapsed = time.monotonic() - self.lock_started
            try:
                quota_path = PARENT.resolve() / 'mac-perf-quota.json'
                quota = read_json(quota_path)
                quota['dates'][state['activeLockDate']]['seconds'] += elapsed - state['activeLockReservedSeconds']
                quota['lastReleased'] = time.time()
                atomic_json(quota_path, quota)
                state['lockUsage'] = quota['dates']
            finally:
                fcntl.flock(self.lock, fcntl.LOCK_UN)
                self.lock.close()
                self.lock = None
                state['lastLockReleased'] = time.time()

    def close(self, state):
        self.stop_hid(state)
        try:
            self.release_lock(state)
            self.end_cua_session()
        finally:
            try:
                if self.lease:
                    command([str(REPO / 'scripts/device-lease.sh'), 'release', 'mac'], env=self.lease_env)
                    self.lease = False
            finally:
                stop_worker(self.caffeinate)
                self.caffeinate = None


def verify_package(args, isolation):
    need(sys.platform == 'darwin', 'mac-only runner', 'BLOCKED', 78)
    app = Path(args.app).absolute()
    need(app.suffix == '.app' and app.resolve() == app and not app.is_relative_to('/Applications'), 'independent canonical bench .app required')
    info_path = app / 'Contents/Info.plist'
    with info_path.open('rb') as handle:
        info = plistlib.load(handle)
    need(info.get('CFBundleIdentifier') == isolation.BUNDLE_ID and info.get('CFBundlePackageType') == 'APPL', 'wrong bundle identity')
    name = info.get('CFBundleExecutable', '')
    need(name and name not in ('.', '..') and '/' not in name, 'bad bundle executable')
    binary = app / 'Contents/MacOS' / name
    need(binary.resolve() == binary and os.access(binary, os.X_OK), 'unsafe/nonexecutable main binary')
    # The parent already inspected this UUID ONCE when creating the GREEN proof.
    # Never rerun dwarfdump or reopen inode/identity machinery here.
    proof = read_json(args.isolation_proof)
    need(proof.get('status') == 'GREEN' and not proof.get('failures'), 'current GREEN isolation proof required', 'BLOCKED', 78)
    known = proof.get('expected_uuids', [])
    need(isinstance(known, list) and known and all(isinstance(value, str) for value in known), 'proof UUID list absent')
    known = [str(uuid.UUID(value)).upper() for value in known]
    need(proof.get('package_uuid', '').upper() in known, 'proof package UUID missing/differs')
    policy = proof.get('kernel_policy_evidence', {})
    need(policy.get('launcher') == '/usr/bin/sandbox-exec' and policy.get('argument') == '-p', 'proof lacks actual kernel policy')
    # Reuse the already-proven lexical AND canonical read-deny paths without
    # stat/traversal of the seven production roots on each scenario.
    old_profile = policy.get('profile', '')
    paths = [json.loads(value) for value in re.findall(r'\(subpath ("(?:[^"\\]|\\.)*")\)', old_profile)]
    protected = [Path(value) for value in paths if value != policy.get('write_root')]
    need(len(set(protected)) >= 7, 'proof lacks the actual protected-root kernel profile')
    args.protected_roots = protected
    host_key = ('reclassification_host_attestation'
                if proof.get('criteria_reclassification') == 'S25-missing-canary-four-evidence' else 'host_attestation')
    need(proof.get(host_key) == metadata(HERE / 'mac-isolation.py'),
         'isolation/reclassification host changed since proof', 'BLOCKED', 78)
    need(proof.get('package_attestation') == metadata(binary),
         'package changed since proof or different app path', 'BLOCKED', 78)
    return app, binary, known


def owned_root(path, token):
    path = Path(path)
    parent = PARENT.resolve()
    need(path.parent in (parent, parent / 'template') and re.fullmatch(r'bench-[A-Za-z0-9_-]+', path.name), 'owned root naming rejected')
    need(path.resolve() == path and not path.is_symlink(), 'owned root canonical path rejected')
    if path.exists():
        marker = read_json(path / '.mac-perf-owner.json')
        need(marker == {'token': token}, 'refusing deletion/reuse of unowned root')
        need(path.stat().st_uid == os.getuid(), 'owned root uid differs')
    return path


def clone(source, destination, token):
    owned_root(source, token)
    owned_root(destination, token)
    need(not destination.exists(), 'clone destination exists')
    command(['/bin/cp', '-cR', str(source), str(destination)], timeout=180)


def _app_window(windows, pid):
    candidates = [window for window in windows if window.get('pid') == pid and window.get('layer') == 0
                  and window.get('bounds', {}).get('width', 0) > 0
                  and window.get('bounds', {}).get('height', 0) > 0]
    return max(candidates, key=lambda window: window['bounds']['width'] * window['bounds']['height'],
               default=None)


def process(argv, env, root, timeout, gates, state, expected=None):
    gates.window(timeout + 2)
    gates.yield_if_compilation_waiting()
    log = root / 'perf/process-output.log'
    preparing_seed = env.get('MP_PERF_SEED') == 'bulk' and env.get('MP_PERF_RUN') != '1'
    total = 0
    gates.own_input(True)
    proc = subprocess.Popen(argv, cwd=root, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    gates.hid_process = proc
    started = time.monotonic()
    next_gate = 0
    next_queue = 0
    try:
        if not preparing_seed:
            command(['cua-driver', 'call', 'start_session', json.dumps({'session': 'sol-macperf-measure'})])
            gates.cua_started = True
            while True:
                gates.window()
                if time.monotonic() >= next_queue:
                    gates.yield_if_compilation_waiting()
                    next_queue = time.monotonic() + 1
                need(proc.poll() is None, 'owned bench exited before creating its window (exit ' + str(proc.returncode) + ')')
                need(time.monotonic() - started < timeout, 'owned window startup watchdog timeout', 'RED', 124)
                window_raw = command(['cua-driver', 'call', 'list_windows',
                                      json.dumps({'pid': proc.pid, 'session': 'sol-macperf-measure'})], timeout=2)
                (root / 'perf/window-list.json').write_bytes(window_raw)
                windows = json.loads(window_raw)
                need(isinstance(windows, dict) and isinstance(windows.get('windows'), list),
                     'Cua window-list schema changed')
                window = _app_window(windows['windows'], proc.pid)
                if window is not None:
                    break
                time.sleep(.1)
            activation = subprocess.run(['cua-driver', 'call', 'bring_to_front',
                                         json.dumps({'pid': proc.pid, 'window_id': window['window_id'],
                                                     'session': 'sol-macperf-measure'})],
                                        timeout=10, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT)
            need(len(activation.stdout) <= LIMIT, 'activation output exceeds bound')
            (root / 'perf/activation.json').write_bytes(activation.stdout)
        gates.own_input(False)
        with selectors.DefaultSelector() as selector, log.open('wb') as output:
            selector.register(proc.stdout, selectors.EVENT_READ)
            while proc.poll() is None or selector.get_map():
                gates.window()
                if time.monotonic() >= next_queue:
                    gates.yield_if_compilation_waiting()
                    next_queue = time.monotonic() + 1
                need(time.monotonic() - started < timeout, 'app/producer watchdog timeout', 'RED', 124)
                need(gates.lock is not None and time.monotonic() - gates.lock_started < gates.lock_allowance,
                     'measurement compilation lock deadline', 'RED', 124)
                if time.monotonic() >= next_gate:
                    snap = gates.snapshot()
                    failures = gates.blocking_failures(snap, preparing_seed)
                    need(not failures, 'in-process load gate: ' + ', '.join(failures))
                    next_gate = time.monotonic() + 3
                for key, _ in selector.select(.2):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        total += len(chunk)
                        need(total <= 256 * 1024, 'app output exceeds bounded capture')
                        output.write(chunk)
            need(proc.wait() == 0, 'app exited nonzero; private output in owned root')
        snap = gates.snapshot()
        failures = gates.blocking_failures(snap, preparing_seed)
        need(not failures, 'post-process load gate: ' + ', '.join(failures))
    finally:
        gates.own_input(True)
        # Only the session this Popen created; never signal a manifest PID.
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGTERM)
        if proc.poll() is None:
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
        if total == 0:
            os.set_blocking(proc.stdout.fileno(), False)
            pending = proc.stdout.read(256 * 1024)
            if pending:
                log.write_bytes(pending)
        proc.stdout.close()
        gates.hid_process = None
        gates.own_input(False)


def prepare_load(root, fixture, level, isolation, protected):
    for item in fixture['loads']:
        item['pid'] = 0
    if level == 'L0':
        return None
    perf = root / 'perf'
    spec = {'level': level, 'pid': 0, 'heartbeatPath': str(perf / 'load-heartbeat.json')}
    if level in ('L1a', 'L1b', 'L1c', 'background'):
        code = fixture['code']
        need(len(code) == 3, 'writer requires three native Code fixtures')
        spec['files'] = [item['path'] for item in code]
        spec['codeKey'] = max(code, key=lambda item: item['minimumBytes'])['key']
    elif level == 'L-term':
        feed = perf / 'terminal-feed.ansi'
        feed.write_bytes(b'')
        spec.update(files=[str(feed)], terminalTitle='mac-perf synthetic TUI', terminalMarker='MAC-PERF-LIVE-TUI')
    elif level == 'L-io':
        path = perf / 'fixed-dose-io.bin'
        # Real allocation/writes, not a sparse file or generated byte count.
        with path.open('wb') as handle:
            block = b'\x5a' * 1_000_000
            for _ in range(100):
                handle.write(block)
            handle.flush()
            os.fsync(handle.fileno())
        spec.update(files=[str(path)], ioBytesPerSecond=2_000_000)
    elif level == 'L2':
        seed = read_json(perf / 'seed-result.json')
        frames_path = safe_inside(seed['bridgeFramesPath'], root)
        need(frames_path.is_file(), 'real bridge protocol fixture absent')
        journal = perf / 'bridge-producer.jsonl'
        journal.write_bytes(b'')
        spec.update(files=[str(journal)], bridgeFramesPath=str(frames_path), backgroundConversationID=seed['backgroundConversationID'])
    config = perf / 'load-config.json'
    atomic_json(config, spec)
    env = isolation.clean_environment(root / 'home', root / 'tmp')
    profile = isolation.sandbox_profile(root, protected)
    worker = subprocess.Popen(['/usr/bin/sandbox-exec', '-p', profile, sys.executable, str(Path(__file__).resolve()),
                               '_load', '--root', str(root), '--config', str(config)],
                              cwd=root, env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        end = time.monotonic() + 8
        while time.monotonic() < end:
            need(worker.poll() is None, 'real load producer exited during startup')
            heartbeat = Path(spec['heartbeatPath'])
            if heartbeat.exists() and all(Path(p).stat().st_size > 0 for p in spec['files']):
                witness = read_json(heartbeat)
                need(witness['pid'] == worker.pid and witness['completedWorkUnits'] > 0, 'producer startup witness differs')
                spec['pid'] = worker.pid
                fixture['loads'] = [item for item in fixture['loads'] if item['level'] != level] + [spec]
                return worker
            time.sleep(.1)
        raise Stop('real load producer heartbeat/progress timeout')
    except BaseException:
        stop_worker(worker)
        raise


def stop_worker(worker):
    if worker is not None:
        if worker.poll() is None:
            worker.terminate()
            try:
                worker.wait(timeout=3)
            except subprocess.TimeoutExpired:
                worker.kill()
        worker.wait()


def schedule(args):
    tasks = []
    def add(arm, scenario, count, level='L0', warm=False):
        for index in range(count):
            tasks.append({'arm': arm, 'scenario': scenario, 'level': level, 'warm': warm,
                          'index': index + 1, 'runID': uuid.uuid4().hex})
    scenarios = args.scenarios.split(',')
    need(scenarios and len(scenarios) == len(set(scenarios)) and all(s in BUDGET for s in scenarios), 'invalid scenarios')
    if args.mode == 'run' and args.verify_m1_first:
        add('probe', 'M1', 1, warm=True)
    if args.mode in ('aa', 'abba'):
        need('M9' not in scenarios, 'use --aa-levels for fixed M9 windows')
        levels = args.aa_levels.split(',')
        need(len(levels) == len(set(levels)) and all(level in LEVELS for level in levels), 'invalid/duplicate M9 levels')
        if args.mode == 'aa':
            need(len(levels) >= 2, 'formal A/A requires at least two M9 levels')
        arms = ['A', 'B'] if args.mode == 'aa' else ['A1', 'B1', 'B2', 'A2']
        for arm in arms:
            for scenario in scenarios:
                add(arm, scenario, 1, warm=True)
                add(arm, scenario, 12 if args.mode == 'aa' else 6)
            for level in levels:
                add(arm, 'M9', 3 if args.mode == 'aa' else 1, level)
    elif args.mode == 'baseline':
        for scenario in [f'M{i}' for i in range(1, 9)]:
            add('base', scenario, 1, warm=True)
            add('base', scenario, 12)
        for level in LEVELS[:6]:
            add('base', 'M9', 3, level)
    else:
        for scenario in scenarios:
            add('run', scenario, args.processes, args.level if scenario == 'M9' else 'L0')
    return tasks


def run_batch(args):
    need(re.fullmatch(r'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', args.source_sha) is not None, 'exact source revision required')
    need(args.window_approved, 'live window approval required', 'BLOCKED', 78)
    need(dt.datetime.fromisoformat(args.deadline).utcoffset() is not None, 'deadline must include timezone')
    need(dt.datetime.fromisoformat(args.deadline).timestamp() > time.time(), 'approved window expired', 'INCOMPLETE_WINDOW', 124)
    isolation = load_module('mac_isolation', HERE / 'mac-isolation.py')
    app, binary, uuids = verify_package(args, isolation)
    if args.mode == 'abba' or (args.mode == 'resume' and args.b_app):
        need(args.b_app and args.b_proof and args.b_source_sha, 'ABBA/resume B needs --b-app --b-proof --b-source-sha')
        need(re.fullmatch(r'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', args.b_source_sha) is not None, 'B source revision invalid')
        import copy
        bargs = copy.copy(args)
        bargs.app, bargs.isolation_proof = args.b_app, args.b_proof
        bapp, bbinary, buuids = verify_package(bargs, isolation)
    else:
        bapp, bbinary, buuids = app, binary, uuids
    if args.mode == 'resume':
        state_path = Path(args.state).resolve(strict=True)
        state = read_json(state_path)
        need(state['status'] in ('INCOMPLETE_WINDOW', 'RUNNING', 'HOST_GATE_WAIT'), 'only incomplete batches can resume')
        token = state['token']
        batch = owned_root(state_path.parent, token)
        need(state['packageUUIDs'] == uuids and state['sourceSHA'] == args.source_sha.lower(), 'resume package/source differs')
        need(state['binaryPath'] == str(binary) and state['bBinaryPath'] == str(bbinary), 'resume bundle paths differ')
        need(state['bPackageUUIDs'] == buuids, 'resume B UUID differs')
        need(state.get('templateFrozen') is True, 'seed did not finish; cannot resume partial template')
        # Interrupted in-flight work is not silently counted as complete/retried.
        need(not state.get('activeRun'), 'interrupted active process requires explicit diagnosis; no automatic retry')
        need(all(record.get('status') == 'OK' for record in state['records']), 'failed/interrupted process is not automatically retried')
        need(state.get('bSourceSHA') == (args.b_source_sha or args.source_sha).lower(), 'resume B source differs')
        state['status'] = 'RUNNING'
        state.pop('error', None)
    else:
        PARENT.mkdir(mode=0o700, exist_ok=True)
        isolation.private_directory(PARENT.resolve(), parent=True)
        reusable = read_json(args.reuse_seed_state) if args.reuse_seed_state else None
        if reusable is not None:
            need(reusable.get('templateFrozen') is True, 'cannot reuse an unfinished seed')
            token = reusable['token']
        else:
            token = uuid.uuid4().hex
        suffix = '-batch-' + uuid.uuid4().hex[:8] if reusable is not None else '-batch'
        batch = PARENT.resolve() / ('bench-' + token + suffix)
        batch.mkdir(mode=0o700)
        atomic_json(batch / '.mac-perf-owner.json', {'token': token})
        state_path = batch / 'state.json'
        state = {'protocol': 'macV1-batch', 'mode': args.mode, 'status': 'RUNNING', 'token': token,
                 'sourceSHA': args.source_sha.lower(), 'packageUUIDs': uuids, 'bPackageUUIDs': buuids,
                 'bSourceSHA': (args.b_source_sha or args.source_sha).lower(),
                 'binaryPath': str(binary), 'bBinaryPath': str(bbinary), 'tasks': schedule(args),
                 'records': [], 'next': 0, 'noiseNote': NOISE, 'hidWaived': args.waive_hid,
                 'root': str(PARENT.resolve() / ('bench-' + token)), 'case': args.case}
        if reusable is not None:
            need(reusable['root'] == state['root'], 'frozen seed absolute root changed')
            state['templateFrozen'] = True
            state['seedReusedFrom'] = str(Path(args.reuse_seed_state).resolve())
            state['seedProducer'] = {'sourceSHA': reusable['sourceSHA'], 'binaryPath': reusable['binaryPath']}
    root = owned_root(state['root'], token)
    templates = TEMPLATES.resolve()
    need(templates == PARENT.resolve() / 'template', 'template directory escapes approved parent')
    templates.mkdir(mode=0o700, exist_ok=True)
    isolation.private_directory(templates)
    template = owned_root(templates / root.name, token)
    state['template'] = str(template)
    if state.get('templateFrozen'):
        need(read_json(template / 'perf/fixture.json').get('revision') == 'macV1-r1-fixture',
             'frozen seed fixture revision changed')
    gates = Gates(args, isolation)
    gates.runtime_path = batch / 'runtime.json'
    old_handlers = {}
    def interrupted(signum, frame):
        raise Stop('measurement interrupted', 'INTERRUPTED', 130)
    for sig in (signal.SIGINT, signal.SIGTERM):
        old_handlers[sig] = signal.signal(sig, interrupted)
    try:
        gates.wait_initial_idle()
        gates.wait_unlocked(state)
        gates.acquire_lease()
        while not state.get('templateFrozen'):
            gates.compile_lock(850, state)
            if root.exists():
                shutil.rmtree(owned_root(root, token))
            root.mkdir(mode=0o700)
            atomic_json(root / '.mac-perf-owner.json', {'token': token})
            for child in ('home', 'tmp', 'perf'):
                (root / child).mkdir(mode=0o700)
            env = isolation.clean_environment(root / 'home', root / 'tmp')
            env.update(MP_PERF_ROOT=str(root), MP_PERF_SEED='bulk', MP_PERF_WINDOW_APPROVED='1')
            profile = isolation.sandbox_profile(root, args.protected_roots)
            try:
                process(['/usr/bin/sandbox-exec', '-p', profile, str(binary)], env, root, 840, gates, state)
            except CompilationYield:
                state['compilationYield'] = True
                gates.release_lock(state)
                gates.end_cua_session()
                continue
            seed = read_json(root / 'perf/seed-result.json')
            need(seed.get('status') == 'complete' and not seed.get('error'), 'bulk seed failed')
            fixture = read_json(root / 'perf/fixture.json')
            need(fixture.get('revision') == 'macV1-r1-fixture' and len(fixture.get('chats', [])) >= 3
                 and len(fixture.get('code', [])) == 3 and bool(fixture.get('files')), 'empty/incomplete bulk fixture')
            for item in fixture['files']:
                path = safe_inside(item['path'], root)
                need(path.stat().st_size == item['bytes'] and item['bytes'] > 0, 'seed file byte count differs')
            clone(root, template, token)
            state['templateFrozen'] = True
            atomic_json(state_path, state)
        while state['next'] < len(state['tasks']):
            gates.wait_unlocked(state)
            task = state['tasks'][state['next']]
            reserve = BUDGET[task['scenario']] + 30
            gates.compile_lock(reserve, state)
            before = gates.wait_clean(reserve, state)
            if gates.lock is None:
                continue
            owned_root(root, token)
            if root.exists():
                shutil.rmtree(root)
            clone(template, root, token)  # Absolute DB/Code paths stay unchanged.
            fixture = read_json(root / 'perf/fixture.json')
            if task['scenario'] == 'M6':
                fixture['streamConversationID'] = next(chat['conversationID'] for chat in fixture['chats'] if chat['name'] == 'A')
            worker = None
            yielded = False
            record = dict(task, status='RUNNING', beforeGate=before)
            state['activeRun'] = task['runID']
            atomic_json(state_path, state)
            destination = batch / task['arm']
            if task['warm']:
                destination /= 'warm'
            destination.mkdir(mode=0o700, parents=True, exist_ok=True)
            try:
                worker = prepare_load(root, fixture, task['level'], isolation, args.protected_roots)
                atomic_json(root / 'perf/fixture.json', fixture)
                env = isolation.clean_environment(root / 'home', root / 'tmp')
                env.update(MP_PERF_RUN='1', MP_PERF_ROOT=str(root), MP_PERF_WINDOW_APPROVED='1',
                           MP_PERF_RUNID=task['runID'], MP_PERF_SOURCE_SHA=state['sourceSHA'],
                           MP_PERF_SCENARIOS=task['scenario'], MP_PERF_LEVEL=task['level'], MP_PERF_CASE=state['case'])
                use_b = task['arm'].startswith('B')
                active_binary = bbinary if use_b else binary
                env['MP_PERF_SOURCE_SHA'] = state['bSourceSHA'] if use_b else state['sourceSHA']
                with (destination / 'manifest.tsv').open('a') as handle:
                    handle.write(task['runID'] + '\t' + json.dumps(env, separators=(',', ':')) + '\n')
                profile = isolation.sandbox_profile(root, args.protected_roots)
                process(['/usr/bin/sandbox-exec', '-p', profile, str(active_binary),
                         '-lastProfileId', 'perf-bench-profile'], env, root,
                        BUDGET[task['scenario']], gates, state)
                report_path = root / 'perf' / ('run-' + task['runID'] + '.json')
                # Raw evidence is private /tmp, allowed larger than the bounded summary.
                report = read_json(report_path, 64 * 1024 * 1024)
                errors = validate_run(report, env)
                need(not errors, '; '.join(errors))
                record.update(status='OK', afterGate=gates.last,
                              timeoutOperations=sum(sample['outcome'] == 'timeout' for sample in report['samples']))
                # Warmups remain separate and are never included in denominators.
                shutil.copyfile(report_path, destination / report_path.name)
                with (destination / 'ledger.tsv').open('a') as handle:
                    handle.write(f"{time.time()}\t{task['runID']}\tOK\n")
            except CompilationYield as error:
                record.update(error=str(error))
                discard_for_compilation(state, task, record)
                with (destination / 'ledger.tsv').open('a') as handle:
                    handle.write(f"{time.time()}\t{record['runID']}\tYIELDED\n")
                yielded = True
            except BaseException as error:
                with (destination / 'ledger.tsv').open('a') as handle:
                    handle.write(f"{time.time()}\t{task['runID']}\tFAIL\n")
                record.update(status='FAIL', error=str(error))
                state['records'].append(record)
                state.pop('activeRun', None)
                raise
            finally:
                stop_worker(worker)
                if yielded or (gates.lock is not None and compilation_waiting()):
                    gates.release_lock(state)
                    state['compilationYield'] = True
                gates.end_cua_session()
            if yielded:
                atomic_json(state_path, state)
                continue
            state['records'].append(record)
            state['next'] += 1
            state.pop('activeRun', None)
            atomic_json(state_path, state)
        state['status'] = 'COMPLETE'
    except Stop as error:
        state.update(status=error.status, error=str(error))
        raise
    except BaseException as error:
        state.update(status='RED', error=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        try:
            gates.close(state)
        except BaseException as error:
            state.update(status='RED', error='cleanup: ' + str(error))
        state['deadline'] = args.deadline
        state['lastGate'] = gates.last
        state['lastScreen'] = gates.last_screen
        state['lastBlockedReason'] = gates.blocked_reason
        atomic_json(state_path, state)
        summary = {'protocol': 'macV1-summary', 'status': state['status'], 'mode': state['mode'],
                   'noiseNote': NOISE, 'hidWaived': args.waive_hid, 'completed': state['next'],
                   'planned': len(state['tasks']), 'error': state.get('error'), 'batch': str(batch),
                   'baselineComplete': state['mode'] == 'baseline' and state['status'] == 'COMPLETE',
                   'aaComplete': formal_aa_complete(state),
                   'timedOutOperations': sum(record.get('timeoutOperations', 0) for record in state['records']),
                   'performanceVerdict': ('RED' if any(record.get('timeoutOperations', 0) for record in state['records'])
                                          else 'GREEN' if state['status'] == 'COMPLETE' else 'INCOMPLETE'),
                   'statistics': summarize_records(records_from_disk(batch, state))}
        atomic_json(batch / 'summary.json', summary)
        print(json.dumps({'status': state['status'], 'summary': str(batch / 'summary.json'), 'completed': state['next'],
                          'planned': len(state['tasks']), 'noiseNote': NOISE}, ensure_ascii=False))
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
    return 0 if state['status'] == 'COMPLETE' else 70


def formal_aa_complete(state):
    return (state['mode'] == 'aa' and state['status'] == 'COMPLETE'
            and {task['scenario'] for task in state['tasks'] if not task['warm'] and task['scenario'] != 'M9'}
            == {f'M{i}' for i in range(1, 9)})


def report_file(batch, record):
    directory = batch / record['arm']
    if record['warm']:
        directory /= 'warm'
    return directory / ('run-' + record['runID'] + '.json')


def records_from_disk(batch, state):
    for record in state['records']:
        if record.get('status') == 'OK':
            report = read_json(report_file(batch, record), 64 * 1024 * 1024)
            yield dict(record, samples=compact_samples(report))


def analyze(directory):
    base = Path(directory)
    state = read_json(base / 'state.json')
    errors, records = [], []
    for record in state['records']:
        if record.get('status') != 'OK':
            errors.append(record.get('error', 'failed process'))
            continue
        path = report_file(base, record)
        report = read_json(path, 64 * 1024 * 1024)
        requested = {'MP_PERF_RUNID': record['runID'], 'MP_PERF_SOURCE_SHA': state['bSourceSHA'] if record['arm'].startswith('B') else state['sourceSHA'],
                     'MP_PERF_SCENARIOS': record['scenario'], 'MP_PERF_LEVEL': record['level'], 'MP_PERF_CASE': state['case']}
        run_errors = validate_run(report, requested)
        errors += [record['runID'] + ': ' + error for error in run_errors]
        if not run_errors:
            records.append(dict(record, samples=compact_samples(report)))
    complete = state['status'] == 'COMPLETE' and state['next'] == len(state['tasks'])
    expected_ids = [task['runID'] for task in state['tasks'][:state['next']]]
    actual_ids = [record['runID'] for record in state['records'] if record.get('status') == 'OK']
    if actual_ids != expected_ids or len(set(actual_ids)) != len(actual_ids):
        errors.append('planned/recorded process denominator differs')
    if state['status'] not in ('COMPLETE', 'INCOMPLETE_WINDOW', 'RUNNING', 'HOST_GATE_WAIT'):
        errors.append(state.get('error', state['status']))
    result = {'protocol': 'macV1-analysis', 'status': 'RED' if errors else 'COMPLETE' if complete else 'INCOMPLETE_WINDOW',
              'planned': len(state['tasks']), 'completed': state['next'], 'noiseNote': NOISE,
              'errors': errors, 'statistics': summarize_records(records)}
    result['aaComplete'] = formal_aa_complete(state) and not errors
    result['baselineComplete'] = state['mode'] == 'baseline' and complete and not errors
    result['performanceVerdict'] = ('RED' if any(sample['failed'] for record in records for sample in record['samples'])
                                    else 'GREEN' if complete and not errors else 'INCOMPLETE')
    # A/A noise bands compare independent processes, never individual UI callbacks.
    by_arm = {}
    for record in records:
        if record.get('warm'):
            continue
        for sample in record['samples']:
            by_arm.setdefault((record['arm'], sample['op']), []).append(sample)
    differences = []
    import random
    rng = random.Random(22)
    arms_a = ['A'] if state['mode'] == 'aa' else ['A1', 'A2']
    arms_b = ['B'] if state['mode'] == 'aa' else ['B1', 'B2']
    names = sorted({name for arm, name in by_arm})
    if state['mode'] in ('aa', 'abba'):
        for name in names:
            a = [s for arm in arms_a for s in by_arm.get((arm, name), [])]
            b = [s for arm in arms_b for s in by_arm.get((arm, name), [])]
            if any(sample['outcome'] == 'timeout' for sample in a) or any(sample['outcome'] == 'timeout' for sample in b):
                result.setdefault('readinessTimeouts', []).append({
                    'name': name, 'AProcesses': len(a), 'BProcesses': len(b),
                    'ATimeouts': sum(sample['outcome'] == 'timeout' for sample in a),
                    'BTimeouts': sum(sample['outcome'] == 'timeout' for sample in b)})
            for metric in ('readyMs', 'busyMs', 'maximumBusyMs', 'footprintMiB', 'cpuPercent', 'logicalWriteMiBPerHour'):
                if metric == 'readyMs' and (any(sample['outcome'] == 'timeout' for sample in a)
                                            or any(sample['outcome'] == 'timeout' for sample in b)):
                    continue
                aa, bb = [s[metric] for s in a if metric in s], [s[metric] for s in b if metric in s]
                if not aa or not bb:
                    continue
                row = {'name': name, 'metric': metric, 'A': percentile(aa, .75), 'B': percentile(bb, .75)}
                row['p75Difference'] = row['B'] - row['A']
                if len(aa) >= 3 and len(bb) >= 3:
                    boot = [percentile(rng.choices(bb, k=len(bb)), .75) - percentile(rng.choices(aa, k=len(aa)), .75) for _ in range(2000)]
                    row['processBootstrap95'] = [percentile(boot, .025), percentile(boot, .975)]
                else:
                    row['processBootstrap95'] = None
                    row['insufficientProcesses'] = True
                differences.append(row)
        result['processComparisons'] = differences
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    return 0 if result['status'] == 'COMPLETE' else 1


def self_test_quota_record_only():
    usage = {'blocks': 99, 'seconds': 9000}
    before = dict(usage)
    need(measurement_lock_budget(usage, 750, True) == (895, 900) and usage == before,
         'authorized ledger is still a gate or its history was reset')
    for extended, reserve in ((False, 750), (True, 896)):
        try:
            measurement_lock_budget(usage, reserve, extended)
        except Stop as error:
            need(error.status == 'INCOMPLETE_WINDOW', 'invalid default/block refusal category')
        else:
            raise Stop('default quota or single-block boundary was removed')
    print(json.dumps({'status': 'GREEN', 'checks': ['authorized-ledger-record-only-default-and-block-preserved'],
                      'only_new_case': True, 'synthetic_only': True}))
    return 0


def self_test_scheduler():
    import tempfile
    usage = {'blocks': 8, 'seconds': 1128}
    before = dict(usage)
    need(measurement_lock_budget(usage, 210, True) == (895, 900)
         and usage == before, 'time-only authorization reset usage or retained block cap')
    need(measurement_lock_budget({'blocks': 99, 'seconds': 9000}, 750, True) == (895, 900),
         'authorized ledger still blocks a complete process')
    for spent, reserve, extended in ((usage, 210, False),
                                     ({'blocks': 1, 'seconds': 6850}, 346, False),
                                     ({'blocks': 1, 'seconds': 7200}, 1, False)):
        try:
            measurement_lock_budget(spent, reserve, extended)
        except Stop as error:
            need(error.status == 'INCOMPLETE_WINDOW', 'invalid budget refusal category')
        else:
            raise Stop('lock budget incorrectly admitted an exhausted/default-capped run')
    PARENT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='scheduler-selftest-', dir=PARENT) as directory:
        queue = Path(directory)
        with (queue / 'live-ticket').open('a') as ticket:
            fcntl.flock(ticket, fcntl.LOCK_EX | fcntl.LOCK_NB)
            need(compilation_waiting(queue), 'live compiler ticket was not detected')
            fcntl.flock(ticket, fcntl.LOCK_UN)
        need(not compilation_waiting(queue), 'stale unlocked compiler ticket blocks measurement')
    state = {'next': 1, 'records': [{'status': 'OK'}], 'activeRun': 'discarded-run'}
    task = {'runID': 'discarded-run', 'scenario': 'M9'}
    discard_for_compilation(state, task, dict(task, status='RUNNING'))
    need(state['next'] == 1 and state['records'] == [{'status': 'OK'}]
         and 'activeRun' not in state and task['runID'] != 'discarded-run'
         and state['discardedRuns'][0]['runID'] == 'discarded-run'
         and state['discardedRuns'][0]['status'] == 'YIELDED' and state['compilationYield'],
         'compiler yield consumed a denominator or reused partial-run identity')
    print(json.dumps({'status': 'GREEN', 'checks': ['time-only-budget-real-flock-queue-discarded-denominator'],
                      'only_new_case': True, 'synthetic_only': True}))
    return 0


def self_test_window_selection():
    hidden = {'pid': 42, 'layer': 0, 'window_id': 1, 'bounds': {'width': 0, 'height': 0}}
    main = {'pid': 42, 'layer': 0, 'window_id': 2, 'bounds': {'width': 900, 'height': 600}}
    foreign = dict(main, pid=43, window_id=3)
    need(_app_window([hidden, foreign, main], 42) == main, 'zero-frame helper displaced owned main window')
    need(_app_window([hidden, foreign], 42) is None, 'helper/foreign window accepted before main exists')
    print(json.dumps({'status': 'GREEN', 'checks': ['owned-nonzero-main-window-before-exact-activation'],
                      'only_new_case': True}))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='mode', required=True)
    for mode in ('run', 'aa', 'abba', 'baseline', 'resume'):
        p = sub.add_parser(mode)
        for name in ('app', 'source-sha', 'isolation-proof', 'deadline'):
            p.add_argument('--' + name, required=True)
        p.add_argument('--window-approved', action='store_true')
        p.add_argument('--waive-hid', action='store_true')
        p.add_argument('--t4-time-only-until', help='explicit expiring live-window authorization: quota records usage without blocking; skip artificial rests')
        p.add_argument('--scenarios', default='M1,M2,M3,M4,M5,M6,M7,M8')
        p.add_argument('--level', choices=LEVELS, default='L0')
        p.add_argument('--case', default='all')
        p.add_argument('--processes', type=int, default=1)
        p.add_argument('--aa-levels', default='L0,L1b')
        p.add_argument('--b-app')
        p.add_argument('--b-proof')
        p.add_argument('--b-source-sha')
        p.add_argument('--state', required=mode == 'resume')
        if mode != 'resume':
            p.add_argument('--reuse-seed-state')
        if mode == 'run':
            p.add_argument('--verify-m1-first', action='store_true')
    p = sub.add_parser('wait-window')
    p.add_argument('--deadline', required=True)
    p.add_argument('--window-approved', action='store_true')
    p.set_defaults(waive_hid=True)
    p = sub.add_parser('analyze')
    p.add_argument('directory')
    p = sub.add_parser('_load', help=argparse.SUPPRESS)
    p.add_argument('--root', required=True)
    p.add_argument('--config', required=True)
    sub.add_parser('scheduler-self-test')
    sub.add_parser('quota-record-self-test')
    sub.add_parser('timeout-summary-self-test')
    sub.add_parser('resource-noise-self-test')
    sub.add_parser('window-selection-self-test')
    sub.add_parser('hid-gate-self-test')
    args = parser.parse_args(argv)
    try:
        if args.mode == 'hid-gate-self-test':
            return self_test_hid_gate()
        if args.mode == 'window-selection-self-test':
            return self_test_window_selection()
        if args.mode == 'scheduler-self-test':
            return self_test_scheduler()
        if args.mode == 'quota-record-self-test':
            return self_test_quota_record_only()
        if args.mode == 'timeout-summary-self-test':
            return self_test_timeout_summary()
        if args.mode == 'resource-noise-self-test':
            return self_test_resource_noise()
        if args.mode == 'wait-window':
            gates = Gates(args, None)
            gates.wait_unlocked({})
            print(json.dumps({'status': 'READY', 'deadline': args.deadline}))
            return 0
        if args.mode == '_load':
            load_worker(args)
            return 0
        if args.mode == 'analyze':
            return analyze(args.directory)
        need(args.processes > 0 and args.processes <= 100, 'process count outside 1..100')
        need(re.fullmatch(r'[A-Za-z0-9_-]{1,128}', args.case) is not None, 'invalid case token')
        return run_batch(args)
    except Stop as error:
        print(json.dumps({'status': error.status, 'error': str(error)}, ensure_ascii=False), file=sys.stderr)
        return error.code
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({'status': 'RED', 'error': type(error).__name__ + ': ' + str(error)}, ensure_ascii=False), file=sys.stderr)
        return 70


if __name__ == '__main__':
    sys.exit(main())
