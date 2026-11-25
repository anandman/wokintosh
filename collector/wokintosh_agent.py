#!/usr/bin/env python3
"""Wokintosh protocol-v1 collector. Python 3.10+, macOS/Linux, stdlib only."""
import argparse
import base64
import binascii
import copy
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import socket
import stat
try:
    import sqlite3
except ImportError:
    sqlite3 = None  # Some portable Python builds omit the optional SQLite module.
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone, timedelta

COLLECTOR_VERSION = '2.0.4'
MAX_COLLECTOR_BYTES = 1024 * 1024

MAX_LOG_BYTES = 2 * 1024 * 1024
MAX_SHARED_SOURCES_BYTES = 1024 * 1024
MAX_SHARED_ARTWORK_BYTES = 128 * 1024
STALE_SECONDS = 1800
MARKER = 'wokintosh-observer'
CACHE_VERSION = 5
MAX_CACHE_BYTES = 1024 * 1024
MAX_CACHE_ENTRIES = 512
SCAN_GAP = {'_wokintosh_scan_gap': True}
SESSION_FIELDS = ('id', 'provider', 'title', 'project', 'state', 'updatedAt', 'activity', 'parentId', 'isHelper', 'goalBlocked', 'openURLs', 'background')
MAX_BACKGROUND_TASKS = 64
BACKGROUND_STATUSES = {'running', 'completed', 'failed', 'cancelled', 'ended', 'unknown', 'needsAttention'}
BACKGROUND_ACTIVE = {'running', 'unknown', 'needsAttention'}
STATES = {'working', 'needsAttention', 'blocked', 'idle', 'finished', 'unknown'}
HOOK_EVENT_FIELDS = ('hook_event_name', 'session_id', 'sessionId', 'agent_id', 'tool_name',
                     'call_id', 'tool_use_id', 'notification_type', '_observedAt')
MAX_PENDING_INPUTS = 128
MAX_HOOK_EVENTS = 64
HOOK_STATE_VERSION = 1
MAX_GOAL_MARKERS = 512
MAX_GOAL_MARKER_BYTES = 4096
CODEX_BLOCKED_STATUSES = {'blocked', 'paused', 'usage_limited', 'budget_limited'}
CODEX_GOAL_STATUSES = CODEX_BLOCKED_STATUSES | {'active', 'complete'}


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


def canonical_thread_id(value):
    if not isinstance(value, str) or len(value) != 36:
        return None
    try:
        return value if str(uuid.UUID(value)) == value.lower() else None
    except ValueError:
        return None


def valid_bridge_id(value):
    return value if isinstance(value, str) and re.fullmatch(r'session_[A-Za-z0-9]{16,128}', value) else None


def session_open_urls(session):
    """Provider-owned navigation; never derive a mobile bridge ID from a hook UUID."""
    if not session or session.get('isHelper') or session.get('parentId'):
        return None
    if session.get('provider') == 'codex':
        identity = canonical_thread_id(session.get('_codexThreadID'))
        if identity and identity == session.get('id'):
            primary = 'codex://threads/' + identity
            return {'macOS': {'primary': primary},
                    'iOS': {'primary': primary, 'fallback': 'https://chatgpt.com/app', 'fallbackLabel': 'Open ChatGPT (new chat)'}}
    elif session.get('provider') == 'claude':
        bridge = valid_bridge_id(session.get('_bridgeSessionID'))
        if bridge:
            target = {'primary': 'claude://code/' + bridge, 'fallback': 'https://claude.ai/code/' + bridge}
            return {'macOS': dict(target), 'iOS': dict(target)}
    return None


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
            'isHelper': isinstance(parent, str) and bool(clean(parent, 180)), '_startedAt': stamp(updated)}


def finalize(session, now):
    if session and session.get('background'):
        return apply_background(session, now)
    if session and session['state'] == 'working':
        updated = parse_time(session['updatedAt'], now)
        if (now - updated).total_seconds() > STALE_SECONDS:
            session['state'] = 'unknown'
            session['activity'] = 'No recent lifecycle signal'
    return session


def background_id(value):
    return value if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_.:-]{1,180}', value) else None


def normalized_background(value):
    """Only bounded lifecycle metadata crosses caches or the protocol boundary."""
    if (not isinstance(value, dict) or value.get('version') != 1 or
            value.get('foregroundState') not in STATES or
            not isinstance(value.get('tasks'), list) or len(value['tasks']) > MAX_BACKGROUND_TASKS):
        return None
    foreground = parse_time(value.get('foregroundUpdatedAt'), None)
    if foreground is None:
        return None
    tasks = []
    for task in value['tasks']:
        if (not isinstance(task, dict) or not background_id(task.get('id')) or
                task.get('status') not in BACKGROUND_STATUSES or
                task.get('kind') not in ('shell', 'monitor', 'subagent', 'other') or
                not isinstance(task.get('label'), str) or len(task['label']) > 90):
            return None
        dates = {key: parse_time(task.get(key), None) for key in ('startedAt', 'updatedAt', 'observedAt')}
        if any(date is None for date in dates.values()):
            return None
        tasks.append(dict(id=task['id'], kind=task['kind'], label=clean(task['label'], 90),
                          status=task['status'], **{key: stamp(date) for key, date in dates.items()}))
    if len({task['id'] for task in tasks}) != len(tasks):
        return None
    result = dict(version=1, foregroundState=value['foregroundState'], foregroundUpdatedAt=stamp(foreground),
                  tasks=tasks, incomplete=value.get('incomplete') is True)
    inventory_at = parse_time(value.get('inventoryAt'), None)
    if inventory_at:
        result['inventoryAt'] = stamp(inventory_at)
    return result


def merge_background(first, second):
    first, second = normalized_background(first), normalized_background(second)
    if first is None:
        return second
    if second is None:
        return first
    result = dict(first if parse_time(first['foregroundUpdatedAt'], None) > parse_time(second['foregroundUpdatedAt'], None) else second)
    tasks = {task['id']: task for task in first['tasks']}
    for task in second['tasks']:
        old = tasks.get(task['id'])
        if old is None or (parse_time(task['updatedAt'], None), parse_time(task['observedAt'], None)) >= (parse_time(old['updatedAt'], None), parse_time(old['observedAt'], None)):
            tasks[task['id']] = task
    inventories = [value for value in (first, second) if value.get('inventoryAt')]
    clears_incomplete = False
    if inventories:
        inventory = max(inventories, key=lambda value:parse_time(value['inventoryAt'], None))
        inventory_at = parse_time(inventory['inventoryAt'], None)
        result['inventoryAt'] = inventory['inventoryAt']
        in_flight = {task['id'] for task in inventory['tasks'] if task['status'] in BACKGROUND_ACTIVE}
        for task in tasks.values():
            if (task['status'] in BACKGROUND_ACTIVE and task['id'] not in in_flight and
                    max(parse_time(task['updatedAt'], None), parse_time(task['observedAt'], None)) < inventory_at):
                task.update(status='ended', updatedAt=inventory['inventoryAt'], observedAt=inventory['inventoryAt'])
        incomplete_dates = [parse_time(value['foregroundUpdatedAt'], None) for value in (first, second) if value.get('incomplete')]
        clears_incomplete = not incomplete_dates or inventory_at >= max(incomplete_dates)
    ordered = sorted(tasks.values(), key=lambda task: (task['status'] in BACKGROUND_ACTIVE, parse_time(task['updatedAt'], None)), reverse=True)
    lost_active = any(task['status'] in BACKGROUND_ACTIVE for task in ordered[MAX_BACKGROUND_TASKS:])
    result['incomplete'] = lost_active or (not clears_incomplete and (first.get('incomplete', False) or second.get('incomplete', False)))
    result['tasks'] = ordered[:MAX_BACKGROUND_TASKS]
    return result


def observe_background_task(background, identity, kind, status, at, label=None, new_launch=False):
    identity = background_id(str(identity)) if identity is not None else None
    if identity is None or status not in BACKGROUND_STATUSES:
        return
    old = next((task for task in background['tasks'] if task['id'] == identity), None)
    timestamp = stamp(at)
    if old and parse_time(old['updatedAt'], None) > at:
        return
    # Replaying the original launch must not resurrect a later completed task.
    if old and old['updatedAt'] == timestamp and old['status'] != 'running' and status == 'running':
        return
    kind = kind if kind in ('shell', 'monitor', 'subagent') else 'other'
    new_run = old and new_launch and at > parse_time(old['startedAt'], at)
    same_run = old and not new_run
    repeated = same_run and old['status'] == status
    terminal_repeat = same_run and old['status'] not in BACKGROUND_ACTIVE and status not in BACKGROUND_ACTIVE
    if terminal_repeat and old['status'] != 'ended':
        status = old['status']
    label = re.sub(r'[\x00-\x1f\x7f]', ' ', label) if isinstance(label, str) else None
    task = dict(id=identity, kind=old['kind'] if old and kind == 'other' else kind,
                label=clean(label or (old and old['label']) or ('Monitor' if kind == 'monitor' else 'Background task') + ' · ' + identity[:12], 90),
                status=status, startedAt=old['startedAt'] if same_run else timestamp,
                updatedAt=old['updatedAt'] if repeated or terminal_repeat else timestamp,
                observedAt=max([timestamp, old['observedAt']] if same_run else [timestamp], key=lambda value:parse_time(value, at)))
    background['tasks'] = [item for item in background['tasks'] if item['id'] != identity] + [task]
    ordered = sorted(background['tasks'], key=lambda item: (item['status'] in BACKGROUND_ACTIVE, parse_time(item['updatedAt'], None)), reverse=True)
    if any(task['status'] in BACKGROUND_ACTIVE for task in ordered[MAX_BACKGROUND_TASKS:]):
        background['incomplete'] = True
    background['tasks'] = ordered[:MAX_BACKGROUND_TASKS]


def apply_background(session, now):
    background = normalized_background(session.get('background'))
    if background is None:
        return session
    session['background'] = background
    foreground = background['foregroundState']
    active = [task for task in background['tasks'] if task['status'] in ('running', 'unknown', 'needsAttention')]
    uncertain = background.get('incomplete') is True or any(task['status'] == 'unknown' or
                    not -60 <= (now - parse_time(task['observedAt'], now)).total_seconds() <= STALE_SECONDS for task in active)
    if session['state'] in ('needsAttention', 'blocked'):
        return session
    if foreground == 'needsAttention' or any(task['status'] == 'needsAttention' for task in active):
        session.update(state='needsAttention', activity='Background agent needs input')
    elif foreground == 'working' and -60 <= (now - parse_time(background['foregroundUpdatedAt'], now)).total_seconds() <= STALE_SECONDS:
        session.update(state='working', activity='Working')
    elif any(task['kind'] != 'monitor' and task['status'] == 'running' and
             -60 <= (now - parse_time(task['observedAt'], now)).total_seconds() <= STALE_SECONDS for task in active):
        count = sum(task['kind'] != 'monitor' and task['status'] == 'running' for task in active)
        session.update(state='working', activity=f'{count} background task' + ('s' if count != 1 else '') + ' running')
    elif uncertain:
        session.update(state='unknown', activity='Background task activity unverified')
    elif active:
        session.update(state='idle', activity='Monitoring')
    else:
        session.update(state=foreground, activity='Turn completed' if foreground == 'finished' else session.get('activity', ''))
        if foreground == 'working' and (now - parse_time(background['foregroundUpdatedAt'], now)).total_seconds() > STALE_SECONDS:
            session.update(state='unknown', activity='No recent lifecycle signal')
    # Lifecycle time is stable across polls. Liveness checks never manufacture Done.
    session['updatedAt'] = max([background['foregroundUpdatedAt']] +
                               [task['updatedAt'] for task in background['tasks'] if task['kind'] != 'monitor'], key=lambda value: parse_time(value, now))
    return session


def background_notifications(item):
    """Read provider task envelopes, not arbitrary text fragments in a response."""
    if item.get('type') == 'queue-operation' and item.get('operation') == 'enqueue':
        content = item.get('content')
    elif item.get('type') == 'user':
        message = item.get('message')
        content = message.get('content') if isinstance(message, dict) else None
    else:
        return []
    if isinstance(content, list):
        content = '\n'.join(part['text'] for part in content if isinstance(part, dict) and part.get('type') == 'text' and isinstance(part.get('text'), str))
    if not isinstance(content, str) or not content.lstrip().startswith('<task-notification>') or len(content) > 65536:
        return []
    identity = re.search(r'<task-id>([A-Za-z0-9_.:-]{1,180})</task-id>', content)
    status = re.search(r'<status>(completed|failed|killed|cancelled)</status>', content)
    return [(identity.group(1), 'cancelled' if status.group(1) == 'killed' else status.group(1))] if identity and status else []


def read_background(path, session, now, previous=None):
    if not session:
        return session
    prior = normalized_background(previous)
    background = dict(version=1, foregroundState=session['state'], foregroundUpdatedAt=session['updatedAt'],
                      tasks=copy.deepcopy(prior['tasks']) if prior else [], incomplete=prior.get('incomplete', False) if prior else False)
    if prior and parse_time(prior['foregroundUpdatedAt'], now) > parse_time(session['updatedAt'], now):
        background.update(foregroundState=prior['foregroundState'], foregroundUpdatedAt=prior['foregroundUpdatedAt'])
    calls = {}
    for item in records(path):
        if item is SCAN_GAP:
            calls.clear()
            continue
        at = parse_time(item.get('timestamp'), None)
        if at is None:
            continue
        if session['provider'] == 'claude':
            message = item.get('message') if isinstance(item.get('message'), dict) else {}
            content = message.get('content')
            if isinstance(content, list):
                for part in content:
                    if not isinstance(part, dict):
                        continue
                    if part.get('type') == 'tool_use':
                        name = part.get('name')
                        data = part.get('input') if isinstance(part.get('input'), dict) else {}
                        if name in ('Bash', 'Monitor', 'Agent', 'Task'):
                            calls[part.get('id')] = ('monitor' if name == 'Monitor' else 'subagent' if name in ('Agent', 'Task') else 'shell', clean(data.get('description'), 90))
                    elif part.get('type') == 'tool_result':
                        data = item.get('toolUseResult')
                        if isinstance(data, dict):
                            task_id = data.get('backgroundTaskId') or data.get('monitorId') or (data.get('agentId') if data.get('isAsync') is True else None)
                            kind, label = calls.get(part.get('tool_use_id'), ('other', ''))
                            if task_id:
                                observe_background_task(background, task_id, kind, 'running', at, label, new_launch=True)
            notifications = background_notifications(item)
            for identity, status in notifications:
                observe_background_task(background, identity, 'other', status, at)
        else:
            payload = item.get('payload')
            if not isinstance(payload, dict):
                continue
            command = payload.get('item') if payload.get('type') == 'item_completed' else payload
            if isinstance(command, dict) and command.get('type') in ('CommandExecution', 'commandExecution'):
                identity = command.get('process_id') or command.get('processId')
                status = command.get('status')
                mapped = {'in_progress': 'running', 'inProgress': 'running', 'running': 'running', 'completed': 'completed', 'failed': 'failed', 'declined': 'cancelled'}.get(status)
                if mapped == 'completed' and command.get('exit_code', command.get('exitCode')) is None:
                    mapped = 'unknown'
                if identity is not None and mapped:
                    observe_background_task(background, identity, 'shell', mapped, at, new_launch=mapped == 'running' and command.get('source') == 'unified_exec_startup')
            if item.get('type') == 'response_item':
                name = str(payload.get('name', '')).split('.')[-1]
                if payload.get('type') == 'function_call' and name in ('exec_command', 'write_stdin'):
                    try:
                        args = json.loads(payload.get('arguments', '{}'))
                    except (ValueError, TypeError):
                        args = {}
                    calls[payload.get('call_id')] = (name, args.get('session_id') if isinstance(args, dict) else None)
                elif payload.get('type') == 'function_call_output' and payload.get('call_id') in calls:
                    name, previous_id = calls[payload['call_id']]
                    output = payload.get('output')
                    if isinstance(output, str):
                        # Match harness headers only, before any command output.
                        header = output.partition('Output:')[0][:2048]
                        running = re.search(r'^Process running with session ID (\d+)\s*$', header, re.M)
                        exited = re.search(r'^Process exited with code (-?\d+)\s*$', header, re.M)
                        if running:
                            observe_background_task(background, running.group(1), 'shell', 'running', at, new_launch=name == 'exec_command')
                        elif name == 'write_stdin' and previous_id is not None and exited:
                            observe_background_task(background, previous_id, 'shell', 'completed' if exited.group(1) == '0' else 'failed', at)
    if background['tasks']:
        session['background'] = background
    return finalize(session, now)


def background_file_is_open(path, timeout):
    """Positive writer evidence only; a reader of old output proves nothing."""
    utility = shutil.which('fuser' if platform.system() == 'Linux' else 'lsof')
    if utility is None:
        return False
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            return False
        linux = platform.system() == 'Linux'
        args = [utility, str(path.resolve())] if linux else [utility, '-Fpa', '--', str(path)]
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, timeout=timeout, check=False)
        if result.returncode != 0:
            return False
        if not linux:
            return any(line in ('aw', 'au') for line in result.stdout.splitlines())
        for pid in result.stdout.split():
            if not pid.isdigit():
                continue
            directory = Path('/proc') / pid / 'fd'
            try:
                if directory.stat().st_uid != os.getuid():
                    continue
                for descriptor in list(directory.iterdir())[:256]:
                    try:
                        opened = descriptor.stat()
                        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                            continue
                        flags = (directory.parent / 'fdinfo' / descriptor.name).read_text()[:4096]
                        match = re.search(r'^flags:\s*([0-7]+)$', flags, re.M)
                        if match and int(match.group(1), 8) & os.O_ACCMODE in (os.O_WRONLY, os.O_RDWR):
                            return True
                    except OSError:
                        continue
            except OSError:
                continue
        return False
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


def refresh_background_liveness(session, path, now, deadline):
    if not session or session.get('provider') != 'claude' or not session.get('background'):
        return
    for task in session['background']['tasks']:
        if task['status'] != 'running' or (now - parse_time(task['observedAt'], now)).total_seconds() < 60:
            continue
        for root in (Path('/tmp'), Path(tempfile.gettempdir())):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            output = root / ('claude-' + str(os.getuid())) / path.parent.name / 'tasks' / (task['id'] + '.output')
            if output.exists() and background_file_is_open(output, min(0.4, remaining)):
                task['observedAt'] = stamp(now)
                break


def read_codex(path, now, title_index=None, previous_background=None):
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
            if canonical_thread_id(payload.get('id')):
                metadata['_codexThreadID'] = payload['id']
            metadata['isHelper'] = metadata['isHelper'] or (isinstance(source, dict) and 'subagent' in source)
            if session and session['id'] == metadata['id']:
                for field in ('title', 'project', 'parentId', 'isHelper', '_codexThreadID'):
                    if field not in metadata:
                        continue
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
    return read_background(path, session, now, previous_background)


def read_claude(path, now, previous_background=None):
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
        if background_notifications(item):
            continue
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
    return read_background(path, session, now, previous_background)


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
    if name == 'Notification' and event.get('notification_type') == 'idle_prompt':
        # Claude emits this after a response has already finished. It is not an input
        # request or a new completion, and must not refresh the lifecycle timestamp.
        calls, unknown = pending_input_state(result)
        if result.get('provider') == 'claude' and result.get('state') == 'unknown' and not calls and not unknown:
            result.update(state='idle', activity='Waiting for a task')
        return result
    supported = {'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
                 'PostToolUseFailure', 'PermissionRequest', 'Notification', 'Stop',
                 'SessionEnd', 'SubagentStart', 'SubagentStop', 'StopFailure', 'Interrupt'}
    if name not in supported or (name == 'Notification' and event.get('notification_type') not in
                                ('permission_prompt', 'elicitation_dialog')):
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
    elif name == 'Notification' and event.get('notification_type') in ('permission_prompt', 'elicitation_dialog'):
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
    previous = normalized_background(result.get('background'))
    snapshot = event.get('background_tasks') if session.get('provider') == 'claude' and name == 'Stop' and not result.get('isHelper') else None
    if previous or isinstance(snapshot, list):
        background = previous or dict(version=1, tasks=[])
        background.update(foregroundState=state, foregroundUpdatedAt=stamp(now))
        valid_tasks = [task for task in snapshot[:MAX_BACKGROUND_TASKS] if isinstance(task, dict) and
                       background_id(task.get('id')) and isinstance(task.get('status'), str)] if isinstance(snapshot, list) else []
        complete = (isinstance(snapshot, list) and len(snapshot) <= MAX_BACKGROUND_TASKS and
                    len(valid_tasks) == len(snapshot) and len({task['id'] for task in valid_tasks}) == len(valid_tasks))
        if complete:
            background['incomplete'] = False
            background['inventoryAt'] = stamp(now)
            present = {task['id'] for task in snapshot}
            for task in list(background['tasks']):
                if task['status'] in ('running', 'unknown', 'needsAttention') and task['id'] not in present:
                    observe_background_task(background, task['id'], task['kind'], 'ended', now)
        elif isinstance(snapshot, list):
            background['incomplete'] = True
        for task in valid_tasks:
            status = {'running':'running','pending':'running','completed':'completed','failed':'failed','killed':'cancelled','cancelled':'cancelled'}.get(task['status'], 'unknown')
            observe_background_task(background, task['id'], task.get('type'), status, now, task.get('description'))
        if background['tasks'] or background.get('incomplete') or complete:
            result['background'] = background
    return result


def normalize_claude_hook_summary(session):
    """Repair proven legacy idle overwrites once; preserve authoritative newer state.

    History is bounded, so it cannot reconstruct a genuine wait/completion after its
    event is evicted. New and repaired summaries carry their lifecycle independently.
    A legacy wait without a real lifecycle anchor remains conservatively pending.
    """
    events = session.get('_hookEvents', [])
    if (session['provider'] != 'claude' or '_hookEvents' not in session or
            session.get('_hookStateVersion', 0) >= HOOK_STATE_VERSION):
        return session
    result = dict(session)
    result['_hookStateVersion'] = HOOK_STATE_VERSION
    if session['state'] != 'needsAttention' or session['activity'] != 'Input needed' or not any(
            event.get('hook_event_name') == 'Notification' and event.get('notification_type') == 'idle_prompt'
            for event in events):
        return result
    observed_events = []
    for event in events:
        observed = parse_time(event['_observedAt'], None)
        if observed is not None and observed.tzinfo is not None:
            observed_events.append((observed, event))
    if not observed_events:
        return result
    observed_events.sort(key=lambda item: item[0])
    first = observed_events[0][0]
    pending = session.get('_pendingInput', {})
    calls = {}
    for key, at in pending.get('calls', {}).items():
        observed = parse_time(at, None)
        if observed is not None and observed.tzinfo is not None:
            calls[key] = at
    has_anchor = any(
        event.get('hook_event_name') in ('UserPromptSubmit', 'Stop', 'SessionEnd', 'Interrupt',
                                         'SubagentStart', 'SubagentStop', 'PermissionRequest', 'StopFailure') or
        (event.get('hook_event_name') == 'PreToolUse' and event.get('tool_name', '').endswith('request_user_input')) or
        (event.get('hook_event_name') == 'Notification' and event.get('notification_type') in
         ('permission_prompt', 'elicitation_dialog')) for _, event in observed_events)
    if not has_anchor:
        if calls:
            result['updatedAt'] = max(calls.values(), key=lambda at: parse_time(at, first))
        return result  # Idle-only history cannot prove an older real wait was answered.
    idle_times = {observed for observed, event in observed_events
                  if event.get('hook_event_name') == 'Notification' and event.get('notification_type') == 'idle_prompt'}
    unknown = pending.get('unknownSince')
    if parse_time(unknown, None) in idle_times:
        unknown = None  # Only this timestamp has proven idle-notice provenance.
    result.update(state='unknown', activity='', updatedAt=stamp(first))
    result.pop('_pendingInput', None)
    if calls or unknown:
        set_pending_input(result, calls, unknown)
        result.update(state='needsAttention', activity='Input needed')
    for observed, event in observed_events:
        result = apply_hook_state(result, event, observed)
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
    for field in SESSION_FIELDS[:7]:
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
    if value.get('goalBlocked') is not None and not isinstance(value['goalBlocked'], bool):
        return None
    result = {field: value.get(field) for field in SESSION_FIELDS}
    started = parse_time(value.get('_startedAt'), None)
    if started:
        result['_startedAt'] = stamp(started)
    result.pop('background', None)
    background = normalized_background(value.get('background'))
    if background:
        result['background'] = background
    # Wire targets are regenerated from bounded provider evidence, never trusted
    # merely because a cached summary contained an arbitrary openURLs object.
    result.pop('openURLs', None)
    thread_id = canonical_thread_id(value.get('_codexThreadID'))
    if value['provider'] == 'codex' and thread_id == value['id']:
        result['_codexThreadID'] = thread_id
    bridge_id = valid_bridge_id(value.get('_bridgeSessionID'))
    if value['provider'] == 'claude' and bridge_id:
        result['_bridgeSessionID'] = bridge_id
    result['isHelper'] = value.get('isHelper', False) or bool(value.get('parentId'))
    if type(value.get('_hookStateVersion')) is int and value['_hookStateVersion'] >= HOOK_STATE_VERSION:
        result['_hookStateVersion'] = value['_hookStateVersion']
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
    return normalize_claude_hook_summary(result)


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



def read_codex_goals(home):
    """A complete, bounded metadata observation, or None when absence is unproven."""
    path = home / '.codex/goals_1.sqlite'
    if sqlite3 is None:
        return None
    connection = None
    deadline = time.monotonic() + 0.15
    try:
        if not path.is_file():
            return None
        # mode=ro must see committed WAL changes; immutable=1 would silently miss them.
        connection = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True,
                                     timeout=0.05, isolation_level=None)
        connection.set_progress_handler(lambda: time.monotonic() > deadline, 1000)
        connection.execute('PRAGMA query_only=ON')
        connection.execute('BEGIN')
        kind = connection.execute("SELECT type FROM sqlite_master WHERE name='thread_goals'").fetchone()
        if kind != ('table',):
            return None
        columns = {row[1]: row[2].upper() for row in connection.execute('PRAGMA table_info(thread_goals)')}
        required = {'thread_id': 'TEXT', 'goal_id': 'TEXT', 'status': 'TEXT',
                    'created_at_ms': 'INTEGER', 'updated_at_ms': 'INTEGER'}
        if any(columns.get(name) != kind for name, kind in required.items()):
            return None
        # SQL bounds text before it crosses into Python, including malformed huge IDs.
        query = """SELECT
            CASE WHEN typeof(thread_id)='text' AND length(thread_id) BETWEEN 1 AND 180
                 AND length(CAST(thread_id AS BLOB))<=720 THEN thread_id END,
            CASE WHEN typeof(goal_id)='text' AND length(goal_id) BETWEEN 1 AND 180
                 AND length(CAST(goal_id AS BLOB))<=720 THEN goal_id END,
            CASE WHEN typeof(status)='text' AND length(status)<=32
                 AND length(CAST(status AS BLOB))<=128 THEN status END,
            CASE WHEN typeof(created_at_ms)='integer' THEN created_at_ms END,
            CASE WHEN typeof(updated_at_ms)='integer' THEN updated_at_ms END
            FROM thread_goals LIMIT ?"""
        rows = connection.execute(query, (MAX_GOAL_MARKERS + 1,)).fetchall()
        if len(rows) > MAX_GOAL_MARKERS:
            return None
        result = {}
        for identity, goal_id, status, created, updated in rows:
            if (not isinstance(identity, str) or not identity.isprintable() or
                    identity != clean(identity, 180) or not isinstance(goal_id, str) or
                    not goal_id.isprintable() or goal_id != clean(goal_id, 180) or
                    status not in CODEX_GOAL_STATUSES or
                    type(created) is not int or type(updated) is not int or
                    not 0 <= created <= updated <= 253402300799999 or identity in result):
                return None
            result[identity] = {'goalId': goal_id, 'status': status,
                                'updatedAt': stamp(datetime.fromtimestamp(updated / 1000, timezone.utc))}
        return result
    except (OSError, ValueError, OverflowError, sqlite3.Error):
        return None
    finally:
        if connection is not None:
            connection.close()


def load_codex_goal_bindings(path):
    """Separate provenance survives older observers rewriting a marker's fields."""
    try:
        with path.open('rb') as stream:
            raw = stream.read(MAX_CACHE_BYTES + 1)
        value = json.loads(raw) if len(raw) <= MAX_CACHE_BYTES else None
        entries = value.get('goals') if isinstance(value, dict) and value.get('version') == 1 else None
        if not isinstance(entries, dict) or len(entries) > MAX_GOAL_MARKERS:
            return {}
        result = {}
        for identity, entry in entries.items():
            if (not isinstance(identity, str) or not identity or identity != clean(identity, 180) or
                    not isinstance(entry, dict) or not isinstance(entry.get('goalId'), str) or
                    not entry['goalId'] or entry['goalId'] != clean(entry['goalId'], 180) or
                    not isinstance(entry.get('updatedAt'), str) or len(entry['updatedAt']) > 50):
                return {}
            datetime.fromisoformat(entry['updatedAt'].replace('Z', '+00:00'))
            result[identity] = {key: entry[key] for key in ('goalId', 'updatedAt')}
        return result
    except (OSError, ValueError, TypeError):
        return {}


def reconcile_codex_goals(sessions, markers, goals, state_dir):
    """Called under the marker lock; automatic evidence never replaces explicit marks."""
    binding_path = state_dir / 'codex-goal-bindings.json'
    previous = load_codex_goal_bindings(binding_path)
    bindings = dict(previous)
    for key, (path, marker) in list(markers.items()):
        if key[0] != 'codex' or marker.get('_goalSource') == 'explicit':
            continue
        goal = goals.get(key[1])
        known = marker.get('_goalSource') == 'codex' or key[1] in bindings
        if known and (goal is None or goal['status'] not in CODEX_BLOCKED_STATUSES):
            path.unlink(missing_ok=True)
            del markers[key]
    pending = [(identity, goal) for identity, goal in goals.items()
               if goal['status'] in CODEX_BLOCKED_STATUSES and
               ('codex', identity) not in markers]
    # Existing explicit/legacy marks have priority when the shared bounded store is full.
    available = max(0, MAX_GOAL_MARKERS - len(markers))
    pending.sort(key=lambda item: item[1]['updatedAt'], reverse=True)
    eligible = {identity for identity, goal in pending[:available]}
    for identity, goal in goals.items():
        if goal['status'] not in CODEX_BLOCKED_STATUSES:
            continue
        key = ('codex', identity)
        old = markers.get(key)
        if old is not None and old[1].get('_goalSource') == 'explicit':
            continue
        if old is None and identity not in eligible:
            continue
        current = sessions.get(key)
        if current is not None:
            marker = {field: current[field] for field in SESSION_FIELDS if field in current}
        elif old is not None:
            marker = dict(old[1])
        else:
            marker = base_session(identity, 'codex', '', parse_time(goal['updatedAt'], datetime.now(timezone.utc)))
        marker.update(state='blocked', activity='Goal blocked', updatedAt=goal['updatedAt'],
                      _goalSource='codex', _goalId=goal['goalId'])
        marker.pop('goalBlocked', None)
        path = goal_marker_path(state_dir, 'codex', identity)
        if old is None or marker != old[1]:
            atomic_json(path, marker)
        markers[key] = (path, marker)
        bindings[identity] = {field: goal[field] for field in ('goalId', 'updatedAt')}
    # Keep deletion receipts too: a delayed old helper must not resurrect a known goal.
    bindings = dict(sorted(bindings.items(), key=lambda item: item[1]['updatedAt'],
                           reverse=True)[:MAX_GOAL_MARKERS])
    if bindings != previous:
        atomic_json(binding_path, {'version': 1, 'goals': bindings})


def goal_marker_path(state_dir, provider, identity):
    key = hashlib.sha256((provider + '\0' + identity).encode()).hexdigest()
    return state_dir / 'goals' / (key + '.json')


def load_goal_marker(path, strict=False):
    try:
        with path.open('rb') as stream:
            data = stream.read(MAX_GOAL_MARKER_BYTES + 1)
        if len(data) > MAX_GOAL_MARKER_BYTES:
            raise ValueError('Goal marker is too large')
        raw = json.loads(data)
        result = valid_session(raw)
        if result is None or result['state'] != 'blocked':
            raise ValueError('Invalid goal marker')
        result.pop('goalBlocked', None)
        source = raw.get('_goalSource')
        if source is not None:
            if source not in ('explicit', 'codex') or (source == 'codex' and result['provider'] != 'codex'):
                raise ValueError('Invalid goal source')
            result['_goalSource'] = source
        goal_id = raw.get('_goalId')
        if goal_id is not None:
            if not isinstance(goal_id, str) or not goal_id or goal_id != clean(goal_id, 180):
                raise ValueError('Invalid goal identity')
            result['_goalId'] = goal_id
        return result
    except (OSError, ValueError, TypeError):
        if strict:
            raise
        return None


def set_goal_status(state_dir, provider, identity, status, now, title=None, project=None, source='explicit'):
    """Persist only an explicit goal status and small display metadata, never a goal body."""
    if (provider not in ('codex', 'claude') or not isinstance(identity, str) or
            not identity or len(identity) > 180 or identity != clean(identity, 180) or
            status not in ('blocked', 'stalled', 'paused', 'active', 'complete') or
            source not in ('explicit', 'codex') or (source == 'codex' and provider != 'codex')):
        raise ValueError('Invalid goal provider, session identity or status')
    path = goal_marker_path(state_dir, provider, identity)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Cross-process status writes and pruning share one bounded store on macOS/Linux.
    with (path.parent / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        existing = load_goal_marker(path)
        if source == 'codex' and existing is not None and existing.get('_goalSource') == 'explicit':
            return
        if status in ('active', 'complete'):
            if source == 'explicit' or (existing is not None and existing.get('_goalSource') == 'codex'):
                path.unlink(missing_ok=True)
            return
        entry = dict(existing) if existing else base_session(identity, provider, '', now)
        entry.update(state='blocked', activity='Goal blocked', _goalSource=source)
        if title is not None:
            entry['title'] = clean(title, 90) or entry['title']
        if project is not None:
            entry['project'] = clean(project, 90) or entry['project']
        if entry != existing:
            entry['updatedAt'] = stamp(now)
            atomic_json(path, entry)
        paths = sorted(path.parent.glob('*.json'), key=lambda item: item.stat().st_mtime_ns, reverse=True)
        for old in paths[MAX_GOAL_MARKERS:]:
            old.unlink(missing_ok=True)


def structured_goal_status(provider, event):
    """Only recognized successful goal-tool envelopes can change a durable marker."""
    if provider != 'codex' or event.get('hook_event_name') != 'PostToolUse':
        return None
    name = event.get('tool_name')
    if name not in ('update_goal', 'get_goal', 'functions.update_goal', 'functions.get_goal'):
        return None
    def object_value(value):
        if isinstance(value, str) and len(value) <= 65536:
            try:
                value = json.loads(value)
            except ValueError:
                return None
        return value if isinstance(value, dict) else None
    response = object_value(event.get('tool_response'))
    if response is None:
        return None
    if response and (response.get('isError') is True or response.get('error') or response.get('success') is False):
        return None
    if name in ('get_goal', 'functions.get_goal') and 'goal' in response and response['goal'] is None:
        return 'complete'  # Verified successful get_goal no-goal envelope, unlike {}.
    goal = response.get('goal', response)
    status = goal.get('status') if isinstance(goal, dict) else None
    return status if status in ('blocked', 'paused', 'active', 'complete') else None


def merge_goal_markers(sessions, state_dir, home=None, transcript_identities=frozenset()):
    directory = state_dir / 'goals'
    if not directory.exists() and home is None:
        return set()
    try:
        directory.mkdir(parents=True, exist_ok=True)
        # Read and classify under the same lock as explicit status writes, so one
        # concurrently cleared marker cannot make unrelated goals disappear.
        with (directory / '.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            paths = sorted(directory.glob('*.json'), key=lambda item: item.stat().st_mtime_ns,
                           reverse=True)[:MAX_GOAL_MARKERS]
            retained = set()
            complete = True
            markers = {}
            for path in paths:
                try:
                    marker = load_goal_marker(path, strict=True)
                except (OSError, ValueError, TypeError):
                    complete = False
                    continue
                key = (marker['provider'], marker['id'])
                markers[key] = (path, marker)
            # Read after acquiring the marker lock: a queued hook may have committed
            # a new goal or cleared an old one while this snapshot was waiting.
            codex_goals = read_codex_goals(home) if home is not None else None
            if codex_goals is not None:
                reconcile_codex_goals(sessions, markers, codex_goals, state_dir)
            for key, (path, marker) in markers.items():
                retained.add(key)
                current = sessions.get(key)
                if current is not None and (key in transcript_identities or current.get('isHelper') or current.get('parentId')):
                    classified = dict(marker)
                    # A saved transcript supersedes a prior hook-only helper guess,
                    # including when that classification was retained with a goal.
                    classified['isHelper'] = bool(current.get('isHelper') or current.get('parentId'))
                    classified['parentId'] = (current.get('parentId') if key in transcript_identities else
                                              current.get('parentId') or marker.get('parentId'))
                    if classified != marker:
                        atomic_json(path, classified)
                        marker = classified
                if current is None:
                    sessions[key] = marker
                else:
                    if marker.get('isHelper'):
                        current['isHelper'] = True
                        current['parentId'] = current.get('parentId') or marker.get('parentId')
                    if current['state'] != 'needsAttention':
                        # Turn completion does not prove an unfinished goal resolved.
                        current.update(state='blocked', activity='Goal blocked')
                        current['updatedAt'] = max((current['updatedAt'], marker['updatedAt']),
                                                  key=lambda value: parse_time(value, datetime.min.replace(tzinfo=timezone.utc)))
                sessions[key]['goalBlocked'] = True
            return retained if complete else None
    except (OSError, ValueError, TypeError):
        return None  # An incomplete store cannot prove that a goal was cleared.


def shared_source_date(value):
    """Validate transport dates without inventing a fresh timestamp on failure."""
    if not isinstance(value, str) or len(value) > 512 or not re.fullmatch(
            r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})', value):
        return None
    try:
        date = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return date.astimezone(timezone.utc) if date.utcoffset() is not None else None
    except (ValueError, OverflowError):
        return None


def shared_source_text(value):
    if not isinstance(value, str) or len(value) > 512:
        return False
    try:
        value.encode('utf-8')  # Reject lone surrogates that Swift JSONDecoder cannot represent.
        return True
    except UnicodeEncodeError:
        return False


def shared_source_base(value):
    if (not isinstance(value, dict) or type(value.get('available')) is not bool or
            shared_source_date(value.get('updatedAt')) is None or not shared_source_text(value.get('status'))):
        return None
    return {field: value[field] for field in ('available', 'updatedAt', 'status')}


def shared_music(value, generated_at, now):
    result = shared_source_base(value)
    if result is None:
        return None
    if not result['available']:
        return dict(result, title='', artist='', album='', isPlaying=False, position=0, duration=0)
    if (not all(shared_source_text(value.get(field)) for field in ('title', 'artist', 'album')) or
            type(value.get('isPlaying')) is not bool):
        return None
    duration, position = value.get('duration'), value.get('position')
    if (type(duration) not in (int, float) or not 0 <= duration <= 604800 or
            type(position) not in (int, float) or not 0 <= position <= duration):
        return None
    result.update({field: value[field] for field in ('title', 'artist', 'album', 'isPlaying', 'position', 'duration')})
    # The original timestamps remain on the wire so clients can visibly label stale data.
    if any(not -30 <= (now - date).total_seconds() <= 90
           for date in (generated_at, shared_source_date(value['updatedAt']))):
        result['isPlaying'] = False
    artwork = value.get('artworkBase64')
    if isinstance(artwork, str) and 0 < len(artwork) <= 4 * ((MAX_SHARED_ARTWORK_BYTES + 2) // 3):
        try:
            data = base64.b64decode(artwork, validate=True)
            if len(data) <= MAX_SHARED_ARTWORK_BYTES and base64.b64encode(data).decode('ascii') == artwork:
                result['artworkBase64'] = artwork
        except (binascii.Error, ValueError):
            pass  # A bad optional thumbnail need not hide an otherwise valid song.
    return result


def shared_calendar(value, now):
    result = shared_source_base(value)
    if result is None:
        return None
    if not result['available']:
        return dict(result, calendars=[], events=[])
    if not isinstance(value.get('calendars'), list) or not isinstance(value.get('events'), list):
        return None
    calendars = []
    for item in value['calendars']:
        if isinstance(item, dict) and all(shared_source_text(item.get(field)) for field in ('id', 'title', 'sourceTitle')):
            calendars.append({field: item[field] for field in ('id', 'title', 'sourceTitle')})
            if len(calendars) == 128:
                break
    selected = {item['id'] for item in calendars}
    events = []
    for item in value['events']:
        if (not isinstance(item, dict) or
                not all(shared_source_text(item.get(field)) for field in ('id', 'title', 'calendarID', 'calendarTitle')) or
                type(item.get('isAllDay')) is not bool or item['calendarID'] not in selected):
            continue
        start, end = shared_source_date(item.get('startDate')), shared_source_date(item.get('endDate'))
        if start is None or end is None or end <= start or end <= now or start >= now + timedelta(days=7):
            continue
        events.append({field: item[field] for field in ('id', 'title', 'startDate', 'endDate',
                                                       'isAllDay', 'calendarID', 'calendarTitle')})
    events.sort(key=lambda item: shared_source_date(item['startDate']))
    result.update(calendars=calendars, events=events[:256])
    return result


def read_shared_sources(home, now):
    """Read only a bounded, private, user-owned native publication; never native APIs."""
    path = home / 'Library/Application Support/Wokintosh/shared-sources.json'
    try:
        # O_NONBLOCK keeps a malicious FIFO from stalling collection before fstat;
        # O_NOFOLLOW checks the opened object rather than a racy path preflight.
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                    info.st_mode & 0o077 or info.st_size > MAX_SHARED_SOURCES_BYTES):
                return None
            data = stream.read(MAX_SHARED_SOURCES_BYTES + 1)
        if len(data) > MAX_SHARED_SOURCES_BYTES:
            return None
        value = json.loads(data)
        if not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1:
            return None
        generated_at = shared_source_date(value.get('generatedAt'))
        if generated_at is None:
            return None
        result = {'version': 1, 'generatedAt': value['generatedAt']}
        music = shared_music(value.get('music'), generated_at, now)
        calendar = shared_calendar(value.get('calendar'), now)
        if music is not None:
            result['music'] = music
        if calendar is not None:
            result['calendar'] = calendar
        return result
    except (OSError, ValueError, TypeError, OverflowError, RecursionError):
        # Absence and invalid publication are normal. Global errors affect goal
        # completion reconciliation and must stay independent of native sharing.
        return None


def collector_revision(content):
    # The SSH installer pins a compatible interpreter without changing the code.
    return hashlib.sha256(content.split(b'\n', 1)[-1]).hexdigest()


def read_managed_observer(home):
    if platform.system() != 'Darwin':
        return None
    path = home / 'Library/Application Support/Wokintosh/bin/Wokintosh-status-observer.py'
    for parent in path.relative_to(home).parents:
        if (home / parent).is_symlink():
            raise ValueError('The managed observer folder must not be a symbolic link')
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise ValueError('The managed observer could not be read safely') from error
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                info.st_mode & 0o022 or not info.st_mode & stat.S_IWUSR or
                not os.access(path, os.W_OK) or info.st_size > MAX_COLLECTOR_BYTES):
            raise ValueError('The managed observer must be a private writable user-owned regular file')
        content = stream.read(MAX_COLLECTOR_BYTES + 1)
    if (len(content) > MAX_COLLECTOR_BYTES or not content.startswith(b'#!') or
            not content.split(b'\n', 1)[-1].startswith(b'"""Wokintosh protocol-v1 collector.') or
            b"MARKER = 'wokintosh-observer'" not in content):
        raise ValueError('The existing observer is not a recognized Wokintosh collector')
    return path, info, content


def collector_metadata(home):
    content = Path(__file__).read_bytes()
    result = {'version': COLLECTOR_VERSION, 'revision': collector_revision(content)}
    try:
        existing = read_managed_observer(home)
        result['observerStatus'] = ('notInstalled' if existing is None else
                                    'current' if collector_revision(existing[2]) == result['revision'] else
                                    'updateAvailable')
    except (OSError, ValueError):
        result['observerStatus'] = 'unavailable'
    return result


def refresh_managed_observer(home):
    """Explicit install operation; never called by a hook or snapshot poll."""
    existing = read_managed_observer(home)
    if existing is None:
        return {'status': 'notInstalled'}
    path, info, previous = existing
    content = Path(__file__).read_bytes()
    if collector_revision(previous) == collector_revision(content):
        return {'status': 'current'}
    backup = path.with_name(path.name + '.wokintosh-backup-' + str(uuid.uuid4()))
    # Back up before replacement; refuse a concurrent change to the destination.
    descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(previous)
    descriptor, temporary = tempfile.mkstemp(prefix='.wokintosh-observer-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(content)
            os.fchmod(stream.fileno(), 0o700)
        current = os.lstat(path)
        if (current.st_dev, current.st_ino, current.st_mtime_ns, current.st_size) != (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size):
            raise ValueError('The managed observer changed during its update; backup retained')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return {'status': 'updated', 'backupPath': str(backup)}


def merge_helper_background(sessions, now):
    """Hidden helper rows still contribute to their parent's effective lifecycle."""
    children = {}
    for key, child in sessions.items():
        parent = (child['provider'], child.get('parentId'))
        if parent in sessions and parent != key:
            children.setdefault(parent, []).append(key)
    done = set()
    def visit(key, trail):
        if key in done or key in trail or len(trail) >= 16:
            return
        parent = sessions[key]
        background = normalized_background(parent.get('background')) or dict(version=1, foregroundState=parent['state'], foregroundUpdatedAt=parent['updatedAt'], tasks=[])
        for child_key in children.get(key, []):
            visit(child_key, trail | {key})
            child = sessions[child_key]
            child_id = child['id'].removeprefix(parent['id'] + ':')
            if child['provider'] == 'claude':
                child_id = child_id.removeprefix('agent-')
            status = {'working':'running','needsAttention':'needsAttention','blocked':'needsAttention',
                      'finished':'completed','idle':'completed','unknown':'unknown'}[child['state']]
            if child.get('background') and child['state'] == 'idle' and any(task['status'] == 'running' for task in child['background']['tasks']):
                status = 'running'
            observe_background_task(background, child_id, 'subagent', status, parse_time(child['updatedAt'], now), child['title'])
            task = next((task for task in background['tasks'] if task['id'] == child_id), None)
            if task:
                task['startedAt'] = child.get('_startedAt', task['startedAt'])
                observations = [task['observedAt']] + [item['observedAt'] for item in (child.get('background') or {}).get('tasks', []) if item['status'] == 'running']
                task['observedAt'] = max(observations, key=lambda value:parse_time(value, now))
        if background['tasks']:
            parent['background'] = background
            finalize(parent, now)
        done.add(key)
    for key in children:
        visit(key, set())


def make_snapshot(home, state_dir, now, host_name=None):
    state_dir.mkdir(parents=True, exist_ok=True)
    title_index = {}
    for item in records(home / '.codex/session_index.jsonl'):
        if isinstance(item.get('id'), str):
            title_index[item['id']] = clean(item.get('thread_name') or item.get('title'), 90)
    sessions = {}
    transcript_identities = set()
    transcript_paths = {}
    bridge_links = {}
    errors = []
    cached = load_parse_cache(state_dir / 'parse-cache.json')
    next_cache = {}
    liveness_budget = 1.0
    title_revision = hashlib.sha256(json.dumps(title_index, sort_keys=True).encode()).hexdigest()
    for provider, directory, parser in (
        ('codex', home / '.codex/sessions', lambda p, previous: read_codex(p, now, title_index, previous)),
        ('claude', home / '.claude/projects', lambda p, previous: read_claude(p, now, previous))):
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
                previous = (entry.get('session') or {}).get('background') if isinstance(entry, dict) else None
                if isinstance(entry, dict) and 'session' in entry and entry.get('fingerprint') == fingerprint:
                    session = valid_session(entry.get('session'), provider)
                    # A cached null is a deliberate negative parse result.
                    if session is None and entry.get('session') is not None:
                        session = parser(path, previous)
                else:
                    session = parser(path, previous)
                # Fresh parses must satisfy the same protocol contract as cache hits.
                session = valid_session(session, provider)
                next_cache[key_hash] = {'fingerprint': fingerprint, 'session': session}
                session = finalize(dict(session), now) if session else None
                if session:
                    key = (provider, session['id'])
                    transcript_paths[key] = path
                    transcript_identities.add(key)
                    if key not in sessions or session['updatedAt'] > sessions[key]['updatedAt']:
                        sessions[key] = session
            except (OSError, ValueError, TypeError, KeyError):
                continue
    for path in (state_dir / 'hooks').glob('*.json'):
        try:
            entry = json.loads(path.read_text())
            entry = valid_session(entry)
            if entry is None:
                continue
            provider, identity = entry['provider'], entry['id']
            key = (provider, identity)
            if provider == 'claude':
                bridge_links[key] = entry.get('_bridgeSessionID')
            if key in sessions:
                combined = merge_background(sessions[key].get('background'), entry.get('background'))
                if combined:
                    current = sessions[key]
                    if not current.get('background') and parse_time(current['updatedAt'], now) > parse_time(combined['foregroundUpdatedAt'], now):
                        combined.update(foregroundState=current['state'], foregroundUpdatedAt=current['updatedAt'])
                    current['background'] = combined
            if key not in sessions:
                sessions[key] = finalize(entry, now)
            elif (provider == 'claude' and entry.get('_hookStateVersion', 0) >= HOOK_STATE_VERSION and
                  entry['state'] in ('working', 'needsAttention', 'finished') and
                  parse_time(entry['updatedAt'], now) >= parse_time(sessions[key]['updatedAt'], now)):
                # Versioned summaries retain true lifecycle evidence after its observation
                # leaves bounded history. A newer transcript still supersedes old hooks.
                current = sessions[key]
                background = merge_background(current.get('background'), entry.get('background'))
                current.update({field: entry[field] for field in ('state', 'activity', 'updatedAt')})
                if background:
                    if not entry.get('background') and parse_time(entry['updatedAt'], now) > parse_time(background['foregroundUpdatedAt'], now):
                        background.update(foregroundState=entry['state'], foregroundUpdatedAt=entry['updatedAt'])
                    current['background'] = background
                calls, unknown = pending_input_state(entry)
                set_pending_input(current, calls, unknown)
                sessions[key] = finalize(current, now)
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
    for key, path in transcript_paths.items():
        before_liveness = time.monotonic()
        refresh_background_liveness(sessions[key], path, now, before_liveness + max(0, liveness_budget))
        liveness_budget -= time.monotonic() - before_liveness
        finalize(sessions[key], now)
    for entry in next_cache.values():
        parsed = entry.get('session')
        current = sessions.get((parsed['provider'], parsed['id'])) if parsed else None
        if current and current.get('background'):
            parsed['background'] = copy.deepcopy(current['background'])
    save_parse_cache(state_dir / 'parse-cache.json', next_cache)
    merge_helper_background(sessions, now)
    goal_identities = merge_goal_markers(sessions, state_dir, home, transcript_identities)
    if goal_identities is None:
        errors.append('Goal status unavailable')
    for key, session in sessions.items():
        finalize(session, now)
        session['goalBlocked'] = key in goal_identities if goal_identities is not None else (True if session.get('goalBlocked') is True else None)
        if session['provider'] == 'claude' and bridge_links.get(key):
            session['_bridgeSessionID'] = bridge_links[key]
        targets = session_open_urls(session)
        if targets:
            session['openURLs'] = targets
        else:
            session.pop('openURLs', None)
    recent = [{field: s[field] for field in SESSION_FIELDS if field in s and (field != 'goalBlocked' or s[field] is not None)}
              for s in sessions.values()
              if (goal_identities is not None and (s['provider'], s['id']) in goal_identities) or
                 s.get('goalBlocked') is True or s['state'] == 'blocked' or
                 (now-parse_time(s['updatedAt'], now)).total_seconds() < 7*86400]
    snapshot = {'schemaVersion': 1, 'host': {'id': host_identity(state_dir), 'name': clean(host_name or socket.gethostname().split('.')[0]), 'platform': 'macos' if platform.system() == 'Darwin' else platform.system().lower()},
                'generatedAt': stamp(now), 'sessions': recent, 'system': system_stats(home, state_dir), 'errors': errors,
                'collector': collector_metadata(home)}
    shared_sources = read_shared_sources(home, now)
    if shared_sources is not None:
        snapshot['sharedSources'] = shared_sources
    return snapshot


HOOK_LABELS = {
    'SessionStart': 'Started', 'UserPromptSubmit': 'Working', 'PreToolUse': 'Working',
    'PostToolUse': 'Working', 'PermissionRequest': 'Needs permission', 'Stop': 'Done',
    'SubagentStart': 'Helper started', 'SubagentStop': 'Helper done', 'Interrupt': 'Interrupted',
    'Notification': 'Needs input', 'SessionEnd': 'Session ended', 'StopFailure': 'Agent error',
    'PostToolUseFailure': 'Tool error'}


def observer_handler(handler):
    return isinstance(handler, dict) and handler.get('type') == 'command' and MARKER in str(handler.get('command', ''))


def hook_install_config(provider, command, existing, installed_events=()):
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
        if name in installed_events:
            continue  # Existing TOML observers already cover this event; retain migrated groups as they are.
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
        component = toml_string(raw) if raw[0] in ('"', "'") else raw
        if component is None:
            raise ValueError('Unsupported TOML key escape; settings were not changed')
        path.append(component)
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
            current = {'path': path, 'array': brackets == 2, 'start': start, 'headerEnd': end, 'fields': {}}
        else:
            if not current['path'] and re.match(r'''\s*(?:hooks|"hooks"|'hooks')\s*\.''', code):
                raise ValueError('Dotted inline-value TOML hooks need manual migration; settings were not changed')
            match = re.match(r'''\s*("(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z_][A-Za-z_0-9]*)\s*=\s*''', text[start:code_end])
            if not match:
                # Unknown/dotted keys remain opaque, but must prohibit deleting this section.
                current['unparsed'] = True
                key_match = re.match(r"""\s*((?:"(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z_0-9-]+)(?:\s*\.\s*(?:"(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z_0-9-]+))*)\s*=""", text[start:code_end])
                current.setdefault('opaque_keys', []).append(toml_key_path(key_match.group(1)) if key_match else ())
                continue
            raw_key = match.group(1)
            key = toml_string(raw_key) if raw_key[0] in ('"', "'") else raw_key
            if key is None:
                raise ValueError('Unsupported TOML key escape; settings were not changed')
            if (not current['path'] and (key == 'hooks' or code.startswith('hooks.'))) or (current['path'] == ('hooks',) and key in HOOK_LABELS):
                raise ValueError('Inline-value TOML hooks need manual migration to [[hooks.Event]] tables; settings were not changed')
            value_start = start + match.end()
            current['fields'][key] = (value_start, code_end, text[value_start:code_end])
            if (current['path'][:1] == ('hooks',) and len(current['path']) <= 2 and key == 'hooks' and
                    not (len(current['path']) == 2 and text[value_start:code_end].strip() == '[]')):
                raise ValueError('Inline-value TOML hook handlers need [[hooks.Event.hooks]] tables; settings were not changed')
    current['end'] = len(text)
    sections.append(current)
    return inline, sections


def toml_value(value):
    error = 'Unsupported hook metadata cannot safely migrate to TOML; settings were not changed'
    if isinstance(value, str):
        if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
            raise ValueError(error)
        return json.dumps(value, ensure_ascii=False).replace('\x7f', '\\u007f')
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, int):
        if not -(2 ** 63) <= value < 2 ** 63:
            raise ValueError(error)
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError(error)
        return json.dumps(value)
    if isinstance(value, list):
        return '[' + ', '.join(toml_value(x) for x in value) + ']'
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            raise ValueError(error)
        return '{ ' + ', '.join(toml_value(k) + ' = ' + toml_value(v) for k, v in value.items()) + ' }'
    raise ValueError(error)


def hook_json_summary(existing):
    """Describe retained JSON without displaying commands, matchers, or metadata values."""
    metadata = set(existing) - {'hooks'}
    hooks = existing.get('hooks', {})
    if not isinstance(hooks, dict):
        raise ValueError('Existing hooks must be an object; settings were not changed')
    count = 0
    for name, groups in hooks.items():
        if name == 'state' or not isinstance(groups, list):
            metadata.add('hooks.' + name)
            continue
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get('hooks', []), list):
                raise ValueError('Existing hook event groups must contain a hooks array; settings were not changed')
            if not all(isinstance(handler, dict) for handler in group.get('hooks', [])):
                raise ValueError('Existing hook handlers must be objects; settings were not changed')
            count += len(group.get('hooks', []))
    return count, metadata


def codex_consolidation_config(existing):
    """Only event arrays migrate; description is known archival metadata, not TOML config."""
    _, metadata = hook_json_summary(existing)
    unknown = metadata - {'description'}
    if unknown:
        raise ValueError('Cannot consolidate unknown active hooks.json metadata keys: ' +
                         ', '.join(json.dumps(key) for key in sorted(unknown)) +
                         '; settings were not changed')
    if 'description' in existing and not isinstance(existing['description'], str):
        raise ValueError('Cannot archive non-string hooks.json description metadata; settings were not changed')
    hooks = copy.deepcopy(existing.get('hooks', {}))
    toml_value(hooks)  # Validate every key/value before backups or either active source is changed.
    return {'hooks': hooks}


def split_owned_hooks(existing):
    """Separate only our marked command handlers; leave all other JSON data intact."""
    hook_json_summary(existing)
    remaining = copy.deepcopy(existing)
    owned = {'hooks': {}}
    for name, entries in list(remaining.get('hooks', {}).items()):
        if name == 'state' or not isinstance(entries, list):
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
    event_names = set(HOOK_LABELS) | set(migrated.get('hooks', {}))
    declared_events = set()
    for section in sections:
        path = section['path']
        if ((path == ('hooks',) and section.get('array')) or
                (path == ('hooks',) and (event_names.intersection(section['fields']) or
                 any(not key or key[0] in event_names for key in section.get('opaque_keys', []))))):
            raise ValueError('Unsupported TOML hook table or inline event value; settings were not changed')
        if len(path) < 2 or path[0] != 'hooks' or path[1] not in event_names:
            continue
        if len(path) == 2 and section.get('array'):
            declared_events.add(path[1])
        elif (path[1] not in declared_events or len(path) == 2 or
                (len(path) == 3 and path[2] == 'hooks' and not section.get('array'))):
            raise ValueError('Unsupported TOML hook event/handler tables need [[hooks.Event]] arrays; settings were not changed')
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
        opaque_metadata = bool(section.get('unparsed') or (len(next_path) > 3 and next_path[:3] == path))
        signature = {key: field[2].strip() for key, field in fields.items()
                     if key not in ('command', 'statusMessage')}
        if previous_handlers and (opaque_metadata or any(item[1] for item in previous_handlers)):
            raise ValueError('Duplicate marked TOML hooks with extra metadata need manual consolidation; settings were not changed')
        if any(item[0] == signature for item in previous_handlers):
            # Only equivalent marked handlers in the same matcher group can be removed.
            comments = ''.join(line for line in text[section['start']:section['end']].splitlines(True)
                               if line.lstrip().startswith('#'))
            edits.append((section['start'], section['end'], comments))
            continue
        previous_handlers.append((signature, opaque_metadata))
        own_events.add(name)
        for key, value in (('command', observer_command), ('statusMessage', 'Wokintosh · ' + HOOK_LABELS.get(name, name))):
            if key in fields:
                start, end, _ = fields[key]
                edits.append((start, end, toml_value(value)))
            else:
                edits.append((section['headerEnd'], section['headerEnd'], key + ' = ' + toml_value(value) + '\n'))
    pending = hook_install_config('codex', command, migrated, installed_events=own_events)['hooks']
    additions = []
    for name, groups in pending.items():
        if not isinstance(groups, list):
            continue
        event_key = name if re.fullmatch(r'[A-Za-z0-9_-]+', name) else toml_value(name)
        for group in groups:
            additions.append('[[hooks.' + event_key + ']]\n')
            for key, value in group.items():
                if key != 'hooks' or not value:
                    additions.append(toml_value(key) + ' = ' + toml_value(value) + '\n')
            for handler in group.get('hooks', []):
                additions.append('[[hooks.' + event_key + '.hooks]]\n')
                additions.extend(toml_value(key) + ' = ' + toml_value(value) + '\n' for key, value in handler.items())
            additions.append('\n')
    for start, end, value in sorted(edits, reverse=True):
        text = text[:start] + value + text[end:]
    if additions:
        text += ('\n' if text and not text.endswith('\n') else '') + '\n# Wokintosh observational hooks\n' + ''.join(additions)
    return text


def install_hooks(provider, home, state_dir, command, dry_run=False, consolidate_sources=False):
    if consolidate_sources and provider != 'codex':
        raise ValueError('--consolidate-sources is only supported for Codex; settings were not changed')
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
        inline, _ = toml_hook_sections(text)
        if inline and consolidate_sources:
            migrated = codex_consolidation_config(existing)
            remaining = {}
        else:
            migrated, remaining = split_owned_hooks(existing)
        updated = hook_install_toml(text, command, migrated)
        if updated is not None:
            primary = toml_path
            changes[toml_path] = updated
            if json_path.exists():
                changes[json_path] = json.dumps(remaining, indent=2, ensure_ascii=False) + '\n' if remaining else None
                if remaining:
                    count, metadata = hook_json_summary(remaining)
                    keys = ', '.join(json.dumps(key) for key in sorted(metadata)) or 'none'
                    warnings.append(f'Both config.toml and hooks.json remain: hooks.json contains {count} event handlers; '
                                    f'metadata keys: {keys}. Unrelated JSON entries were retained. To consolidate supported '
                                    'sources with backups, run: wokintosh-agent install-hooks --provider codex --consolidate-sources')
    if primary == json_path:
        changes[json_path] = json.dumps(hook_install_config(provider, command, existing), indent=2, ensure_ascii=False) + '\n'
    backups = {path: path.with_name(path.name + '.wokintosh-backup-' + str(time.time_ns()))
               for path, content in changes.items()
               if path.exists() and (content is None or path.read_text() != content)}
    if consolidate_sources and primary == toml_path and json_path.exists() and 'description' in existing:
        warnings.append('Top-level hooks.json description metadata ' + ('will be archived' if dry_run else 'was archived') +
                        ' in the full original JSON backup ' + str(backups[json_path]) + '; event groups are preserved in config.toml.')
    if dry_run:
        print(changes[primary])
        for path, content in changes.items():
            action = 'Remove' if content is None else 'Update' if not path.exists() or path.read_text() != content else 'Keep unchanged'
            print(f'Wokintosh dry run: {action} {path}', file=sys.stderr)
            if path in backups:
                print(f'Wokintosh dry run: Back up {path} to {backups[path]} before changing either source', file=sys.stderr)
    else:
        # Prepare every new file first. Parser/serialization errors cannot cause partial migrations.
        for path, backup in backups.items():
            shutil.copy2(path, backup)
        for path, content in changes.items():
            if content is not None and (not path.exists() or path.read_text() != content):
                path.parent.mkdir(parents=True, exist_ok=True)
                fd, temporary = tempfile.mkstemp(prefix='.wokintosh-', dir=path.parent)
                try:
                    with os.fdopen(fd, 'w') as stream:
                        stream.write(content)
                    os.replace(temporary, path)
                finally:
                    if os.path.exists(temporary):
                        os.unlink(temporary)
        # Never remove an active source until all backups and replacement writes succeeded.
        for path, content in changes.items():
            if content is None:
                path.unlink()
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
    # Codex explicitly sends null for nonpersistent runs (for example its
    # ambient suggestions and safety checks). An omitted field is unknown, not
    # proof of a helper. Persist only this classification, never a transcript path.
    if provider == 'codex' and 'transcript_path' in event and event['transcript_path'] is None:
        session['isHelper'] = True
    observation = {key: event[key] for key in HOOK_EVENT_FIELDS
                   if key in event and isinstance(event[key], str) and len(event[key]) <= 180}
    observation['_observedAt'] = stamp(now)
    result = apply_hook_state(session, event, now)
    if provider == 'claude':
        bridge = valid_bridge_id(os.environ.get('CLAUDE_CODE_BRIDGE_SESSION_ID'))
        if event.get('hook_event_name') == 'SessionEnd':
            result.pop('_bridgeSessionID', None)
        elif bridge and not result.get('isHelper') and not result.get('parentId'):
            result['_bridgeSessionID'] = bridge
    result['_hookStateVersion'] = HOOK_STATE_VERSION
    result['_hookEvents'] = (session.get('_hookEvents', []) + [observation])[-MAX_HOOK_EVENTS:]
    atomic_json(path, result)
    goal_status = structured_goal_status(provider, event)
    if goal_status is not None:
        set_goal_status(state_dir, provider, identity, goal_status, now,
                        title=session.get('title'), project=session.get('project'), source='codex')


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
    goal = sub.add_parser('goal-status', help='Publish or clear a persistent unfinished-goal status')
    goal.add_argument('--provider', choices=['codex', 'claude'], required=True)
    goal.add_argument('--session-id', required=True)
    goal.add_argument('--status', choices=['blocked', 'stalled', 'active', 'complete'], required=True)
    goal.add_argument('--title', help='Optional short dashboard title; no goal body')
    goal.add_argument('--project', help='Optional short project name')
    install = sub.add_parser('install-hooks', help='Explicitly merge observational hooks, backing up settings')
    install.add_argument('--provider', choices=['codex', 'claude'], required=True)
    install.add_argument('--dry-run', action='store_true')
    install.add_argument('--consolidate-sources', action='store_true',
                         help='Explicitly consolidate Codex hooks.json into existing TOML hook tables, with full backups')
    refresh = sub.add_parser('refresh-observer', help='Explicitly update an existing managed observer copy with a backup')
    refresh.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    state_dir = args.state_dir or state_directory(args.home)
    now = datetime.now(timezone.utc)
    if args.command == 'snapshot':
        print(json.dumps(make_snapshot(args.home, state_dir, now, args.host_name), separators=(',', ':')))
    elif args.command == 'refresh-observer':
        try:
            print(json.dumps(refresh_managed_observer(args.home)))
        except (OSError, ValueError) as error:
            parser.error(str(error))
    elif args.command == 'goal-status':
        try:
            set_goal_status(state_dir, args.provider, args.session_id, args.status, now, args.title, args.project)
        except (OSError, ValueError, TypeError) as error:
            parser.error(str(error))
        print('{}')
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
            install_hooks(args.provider, args.home, state_dir, command, args.dry_run, args.consolidate_sources)
        except (OSError, ValueError, TypeError, KeyError) as error:
            parser.error(str(error))



if __name__ == '__main__':
    main()
