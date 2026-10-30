#!/usr/bin/env python3
"""Wokintosh protocol-v1 collector. Python 3.10+, macOS/Linux, stdlib only."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone, timedelta

MAX_LOG_BYTES = 2 * 1024 * 1024
STALE_SECONDS = 1800
MARKER = 'wokintosh-observer'
CACHE_VERSION = 2
MAX_CACHE_BYTES = 1024 * 1024
MAX_CACHE_ENTRIES = 512
SCAN_GAP = {'_wokintosh_scan_gap': True}
SESSION_FIELDS = ('id', 'provider', 'title', 'project', 'state', 'updatedAt', 'activity', 'parentId')
STATES = {'working', 'needsAttention', 'idle', 'finished', 'unknown'}
HOOK_EVENT_FIELDS = ('hook_event_name', 'session_id', 'sessionId', 'agent_id', 'tool_name',
                     'call_id', 'tool_use_id', 'notification_type', '_observedAt')
MAX_PENDING_INPUTS = 128
MAX_HOOK_EVENTS = 64


def stamp(value):
    return value.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')


def parse_time(value, fallback):
    try:
        if isinstance(value, (int, float)):
            return datetime.fromtimestamp(value / 1000 if value > 10**11 else value, timezone.utc)
        return datetime.fromisoformat(str(value).replace('Z', '+00:00')).astimezone(timezone.utc)
    except (ValueError, TypeError, OverflowError, OSError):
        return fallback


def clean(value, limit=100):
    return ' '.join(str(value or '').split())[:limit]


def records(path):
    """Read bounded head/tail data; ignore partial or corrupt JSONL records."""
    try:
        with path.open('rb') as stream:
            size = path.stat().st_size
            if size <= MAX_LOG_BYTES:
                chunks = [stream.read(MAX_LOG_BYTES)]
            else:
                chunks = [stream.read(65536)]
                stream.seek(max(0, size - MAX_LOG_BYTES + 65536))
                tail = stream.read(MAX_LOG_BYTES - 65536)
                chunks.append(tail.partition(b'\n')[2])  # discard partial tail record, bounded
        for index, chunk in enumerate(chunks):
            if index:
                yield SCAN_GAP
            for line in chunk.splitlines():
                try:
                    item = json.loads(line)
                    if isinstance(item, dict):
                        yield item
                except (ValueError, UnicodeDecodeError):
                    continue
    except (OSError, ValueError):
        return


def base_session(identity, provider, cwd, updated, title=None, parent=None):
    project = Path(cwd).name if cwd else 'Untitled project'
    return {'id': clean(identity, 180), 'provider': provider,
            'title': clean(title or f'{project} · {str(identity)[:6]}', 90),
            'project': clean(project, 90), 'state': 'unknown',
            'updatedAt': stamp(updated), 'activity': '', 'parentId': parent}


def finalize(session, now):
    if session and session['state'] == 'working':
        updated = parse_time(session['updatedAt'], now)
        if (now - updated).total_seconds() > STALE_SECONDS:
            session['state'] = 'unknown'
            session['activity'] = 'No recent lifecycle signal'
    return session


def read_codex(path, now, title_index=None):
    session = None
    pending_input = {}
    unmatched_input = None
    lifecycle_seen = False
    last_time = now
    for item in records(path):
        if item is SCAN_GAP:
            if session:
                session.update(state='unknown', activity='Lifecycle outside bounded scan')
            pending_input.clear()
            unmatched_input = None
            lifecycle_seen = False
            continue
        last_time = parse_time(item.get('timestamp'), last_time)
        payload = item.get('payload') or {}
        if not isinstance(payload, dict):
            continue
        kind = item.get('type')
        if kind == 'session_meta':
            identity = payload.get('id') or payload.get('session_id')
            if not isinstance(identity, str) or not identity:
                continue
            title = (title_index or {}).get(identity) or payload.get('title') or payload.get('thread_name')
            source = payload.get('source')
            parent = None
            if isinstance(source, dict):
                sub = source.get('subagent', {})
                if isinstance(sub, dict):
                    spawn = sub.get('thread_spawn', sub)
                    if isinstance(spawn, dict):
                        parent = spawn.get('parent_thread_id')
            session = base_session(identity, 'codex', payload.get('cwd', ''), last_time, title, parent)
        elif session:
            event = payload.get('type')
            if kind == 'event_msg':
                transitions = {'task_started': ('working', 'Working'),
                               'task_complete': ('finished', 'Turn completed'),
                               'turn_aborted': ('idle', 'Interrupted'),
                               'approval_request': ('needsAttention', 'Approval needed'),
                               'request_user_input': ('needsAttention', 'Input needed')}
                if event in transitions:
                    lifecycle_seen = True
                    session['state'], session['activity'] = transitions[event]
                    if event in ('task_started', 'task_complete', 'turn_aborted'):
                        pending_input.clear()
                        unmatched_input = None
                    elif event == 'request_user_input':
                        call_id = payload.get('call_id')
                        if isinstance(call_id, str) and call_id:
                            pending_input[call_id] = stamp(last_time)
                        else:
                            unmatched_input = stamp(last_time)
                elif (event in ('agent_reasoning', 'agent_message') and not lifecycle_seen
                      and session['state'] != 'needsAttention' and not pending_input and not unmatched_input):
                    session['state'], session['activity'] = 'working', 'Working'
            elif kind == 'response_item':
                name = str(payload.get('name', ''))
                if event in ('function_call', 'custom_tool_call') and name.endswith('request_user_input'):
                    session['state'], session['activity'] = 'needsAttention', 'Input needed'
                    call_id = payload.get('call_id')
                    if isinstance(call_id, str) and call_id:
                        pending_input[call_id] = stamp(last_time)
                    else:
                        unmatched_input = stamp(last_time)
                elif event in ('function_call_output', 'custom_tool_call_output'):
                    call_id = payload.get('call_id')
                    if isinstance(call_id, str) and call_id in pending_input:
                        del pending_input[call_id]
                        if not pending_input and not unmatched_input:
                            session['state'], session['activity'] = 'working', 'Working'
                    elif not lifecycle_seen and session['state'] != 'needsAttention':
                        session['state'], session['activity'] = 'working', 'Working'
                elif (event in ('function_call', 'custom_tool_call', 'reasoning') or
                      (event == 'message' and payload.get('role') == 'assistant')):
                    if not lifecycle_seen and session['state'] != 'needsAttention':
                        session['state'], session['activity'] = 'working', 'Working'
            session['updatedAt'] = stamp(last_time)
    if session:
        set_pending_input(session, pending_input, unmatched_input)
    return finalize(session, now)


def read_claude(path, now):
    session = None
    title = None
    last_time = now
    for item in records(path):
        if item is SCAN_GAP:
            if session:
                session.update(state='unknown', activity='Lifecycle outside bounded scan')
            continue
        if item.get('type') == 'custom-title':
            title = clean(item.get('customTitle'), 90)
            if session and title:
                session['title'] = title
        identity = item.get('sessionId')
        if not isinstance(identity, str) or not identity:
            continue
        last_time = parse_time(item.get('timestamp'), last_time)
        parent = None
        if 'subagents' in path.parts:
            parent = identity
            identity = identity + ':' + path.stem
        if session is None:
            session = base_session(identity, 'claude', item.get('cwd', ''), last_time, title, parent)
        if item.get('cwd'):
            session['project'] = clean(Path(item['cwd']).name, 90)
        kind = item.get('type')
        message = item.get('message') or {}
        if not isinstance(message, dict):
            message = {}
        if kind == 'user':
            session['state'], session['activity'] = 'working', 'Working'
        elif kind == 'assistant':
            if message.get('stop_reason') == 'end_turn':
                session['state'], session['activity'] = 'finished', 'Turn completed'
            else:
                session['state'], session['activity'] = 'working', 'Working'
        elif kind == 'system' and item.get('subtype') == 'turn_duration':
            session['state'], session['activity'] = 'finished', 'Turn completed'
        session['updatedAt'] = stamp(last_time)
    return finalize(session, now)


def hook_identity(provider, event):
    identity = event.get('session_id') or event.get('sessionId')
    if not isinstance(identity, str) or not identity:
        return None
    child = event.get('agent_id')
    if isinstance(child, str) and child:
        if child == identity:
            return None
        if provider == 'claude':
            child = identity + ':' + (child if child.startswith('agent-') else 'agent-' + child)
        return child, identity
    if event.get('hook_event_name') in ('SubagentStart', 'SubagentStop'):
        return None  # Internal helpers can fire these without a usable child identity.
    return identity, None


def pending_input_state(session):
    value = session.get('_pendingInput')
    if isinstance(value, dict):
        return dict(value.get('calls', {})), value.get('unknownSince')
    if session.get('state') == 'needsAttention' and session.get('activity') == 'Input needed':
        return {}, session['updatedAt']  # Legacy summaries have no matching-call evidence.
    return {}, None


def set_pending_input(session, calls, unknown_since):
    if len(calls) > MAX_PENDING_INPUTS:
        unknown_since = unknown_since or min(calls.values())
    calls = dict(list(calls.items())[:MAX_PENDING_INPUTS])
    if calls or unknown_since:
        session['_pendingInput'] = {'calls': calls, 'unknownSince': unknown_since}
    else:
        session.pop('_pendingInput', None)


def apply_hook_state(session, event, now):
    result = dict(session)
    target = hook_identity(session.get('provider'), event)
    name = event.get('hook_event_name', '')
    if name in ('SubagentStart', 'SubagentStop') and target is None:
        return result
    if target and target[1] and result.get('id') != clean(target[0], 180):
        return result
    calls, unknown_since = pending_input_state(result)
    call_id = event.get('tool_use_id') or event.get('call_id')
    progression = name in ('UserPromptSubmit', 'SessionStart', 'SessionEnd', 'Stop',
                           'Interrupt', 'SubagentStart', 'SubagentStop')
    if progression:
        calls = {key: at for key, at in calls.items() if parse_time(at, now) > now}
        if unknown_since and parse_time(unknown_since, now) <= now:
            unknown_since = None
    elif name == 'PostToolUse' and isinstance(call_id, str) and call_id in calls:
        if parse_time(calls[call_id], now) <= now:
            del calls[call_id]
    if name == 'PreToolUse' and str(event.get('tool_name', '')).endswith('request_user_input'):
        if isinstance(call_id, str) and call_id:
            calls[call_id] = stamp(now)
        else:
            unknown_since = stamp(now)
    state, activity = result.get('state', 'unknown'), result.get('activity', '')
    if name in ('UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'SubagentStart'):
        state, activity = 'working', 'Working'
    elif name == 'PermissionRequest':
        state, activity = 'needsAttention', 'Approval needed'
    elif name == 'Notification' and event.get('notification_type') in ('permission_prompt', 'idle_prompt', 'elicitation_dialog'):
        state, activity = 'needsAttention', 'Input needed'
    elif name in ('Stop', 'SessionEnd', 'SubagentStop'):
        state, activity = 'finished', 'Turn completed'
    elif name in ('StopFailure',):
        state, activity = 'needsAttention', 'Agent error'
    elif name in ('Interrupt', 'SessionStart'):
        state, activity = 'idle', 'Waiting for a task'
    if calls or unknown_since:
        state, activity = 'needsAttention', 'Input needed'
    set_pending_input(result, calls, unknown_since)
    result.update(state=state, activity=activity, updatedAt=stamp(now), source='hook')
    return result


def state_directory(home=None):
    home = home or Path.home()
    if platform.system() == 'Darwin':
        return home / 'Library/Application Support/Wokintosh/collector'
    return Path(os.environ.get('XDG_STATE_HOME', str(home / '.local/state'))) / 'wokintosh'


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.wokintosh-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, separators=(',', ':'))
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def host_identity(state_dir):
    path = state_dir / 'host-id'
    state_dir.mkdir(parents=True, exist_ok=True)
    try:
        return path.read_text().strip()
    except OSError:
        identity = str(uuid.uuid4())
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as stream:
                stream.write(identity)
            return identity
        except FileExistsError:
            return path.read_text().strip()


def command_output(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=2, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return ''


def system_stats(home, state_dir):
    usage = shutil.disk_usage(home)
    result = {'diskFreeBytes': usage.free, 'diskTotalBytes': usage.total}
    if platform.system() == 'Linux':
        try:
            mem = {}
            for line in Path('/proc/meminfo').read_text().splitlines():
                key, value = line.split(':', 1)
                mem[key] = int(value.strip().split()[0]) * 1024
            result.update(memoryTotalBytes=mem['MemTotal'], memoryUsedBytes=mem['MemTotal']-mem['MemAvailable'])
            cpu = [int(v) for v in Path('/proc/stat').read_text().splitlines()[0].split()[1:]]
            total, idle = sum(cpu[:8]), cpu[3] + (cpu[4] if len(cpu) > 4 else 0)
            previous_path = state_dir / 'cpu.json'
            try:
                previous = json.loads(previous_path.read_text())
                delta = total - previous['total']
                if delta > 0:
                    result['cpuPercent'] = max(0, min(100, 100*(1-(idle-previous['idle'])/delta)))
            except (OSError, ValueError, KeyError, TypeError):
                pass
            atomic_json(previous_path, {'total': total, 'idle': idle})
        except (OSError, ValueError, KeyError):
            pass
    elif platform.system() == 'Darwin':
        try:
            total = int(command_output(['/usr/sbin/sysctl', '-n', 'hw.memsize']).strip())
            output = command_output(['/usr/bin/vm_stat'])
            import re
            page_match = re.search(r'page size of (\d+) bytes', output)
            page_size = int(page_match.group(1)) if page_match else 16384
            pages = {}
            for line in output.splitlines()[1:]:
                key, _, value = line.partition(':')
                if value.strip().rstrip('.').isdigit():
                    pages[key] = int(value.strip().rstrip('.'))
            free = (pages.get('Pages free', 0)+pages.get('Pages inactive', 0)+pages.get('Pages speculative', 0))*page_size
            result.update(memoryTotalBytes=total, memoryUsedBytes=max(0,total-free))
            values = command_output(['/bin/ps', '-A', '-o', '%cpu=']).split()
            result['cpuPercent'] = min(100, sum(float(x) for x in values)/max(1, os.cpu_count() or 1))
        except (ValueError, OSError):
            pass
    return result


def valid_session(value, provider=None):
    """Validate persisted summaries; whitelist fields so cache contents cannot add bodies."""
    if not isinstance(value, dict) or value.get('provider') not in ('codex', 'claude'):
        return None
    if provider and value['provider'] != provider:
        return None
    if not isinstance(value.get('state'), str) or value['state'] not in STATES:
        return None
    for field in SESSION_FIELDS[:-1]:
        if not isinstance(value.get(field), str) or len(value[field]) > 180:
            return None
    if not value['id'] or not isinstance(value.get('parentId'), (str, type(None))):
        return None
    if isinstance(value.get('parentId'), str) and len(value['parentId']) > 180:
        return None
    try:
        datetime.fromisoformat(value['updatedAt'].replace('Z', '+00:00'))
    except ValueError:
        return None
    result = {field: value.get(field) for field in SESSION_FIELDS}
    pending = value.get('_pendingInput')
    if pending is not None:
        if not isinstance(pending, dict) or not isinstance(pending.get('calls'), dict):
            return None
        calls, unknown = pending['calls'], pending.get('unknownSince')
        if len(calls) > MAX_PENDING_INPUTS or any(
                not isinstance(key, str) or len(key) > 180 or not isinstance(at, str) or len(at) > 50
                for key, at in calls.items()):
            return None
        if unknown is not None and (not isinstance(unknown, str) or len(unknown) > 50):
            return None
        set_pending_input(result, calls, unknown)
    events = value.get('_hookEvents')
    if events is not None:
        if not isinstance(events, list) or len(events) > MAX_HOOK_EVENTS:
            return None
        if any(not isinstance(event, dict) or not isinstance(event.get('_observedAt'), str) or
               any(not isinstance(item, str) or len(item) > 180 for item in event.values())
               for event in events):
            return None
        result['_hookEvents'] = [{key: event[key] for key in HOOK_EVENT_FIELDS if key in event}
                                 for event in events]
    return result


def load_parse_cache(path):
    try:
        with path.open('rb') as stream:
            content = stream.read(MAX_CACHE_BYTES + 1)
        if len(content) > MAX_CACHE_BYTES:
            return {}
        data = json.loads(content)
        if (not isinstance(data, dict) or data.get('version') != CACHE_VERSION or
                not isinstance(data.get('entries'), dict) or len(data['entries']) > MAX_CACHE_ENTRIES):
            return {}
        return data['entries']
    except (OSError, ValueError):
        return {}


def save_parse_cache(path, entries):
    # Store only this poll's bounded discovery set, dropping deleted/old transcript entries.
    bounded = {}
    size = 64
    for key, entry in list(entries.items())[:MAX_CACHE_ENTRIES]:
        size += len(json.dumps({key: entry}, separators=(',', ':')).encode())
        if size > MAX_CACHE_BYTES - 1024:
            break
        bounded[key] = entry
    try:
        atomic_json(path, {'version': CACHE_VERSION, 'entries': bounded})
    except OSError:
        pass  # A cache write failure must not hide otherwise readable sessions.


def make_snapshot(home, state_dir, now, host_name=None):
    state_dir.mkdir(parents=True, exist_ok=True)
    title_index = {}
    for item in records(home / '.codex/session_index.jsonl'):
        if isinstance(item.get('id'), str):
            title_index[item['id']] = clean(item.get('thread_name') or item.get('title'), 90)
    sessions = {}
    errors = []
    cached = load_parse_cache(state_dir / 'parse-cache.json')
    next_cache = {}
    title_revision = hashlib.sha256(json.dumps(title_index, sort_keys=True).encode()).hexdigest()
    for provider, directory, parser in (
        ('codex', home / '.codex/sessions', lambda p: read_codex(p, now, title_index)),
        ('claude', home / '.claude/projects', lambda p: read_claude(p, now))):
        if not directory.is_dir():
            continue
        try:
            paths = sorted(directory.rglob('*.jsonl'), key=lambda p:p.stat().st_mtime, reverse=True)[:256]
        except OSError:
            errors.append(f'{provider}: session directory unavailable')
            continue
        for path in paths:
            try:
                info = path.stat()
                if info.st_mtime < (now-timedelta(days=7)).timestamp():
                    continue
                key_hash = hashlib.sha256((provider + '\0' + str(path)).encode()).hexdigest()
                fingerprint = [info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_ino,
                               title_revision if provider == 'codex' else '']
                entry = cached.get(key_hash)
                if isinstance(entry, dict) and 'session' in entry and entry.get('fingerprint') == fingerprint:
                    session = valid_session(entry.get('session'), provider)
                    # A cached null is a deliberate negative parse result.
                    if session is None and entry.get('session') is not None:
                        session = parser(path)
                else:
                    session = parser(path)
                next_cache[key_hash] = {'fingerprint': fingerprint, 'session': session}
                session = finalize(dict(session), now) if session else None
                if session:
                    key = (provider, session['id'])
                    if key not in sessions or session['updatedAt'] > sessions[key]['updatedAt']:
                        sessions[key] = session
            except (OSError, ValueError, TypeError, KeyError):
                continue
    save_parse_cache(state_dir / 'parse-cache.json', next_cache)
    for path in (state_dir / 'hooks').glob('*.json'):
        try:
            entry = json.loads(path.read_text())
            entry = valid_session(entry)
            if entry is None:
                continue
            provider, identity = entry['provider'], entry['id']
            key = (provider, identity)
            if key not in sessions:
                sessions[key] = finalize(entry, now)
            elif entry.get('_hookEvents'):
                # Replay bounded, body-free observations onto transcript state. A later unrelated
                # hook must not erase evidence of a matching input completion between polls.
                current = sessions[key]
                calls, unknown = pending_input_state(current)
                boundary = min(list(calls.values()) + ([unknown] if unknown else []) or [current['updatedAt']])
                for event in entry['_hookEvents']:
                    observed = parse_time(event['_observedAt'], now)
                    if observed >= parse_time(boundary, now):
                        previous_time = current['updatedAt']
                        current = apply_hook_state(current, event, observed)
                        if parse_time(previous_time, now) > observed:
                            current['updatedAt'] = previous_time
                sessions[key] = finalize(current, now)
            elif parse_time(entry['updatedAt'], now) >= parse_time(sessions[key]['updatedAt'], now):
                # Legacy hook summaries cannot prove that a transcript input wait was answered.
                calls, unknown = pending_input_state(sessions[key])
                if not calls and not unknown:
                    sessions[key].update({field: entry[field] for field in ('state', 'activity', 'updatedAt')})
                    finalize(sessions[key], now)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    recent = [{field: s[field] for field in SESSION_FIELDS} for s in sessions.values()
              if (now-parse_time(s['updatedAt'], now)).total_seconds() < 7*86400]
    return {'schemaVersion': 1, 'host': {'id': host_identity(state_dir), 'name': clean(host_name or socket.gethostname().split('.')[0]), 'platform': 'macos' if platform.system() == 'Darwin' else platform.system().lower()},
            'generatedAt': stamp(now), 'sessions': recent, 'system': system_stats(home, state_dir), 'errors': errors}


def hook_install_config(provider, command, existing):
    result = copy.deepcopy(existing)
    hooks = result.setdefault('hooks', {})
    names = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest', 'Stop', 'SubagentStart', 'SubagentStop']
    if provider == 'claude':
        names += ['Notification', 'SessionEnd', 'StopFailure', 'PostToolUseFailure']
    else:
        names += ['Interrupt']
    for name in names:
        entries = hooks.setdefault(name, [])
        if not any(MARKER in str(h.get('command', '')) for e in entries for h in e.get('hooks', [])):
            entries.append({'hooks': [{'type': 'command', 'command': command+' # '+MARKER, 'timeout': 3}]})
    return result


def ingest_hook(provider, event, home, state_dir, now):
    target = hook_identity(provider, event)
    if target is None:
        return
    identity, parent = target
    key = hashlib.sha256((provider+'\0'+identity).encode()).hexdigest()
    path = state_dir / 'hooks' / (key+'.json')
    try:
        session = valid_session(json.loads(path.read_text()), provider)
    except (OSError, ValueError):
        session = None
    if session is None:
        session = base_session(identity, provider, event.get('cwd', ''), now, event.get('session_title'), parent)
    observation = {key: event[key] for key in HOOK_EVENT_FIELDS
                   if key in event and isinstance(event[key], str) and len(event[key]) <= 180}
    observation['_observedAt'] = stamp(now)
    result = apply_hook_state(session, event, now)
    result['_hookEvents'] = (session.get('_hookEvents', []) + [observation])[-MAX_HOOK_EVENTS:]
    atomic_json(path, result)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, default=Path.home())
    parser.add_argument('--state-dir', type=Path)
    sub = parser.add_subparsers(dest='command', required=True)
    snapshot = sub.add_parser('snapshot', help='Print protocol-v1 JSON snapshot')
    snapshot.add_argument('--json', action='store_true', help='Compatibility; JSON is always emitted')
    snapshot.add_argument('--host-name')
    hook = sub.add_parser('hook', help='Observe a lifecycle hook from stdin; always return neutral JSON')
    hook.add_argument('--provider', choices=['codex', 'claude'], required=True)
    install = sub.add_parser('install-hooks', help='Explicitly merge observational hooks, backing up settings')
    install.add_argument('--provider', choices=['codex', 'claude'], required=True)
    install.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    state_dir = args.state_dir or state_directory(args.home)
    now = datetime.now(timezone.utc)
    if args.command == 'snapshot':
        print(json.dumps(make_snapshot(args.home, state_dir, now, args.host_name), separators=(',', ':')))
    elif args.command == 'hook':
        try:
            event = json.loads(sys.stdin.buffer.read(1024*1024))
            if isinstance(event, dict):
                ingest_hook(args.provider, event, args.home, state_dir, now)
        except (OSError, ValueError, TypeError) as error:
            print(f'Wokintosh observer: {type(error).__name__}', file=sys.stderr)
        print('{}')  # No approval decision, continuation instruction or model context.
    else:
        path = args.home / ('.claude/settings.json' if args.provider == 'claude' else '.codex/hooks.json')
        existing = json.loads(path.read_text()) if path.exists() else {}
        if not isinstance(existing, dict):
            parser.error('Existing hook settings must be a JSON object')
        command = shlex.join([sys.executable, str(Path(__file__).resolve()), '--home', str(args.home),
                              '--state-dir', str(state_dir), 'hook', '--provider', args.provider])
        result = hook_install_config(args.provider, command, existing)
        if args.dry_run:
            print(json.dumps(result, indent=2))
        else:
            if path.exists():
                backup = path.with_name(path.name+'.wokintosh-backup-'+str(time.time_ns()))
                shutil.copy2(path, backup)
            atomic_json(path, result)
            print(f'Installed observational hooks in {path}. Existing entries preserved. Restart sessions to load hooks.')


if __name__ == '__main__':
    main()
