#!/bin/bash
# Read-only device pull. Run with bash; never enable shell/Python tracing.
# device.json: {"floorSlug":"…","profileId":"…","identityVerified":true}
# Optional deviceId must identify the fixed device below. CLI slug must match.
set -eu
umask 077
exec python3 - "$@" <<'PY'
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

DEVICE = '00008110-000E0C1121B9401E'
BUNDLE = 'com.susu.MemoryPalace.ios'
ROOT = Path.home() / '.mp-test-data' / '真测试集A'
KEYS = Path.home() / '.mp-test-keys' / 'relays.json'
MARKER = '[REDACTED]'
JSON_STRING = re.compile(rb'"(?:[^"\\]|\\.)*"', re.DOTALL)

class PullError(Exception):
    pass

def fail(message):
    raise PullError(message)

def private_dir(path):
    # Do not follow an existing symlink at any component of the private tree.
    chain = []
    cursor = path
    while cursor != Path.home():
        chain.append(cursor)
        if cursor.parent == cursor:
            fail('private_directory_invalid')
        cursor = cursor.parent
    for item in reversed(chain):
        try:
            item.mkdir(mode=0o700)
        except FileExistsError:
            pass
        if item.is_symlink() or not item.is_dir():
            fail('private_directory_invalid')
        os.chmod(item, 0o700)

def read_json(path, code):
    try:
        if path.is_symlink() or not path.is_file():
            fail(code)
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, UnicodeError, ValueError):
        fail(code)

def component(value):
    return (isinstance(value, str) and value not in ('', '.', '..')
            and value == value.strip() and len(value.encode('utf-8')) <= 255
            and not any(c in value for c in '/\\:')
            and not any(ord(c) < 32 or ord(c) == 127 for c in value))

def stop(signum, frame):
    raise PullError('interrupted')

stage = None
raw = None
published = None
keys = []
patterns = []
redactions = 0

def redact(data):
    global redactions
    # Decode each JSON string token, so mixed \\uXXXX, escaped slashes, quotes,
    # and backslashes are handled, not just json.dumps' preferred spelling.
    def token(match):
        global redactions
        try:
            value = json.loads(match.group().decode('utf-8'))
        except (UnicodeError, ValueError):
            return match.group()
        changed = False
        for key in keys:
            count = value.count(key)
            if count:
                value = value.replace(key, MARKER)
                redactions += count
                changed = True
        return json.dumps(value, ensure_ascii=True).encode('ascii') if changed else match.group()
    data = JSON_STRING.sub(token, data)
    for pattern in patterns:
        count = data.count(pattern)
        if count:
            data = data.replace(pattern, MARKER.encode('ascii'))
            redactions += count
    return data

def clean(data):
    # Equivalent to per-value fixed-string quiet grep; never emit matching data.
    if any(pattern in data for pattern in patterns):
        return False
    for match in JSON_STRING.finditer(data):
        try:
            value = json.loads(match.group().decode('utf-8'))
        except (UnicodeError, ValueError):
            continue
        if any(key in value for key in keys):
            return False
    return True

try:
    args = sys.argv[1:]
    if args in (['--help'], ['-h']):
        print('Usage: bash scripts/real-set-a-pull.sh [--floor-slug SLUG]')
        sys.exit(0)
    if args and (len(args) != 2 or args[0] != '--floor-slug'):
        fail('arguments_invalid')
    requested = args[1] if args else None
    if requested is not None and not component(requested):
        fail('floor_slug_invalid')

    entries = read_json(KEYS, 'relay_keys_missing_or_invalid')
    if not isinstance(entries, list) or not entries:
        fail('relay_keys_missing_or_invalid')
    if any(not isinstance(item, dict) or not isinstance(item.get('key'), str)
           or not item['key'] for item in entries):
        fail('relay_keys_missing_or_invalid')
    keys = sorted({item['key'] for item in entries}, key=len, reverse=True)
    # If replacement itself contains a key, a zero-hit result is impossible.
    if any(key in MARKER for key in keys):
        fail('relay_keys_incompatible_with_redaction_marker')
    variants = set()
    for key in keys:
        for encoding in ('utf-8', 'utf-16-le', 'utf-16-be'):
            variants.add(key.encode(encoding))
        for ascii_only in (False, True):
            escaped = json.dumps(key, ensure_ascii=ascii_only)[1:-1]
            variants.add(escaped.encode('utf-8'))
            variants.add(escaped.replace('/', '\\/').encode('utf-8'))
    patterns = sorted(variants, key=len, reverse=True)

    identity = read_json(ROOT / 'device.json', 'verified_identity_missing_or_invalid')
    if (not isinstance(identity, dict) or identity.get('identityVerified') is not True
            or not component(identity.get('floorSlug'))
            or not component(identity.get('profileId'))
            or identity.get('deviceId', DEVICE) != DEVICE):
        fail('verified_identity_missing_or_invalid')
    slug = identity['floorSlug']
    if requested is not None and requested != slug:
        fail('floor_identity_mismatch')
    source = 'Documents/记忆宫殿/floors/' + slug + '/memory/wiki'
    # Private identity is an attestation by the operator who checked the on-device
    # savedProfiles / slug map. Never discover by copying other floors.
    private_dir(ROOT / 'runs')
    stage = Path(tempfile.mkdtemp(prefix='.pull-', dir=ROOT / 'runs'))
    os.chmod(stage, 0o700)
    raw = stage / 'raw'
    raw.mkdir(mode=0o700)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, stop)
    command = ['xcrun', 'devicectl', 'device', 'copy', 'from',
               '--device', DEVICE, '--domain-type', 'appDataContainer',
               '--domain-identifier', BUNDLE, '--source', source,
               '--destination', str(raw / 'wiki'), '--quiet', '--timeout', '180']
    # Tool output may contain remote contents: spool only inside the 0700 tree.
    with (raw / 'device-copy.log').open('wb') as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            returncode = process.wait()
        except BaseException:
            # Stop the complete copy process group before deleting raw data.
            for sig in (signal.SIGINT, signal.SIGTERM):
                signal.signal(sig, signal.SIG_IGN)
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            raise
    log = redact((raw / 'device-copy.log').read_bytes())
    if not clean(log):
        fail('redaction_verification_failed')
    (stage / 'device-copy.log').write_bytes(log)
    os.chmod(stage / 'device-copy.log', 0o600)
    if returncode:
        fail('device_copy_failed_' + str(returncode))
    pulled = raw / 'wiki'
    if pulled.is_symlink() or not pulled.is_dir():
        fail('wiki_missing')
    # Directory copy transfers the complete source, including hidden children;
    # reject links/special files instead of allowing them to escape this floor.
    all_files = []
    for directory, dirs, files in os.walk(pulled, followlinks=False):
        base = Path(directory)
        for name in dirs + files:
            path = base / name
            mode = path.lstat().st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                fail('wiki_links_or_special_files_rejected')
            if not clean(os.fsencode(name)):
                fail('sensitive_filename_rejected')
        all_files.extend(base / name for name in files)
    if not all_files:
        fail('wiki_empty')
    wiki = stage / 'wiki'
    wiki.mkdir(mode=0o700)
    for directory, dirs, files in os.walk(pulled, followlinks=False):
        relative = Path(directory).relative_to(pulled)
        target = wiki / relative
        target.mkdir(mode=0o700, parents=True, exist_ok=True)
        for name in files:
            data = redact((Path(directory) / name).read_bytes())
            if not clean(data):
                fail('redaction_verification_failed')
            dest = target / name
            dest.write_bytes(data)
            os.chmod(dest, 0o600)
    # Reopen every final byte stream and path for the independent zero-hit gate.
    for path in wiki.rglob('*'):
        if not clean(os.fsencode(str(path.relative_to(wiki)))):
            fail('redaction_verification_failed')
        if path.is_file() and not clean(path.read_bytes()):
            fail('redaction_verification_failed')

    records = sum(1 for p in (wiki / '.runs').glob('*.md') if p.is_file())
    directories = bodies = tasks = 0
    for path in (wiki / '.proposals').rglob('*.json'):
        if path.name == 'task.json':
            tasks += 1
            continue
        proposal = read_json(path, 'proposal_json_invalid')
        if not isinstance(proposal, dict) or not isinstance(proposal.get('items'), list):
            fail('proposal_json_invalid')
        changes = [item.get('change') for item in proposal['items'] if isinstance(item, dict)]
        has_direction = any(isinstance(change, dict) and 'direction' in change for change in changes)
        has_body = any(isinstance(change, dict) and any(k != 'direction' for k in change) for change in changes)
        directories += int(has_direction)
        bodies += int(has_body)
    markdown = sum(1 for p in wiki.rglob('*.md')
                   if p.is_file() and not any(part.startswith('.') for part in p.relative_to(wiki).parts))
    stamp = datetime.datetime.now().strftime('%Y-%m-%d-%H%M')
    destination = ROOT / 'runs' / stamp
    # Exclusive mkdir: concurrent or same-minute pulls fail, never merge/replace.
    try:
        destination.mkdir(mode=0o700)
    except FileExistsError:
        fail('snapshot_minute_already_exists')
    published = destination
    os.rename(wiki, destination / 'wiki')
    os.rename(stage / 'device-copy.log', destination / 'device-copy.log')
    # Only fixed labels, numbers and the allowed result directory are printed.
    output_path = str(destination / 'wiki')
    if not clean(os.fsencode(output_path)):
        fail('sensitive_output_path_rejected')
    print('records=' + str(records))
    print('directory_proposals=' + str(directories))
    print('body_proposals=' + str(bodies))
    print('tasks=' + str(tasks))
    print('wiki_md=' + str(markdown))
    print('redactions=' + str(redactions))
    print('secret_hits=0')
    print('result=' + output_path)
except (PullError, OSError, UnicodeError, ValueError, subprocess.SubprocessError) as error:
    # Never print exception repr: paths, subprocess diagnostics and JSON excerpts
    # may be private. The sanitized copy error is retained as a private file.
    code = str(error) if isinstance(error, PullError) else 'local_operation_failed'
    print('error=' + code, file=sys.stderr)
    if stage is not None and (stage / 'device-copy.log').is_file():
        path = str(stage / 'device-copy.log')
        if clean(os.fsencode(path)):
            print('error_log=' + path, file=sys.stderr)
    if published is not None:
        shutil.rmtree(published, ignore_errors=True)
    sys.exit(1)
finally:
    if raw is not None:
        shutil.rmtree(raw, ignore_errors=True)
    if stage is not None:
        # Retain only the already-sanitized error log on failure.
        if (stage / 'wiki').exists():
            shutil.rmtree(stage / 'wiki', ignore_errors=True)
        if stage.exists() and not any(stage.iterdir()):
            stage.rmdir()
PY
