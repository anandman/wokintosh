#!/usr/bin/env python3
"""Wokintosh protocol-v1 collector. Python 3.10+, macOS/Linux, stdlib only."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import platform
import re
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
CACHE_VERSION = 3
MAX_CACHE_BYTES = 1024 * 1024
MAX_CACHE_ENTRIES = 512
SCAN_GAP = {'_wokintosh_scan_gap': True}
SESSION_FIELDS = ('id', 'provider', 'title', 'project', 'state', 'updatedAt', 'activity', 'parentId', 'isHelper')
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
            'updatedAt': stamp(updated), 'activity': '',
            'parentId': (clean(parent, 180) or None) if isinstance(parent, str) else None,
            'isHelper': isinstance(parent, str) and bool(clean(parent, 180))}


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
            parent = payload.get('parent_thread_id')
            if isinstance(source, dict):
                sub = source.get('subagent', {})
                if isinstance(sub, dict):
                    spawn = sub.get('thread_spawn', sub)
                    if isinstance(spawn, dict):
                        parent = parent if isinstance(parent, str) and parent else spawn.get('parent_thread_id')
            metadata = base_session(identity, 'codex', payload.get('cwd', ''), last_time, title, parent)
            metadata['isHelper'] = metadata['isHelper'] or (isinstance(source, dict) and 'subagent' in source)
            if session and session['id'] == metadata['id']:
                for field in ('title', 'project', 'parentId', 'isHelper'):
                    session[field] = metadata[field]
            else:
                session = metadata
        elif session:
            observed_activity = False
            event = payload.get('type')
            if kind == 'event_msg':
                transitions = {'task_started': ('working', 'Working'),
                               'task_complete': ('finished', 'Turn completed'),
                               'turn_aborted': ('idle', 'Interrupted'),
                               'approval_request': ('needsAttention', 'Approval needed'),
                               'request_user_input': ('needsAttention', 'Input needed')}
                if event in transitions:
                    observed_activity = True
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
                if event in ('agent_reasoning', 'agent_message') and session['state'] == 'working':
                    observed_activity = True
            elif kind == 'response_item':
                name = str(payload.get('name', ''))
                if event in ('function_call', 'custom_tool_call') and name.endswith('request_user_input'):
                    observed_activity = True
                    session['state'], session['activity'] = 'needsAttention', 'Input needed'
                    call_id = payload.get('call_id')
                    if isinstance(call_id, str) and call_id:
                        pending_input[call_id] = stamp(last_time)
                    else:
                        unmatched_input = stamp(last_time)
                elif event in ('function_call_output', 'custom_tool_call_output'):
                    call_id = payload.get('call_id')
                    if isinstance(call_id, str) and call_id in pending_input:
                        observed_activity = True
                        del pending_input[call_id]
                        if not pending_input and not unmatched_input:
                            session['state'], session['activity'] = 'working', 'Working'
                    elif not lifecycle_seen and session['state'] != 'needsAttention':
                        session['state'], session['activity'] = 'working', 'Working'
                elif (event in ('function_call', 'custom_tool_call', 'reasoning') or
                      (event == 'message' and payload.get('role') == 'assistant')):
                    if not lifecycle_seen and session['state'] != 'needsAttention':
                        session['state'], session['activity'] = 'working', 'Working'
                if (event in ('function_call', 'custom_tool_call', 'function_call_output',
                              'custom_tool_call_output', 'reasoning') or
                        (event == 'message' and payload.get('role') == 'assistant')) and session['state'] == 'working':
                    observed_activity = True
            if observed_activity:
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
        if kind in ('user', 'assistant') or (kind == 'system' and item.get('subtype') == 'turn_duration'):
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
    supported = {'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
                 'PostToolUseFailure', 'PermissionRequest', 'Notification', 'Stop',
                 'SessionEnd', 'SubagentStart', 'SubagentStop', 'StopFailure', 'Interrupt'}
    if name not in supported or (name == 'Notification' and event.get('notification_type') not in
                                ('permission_prompt', 'idle_prompt', 'elicitation_dialog')):
        return result
    # Starting/resuming a process is not fresh task activity. Preserve known lifecycle evidence.
    if name == 'SessionStart':
        if result.get('state') == 'unknown':
            result.update(state='idle', activity='Waiting for a task')
        return result
    if target and target[1]:
        result.update(parentId=clean(target[1], 180), isHelper=True)
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


def disk_metrics(path):
    try:
        usage = shutil.disk_usage(path)
        return {'freeBytes': usage.free, 'totalBytes': usage.total}
    except OSError:
        return {'freeBytes': None, 'totalBytes': None}


def mounted_drives():
    """Root plus 64 user volumes; use bounded df measurements for added mounts."""
    mounts = {}
    system = platform.system()
    for line in command_output(['df', '-P', '-k']).splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) != 6 or not fields[1].isdigit():
            continue
        source, mount = fields[0], fields[5]
        mount = re.sub(r'\\([0-7]{3})', lambda match: chr(int(match[1], 8)), mount)
        if not mount.startswith('/') or mount == '/':
            continue
        if system == 'Darwin':
            if not mount.startswith('/Volumes/'):
                continue
        elif system == 'Linux':
            # Real devices and network shares only. Container /etc file binds and
            # pseudo/system mounts are not useful disk selections.
            excluded = ('/dev', '/proc', '/sys', '/etc', '/boot', '/snap',
                        '/var/lib/docker', '/var/lib/containerd')
            if any(mount == prefix or mount.startswith(prefix + '/') for prefix in excluded):
                continue
            if (mount == '/run' or mount.startswith('/run/')) and not mount.startswith('/run/media/'):
                continue
            if not (source.startswith('/dev/') or ':' in source or source.startswith('//')):
                continue
        else:
            continue
        try:
            total, free = int(fields[1]) * 1024, int(fields[3]) * 1024
            if total < 0 or free < 0:
                raise ValueError('negative disk measurement')
            metrics = {'freeBytes': free, 'totalBytes': total}
        except ValueError:
            metrics = {'freeBytes': None, 'totalBytes': None}
        mounts[mount] = metrics
    # df already obtains filesystem statistics in a process with a two-second
    # timeout. Restatting each user mount here can block indefinitely on stale
    # network volumes and prevent otherwise healthy session snapshots.
    return [{'id': '/', 'name': 'System', 'mountPoint': '/', **disk_metrics('/')}]+[
        {'id': mount, 'name': Path(mount).name, 'mountPoint': mount, **mounts[mount]}
        for mount in sorted(mounts)[:64]]


def macos_cpu_ticks():
    """Read aggregate Mach host CPU ticks; percentages require two observations."""
    import ctypes
    try:
        library = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        library.mach_host_self.restype = ctypes.c_uint
        library.host_statistics.argtypes = (ctypes.c_uint, ctypes.c_int, ctypes.c_void_p,
                                            ctypes.POINTER(ctypes.c_uint))
        ticks = (ctypes.c_uint * 4)()
        count = ctypes.c_uint(4)
        if library.host_statistics(library.mach_host_self(), 3, ticks, ctypes.byref(count)) != 0:
            return None
        return sum(ticks), ticks[2]  # CPU_STATE_IDLE in HOST_CPU_LOAD_INFO.
    except (OSError, AttributeError):
        return None


def system_stats(home, state_dir):
    usage = disk_metrics(home)
    result = {'diskFreeBytes': usage['freeBytes'], 'diskTotalBytes': usage['totalBytes'],
              'drives': mounted_drives()}
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
        except (ValueError, OSError):
            pass
        try:
            ticks = macos_cpu_ticks()
            if ticks is not None:
                total_ticks, idle_ticks = ticks
                previous_path = state_dir / 'macos-cpu.json'
                try:
                    previous = json.loads(previous_path.read_text())
                    delta = total_ticks - previous['total']
                    idle_delta = idle_ticks - previous['idle']
                    if delta > 0 and 0 <= idle_delta <= delta:
                        result['cpuPercent'] = 100 * (1 - idle_delta / delta)
                except (OSError, ValueError, KeyError, TypeError):
                    pass
                atomic_json(previous_path, {'total': total_ticks, 'idle': idle_ticks})
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
    for field in SESSION_FIELDS[:-2]:
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
    if 'isHelper' in value and not isinstance(value['isHelper'], bool):
        return None
    result = {field: value.get(field) for field in SESSION_FIELDS}
    result['isHelper'] = value.get('isHelper', False) or bool(value.get('parentId'))
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
                # Fresh parses must satisfy the same protocol contract as cache hits.
                session = valid_session(session, provider)
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


HOOK_LABELS = {
    'SessionStart': 'Started', 'UserPromptSubmit': 'Working', 'PreToolUse': 'Working',
    'PostToolUse': 'Working', 'PermissionRequest': 'Needs permission', 'Stop': 'Done',
    'SubagentStart': 'Helper started', 'SubagentStop': 'Helper done', 'Interrupt': 'Interrupted',
    'Notification': 'Needs input', 'SessionEnd': 'Session ended', 'StopFailure': 'Agent error',
    'PostToolUseFailure': 'Tool error'}


def observer_handler(handler):
    return isinstance(handler, dict) and handler.get('type') == 'command' and MARKER in str(handler.get('command', ''))


def hook_install_config(provider, command, existing):
    result = copy.deepcopy(existing)
    hooks = result.setdefault('hooks', {})
    if not isinstance(hooks, dict):
        raise ValueError('Existing hooks must be an object')
    if provider == 'codex':
        result.setdefault('description', 'Wokintosh status observer hooks')
    observer_command = command + ' # Wokintosh status observer; ' + MARKER
    for name, entries in hooks.items():
        if not isinstance(entries, list):
            continue  # Non-event metadata, including Codex hooks.state, is not an event array.
        for entry in entries:
            handlers = entry.get('hooks', [])
            retained = []
            for handler in handlers:
                if observer_handler(handler):
                    handler.update(command=observer_command,
                                   statusMessage='Wokintosh · ' + HOOK_LABELS.get(name, name))
                    if handler in retained:
                        continue  # Equivalent handlers in this group only; matchers remain independent.
                retained.append(handler)
            entry['hooks'] = retained
    names = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest',
             'Stop', 'SubagentStart', 'SubagentStop']
    names += ['Notification', 'SessionEnd', 'StopFailure', 'PostToolUseFailure'] if provider == 'claude' else ['Interrupt']
    for name in names:
        entries = hooks.setdefault(name, [])
        if not isinstance(entries, list):
            raise ValueError('Existing hook event must be an array: ' + name)
        if not any(observer_handler(h) for e in entries for h in e.get('hooks', [])):
            entries.append({'hooks': [{'type': 'command', 'command': observer_command,
                                      'statusMessage': 'Wokintosh · ' + HOOK_LABELS[name], 'timeout': 3}]})
    return result


def toml_statements(text):
    """Find complete TOML statements without interpreting or rewriting unrelated values.

    Quote/depth tracking prevents apparent headers or comments inside multiline strings
    and arrays from being treated as configuration. Python 3.10 needs no TOML dependency.
    """
    start = index = 0
    quote = None
    depth = 0
    code_end = 0
    while index < len(text):
        char = text[index]
        if quote:
            if quote[0] == '"' and char == '\\':
                index += 2
                code_end = index
                continue
            if text.startswith(quote, index):
                index += len(quote)
                code_end = index
                quote = None
                continue
            index += 1
            code_end = index
            continue
        if char in ('"', "'"):
            quote = char * 3 if text.startswith(char * 3, index) else char
            index += len(quote)
            code_end = index
            continue
        if char == '#':
            newline = text.find('\n', index)
            index = len(text) if newline == -1 else newline
            continue
        if char in '[{':
            depth += 1
        elif char in ']}':
            depth -= 1
            if depth < 0:
                raise ValueError('Malformed TOML configuration; settings were not changed')
        if char == '\n' and depth == 0:
            yield start, index + 1, code_end
            start = index + 1
            code_end = start
        elif not char.isspace():
            code_end = index + 1
        index += 1
    if quote or depth:
        raise ValueError('Incomplete TOML configuration; settings were not changed')
    if start < len(text):
        yield start, len(text), code_end


def toml_string(value):
    value = value.strip()
    if value.startswith("'''") and value.endswith("'''"):
        return value[3:-3].lstrip('\n')
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    if value.startswith('"') and not value.startswith('"""'):
        try:
            return json.loads(value)
        except ValueError:
            pass
    return None


def toml_key_path(value):
    path = []
    pattern = re.compile(r"""\s*("(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z_0-9-]+)\s*(\.|$)""")
    index = 0
    while index < len(value):
        match = pattern.match(value, index)
        if not match:
            return ()
        raw = match.group(1)
        path.append(toml_string(raw) if raw[0] in ('"', "'") else raw)
        index = match.end()
        if not match.group(2):
            break
    return tuple(path)


def toml_hook_sections(text):
    sections = []
    current = {'path': (), 'start': 0, 'fields': {}}
    inline = False
    for start, end, code_end in toml_statements(text):
        code = text[start:code_end].strip()
        if not code:
            continue
        if code.startswith('['):
            current['end'] = start
            sections.append(current)
            # Only simple hook header components are edited; trust keys stay opaque.
            brackets = 2 if code.startswith('[[') else 1
            path = toml_key_path(code[brackets:-brackets].strip())
            if path[:1] == ('hooks',):
                inline = True
            current = {'path': path, 'start': start, 'headerEnd': end, 'fields': {}}
        else:
            if not current['path'] and re.match(r'''\s*(?:hooks|"hooks"|'hooks')\s*\.''', code):
                raise ValueError('Dotted inline-value TOML hooks need manual migration; settings were not changed')
            match = re.match(r'''\s*("(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z_][A-Za-z_0-9]*)\s*=\s*''', text[start:code_end])
            if not match:
                # Unknown/dotted keys remain opaque, but must prohibit deleting this section.
                current['unparsed'] = True
                continue
            raw_key = match.group(1)
            key = toml_string(raw_key) if raw_key[0] in ('"', "'") else raw_key
            if (not current['path'] and (key == 'hooks' or code.startswith('hooks.'))) or (current['path'] == ('hooks',) and key in HOOK_LABELS):
                raise ValueError('Inline-value TOML hooks need manual migration to [[hooks.Event]] tables; settings were not changed')
            value_start = start + match.end()
            current['fields'][key] = (value_start, code_end, text[value_start:code_end])
            if current['path'][:1] == ('hooks',) and key == 'hooks':
                raise ValueError('Inline-value TOML hook handlers need [[hooks.Event.hooks]] tables; settings were not changed')
    current['end'] = len(text)
    sections.append(current)
    return inline, sections


def toml_value(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (int, float)):
        return json.dumps(value, allow_nan=False)
    if isinstance(value, list):
        return '[' + ', '.join(toml_value(x) for x in value) + ']'
    if isinstance(value, dict):
        return '{ ' + ', '.join(json.dumps(k) + ' = ' + toml_value(v) for k, v in value.items()) + ' }'
    raise ValueError('Unsupported hook metadata cannot safely migrate to TOML; settings were not changed')


def split_owned_hooks(existing):
    """Separate only our marked command handlers; leave all other JSON data intact."""
    remaining = copy.deepcopy(existing)
    owned = {'hooks': {}}
    for name, entries in list(remaining.get('hooks', {}).items()):
        if not isinstance(entries, list):
            continue
        retained = []
        for entry in entries:
            own = [h for h in entry.get('hooks', []) if observer_handler(h)]
            other = [h for h in entry.get('hooks', []) if not observer_handler(h)]
            if own:
                group = copy.deepcopy(entry)
                group['hooks'] = own
                owned['hooks'].setdefault(name, []).append(group)
            if other or not own:
                entry['hooks'] = other
                retained.append(entry)
        if retained:
            remaining['hooks'][name] = retained
        else:
            del remaining['hooks'][name]
    if remaining.get('description') == 'Wokintosh status observer hooks':
        remaining.pop('description')
    if not remaining.get('hooks'):
        remaining.pop('hooks', None)
    return owned, remaining


def hook_install_toml(text, command, migrated):
    inline, sections = toml_hook_sections(text)
    if not inline:
        return None
    edits = []
    own_events = set()
    group_ids = {}
    own_groups = {}
    observer_command = command + ' # Wokintosh status observer; ' + MARKER
    for index, section in enumerate(sections):
        path = section['path']
        if len(path) == 2 and path[0] == 'hooks':
            group_ids[path[1]] = section['start']
        if len(path) != 3 or path[0] != 'hooks' or path[2] != 'hooks':
            continue
        fields = section['fields']
        raw_command = fields.get('command', (0, 0, ''))[2]
        value = toml_string(raw_command)
        if value is None and MARKER in raw_command:
            raise ValueError('Unsupported marked TOML command string; settings were not changed')
        if value is None or MARKER not in value or toml_string(fields.get('type', (0, 0, ''))[2]) != 'command':
            continue
        name = path[1]
        group_key = (name, group_ids.get(name))
        previous_handlers = own_groups.setdefault(group_key, [])
        next_path = sections[index + 1]['path'] if index + 1 < len(sections) else ()
        complex_metadata = bool(section.get('unparsed') or
                                set(fields) - {'type', 'command', 'statusMessage', 'timeout'} or
                                next_path[:3] == path)
        signature = {key: field[2].strip() for key, field in fields.items()
                     if key not in ('command', 'statusMessage')}
        if previous_handlers and (complex_metadata or any(item[1] for item in previous_handlers)):
            raise ValueError('Duplicate marked TOML hooks with extra metadata need manual consolidation; settings were not changed')
        if any(item[0] == signature for item in previous_handlers):
            # Only equivalent marked handlers in the same matcher group can be removed.
            comments = ''.join(line for line in text[section['start']:section['end']].splitlines(True)
                               if line.lstrip().startswith('#'))
            edits.append((section['start'], section['end'], comments))
            continue
        previous_handlers.append((signature, complex_metadata))
        own_events.add(name)
        for key, value in (('command', observer_command), ('statusMessage', 'Wokintosh · ' + HOOK_LABELS.get(name, name))):
            if key in fields:
                start, end, _ = fields[key]
                edits.append((start, end, toml_value(value)))
            else:
                edits.append((section['headerEnd'], section['headerEnd'], key + ' = ' + toml_value(value) + '\n'))
    pending = hook_install_config('codex', command, migrated)['hooks']
    additions = []
    for name, groups in pending.items():
        if not isinstance(groups, list) or (name in own_events and name not in migrated.get('hooks', {})):
            continue
        for group in groups:
            additions.append('[[hooks.' + name + ']]\n')
            for key, value in group.items():
                if key != 'hooks':
                    additions.append(json.dumps(key) + ' = ' + toml_value(value) + '\n')
            for handler in group.get('hooks', []):
                additions.append('[[hooks.' + name + '.hooks]]\n')
                additions.extend(json.dumps(key) + ' = ' + toml_value(value) + '\n' for key, value in handler.items())
            additions.append('\n')
    for start, end, value in sorted(edits, reverse=True):
        text = text[:start] + value + text[end:]
    if additions:
        text += ('\n' if text and not text.endswith('\n') else '') + '\n# Wokintosh observational hooks\n' + ''.join(additions)
    return text


def install_hooks(provider, home, state_dir, command, dry_run=False):
    json_path = home / ('.claude/settings.json' if provider == 'claude' else '.codex/hooks.json')
    existing = json.loads(json_path.read_text()) if json_path.exists() else {}
    if not isinstance(existing, dict):
        raise ValueError('Existing hook settings must be a JSON object')
    changes = {}
    warnings = []
    primary = json_path
    toml_path = home / '.codex/config.toml'
    if provider == 'codex' and toml_path.exists():
        text = toml_path.read_text()
        owned, remaining = split_owned_hooks(existing)
        updated = hook_install_toml(text, command, owned)
        if updated is not None:
            primary = toml_path
            changes[toml_path] = updated
            if json_path.exists():
                changes[json_path] = json.dumps(remaining, indent=2, ensure_ascii=False) + '\n' if remaining else None
                if remaining:
                    warnings.append('Both config.toml and hooks.json remain because hooks.json contains unrelated hooks or metadata. '
                                    'Wokintosh entries were migrated; consolidate unrelated entries manually to remove the Codex dual-source warning.')
    if primary == json_path:
        changes[json_path] = json.dumps(hook_install_config(provider, command, existing), indent=2, ensure_ascii=False) + '\n'
    if dry_run:
        print(changes[primary])
    else:
        # Prepare every new file first. Parser/serialization errors cannot cause partial migrations.
        for path, content in changes.items():
            if path.exists() and (content is None or path.read_text() != content):
                shutil.copy2(path, path.with_name(path.name + '.wokintosh-backup-' + str(time.time_ns())))
        for path, content in changes.items():
            if content is None:
                path.unlink()
            elif not path.exists() or path.read_text() != content:
                path.parent.mkdir(parents=True, exist_ok=True)
                fd, temporary = tempfile.mkstemp(prefix='.wokintosh-', dir=path.parent)
                try:
                    with os.fdopen(fd, 'w') as stream:
                        stream.write(content)
                    os.replace(temporary, path)
                finally:
                    if os.path.exists(temporary):
                        os.unlink(temporary)
        print(f'Installed observational hooks in {primary}. Existing entries preserved. Restart sessions and review changed hooks normally in /hooks.')
    for warning in warnings:
        print('Wokintosh: ' + warning, file=sys.stderr if dry_run else sys.stdout)


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
        command = shlex.join([sys.executable, str(Path(__file__).resolve()), '--home', str(args.home),
                              '--state-dir', str(state_dir), 'hook', '--provider', args.provider])
        try:
            install_hooks(args.provider, args.home, state_dir, command, args.dry_run)
        except (OSError, ValueError, TypeError, KeyError) as error:
            parser.error(str(error))



if __name__ == '__main__':
    main()
