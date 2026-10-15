#!/usr/bin/env bash
set -euo pipefail

python3 - <<'GPU_USERS_PY'
import csv
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import pwd
import subprocess
import sys
import xml.etree.ElementTree as ET

def query(arguments):
    return subprocess.run(arguments, capture_output=True, text=True,
                          check=True, timeout=20).stdout

try:
    mapping = {}
    for fields in csv.reader(query(['nvidia-smi', '--query-gpu=index,uuid',
                                   '--format=csv,noheader,nounits']).splitlines()):
        if len(fields) != 2 or not fields[0].strip().isdigit():
            raise ValueError('GPU index')
        index, uuid = int(fields[0].strip()), fields[1].strip().lower()
        if not uuid.startswith('gpu-') or uuid in mapping or index in mapping.values():
            raise ValueError('GPU mapping')
        mapping[uuid] = index
    root = ET.fromstring(query(['nvidia-smi', '-q', '-x']))
    processes, seen = [], set()
    for gpu in root.findall('gpu'):
        uuid = gpu.findtext('uuid', '').strip().lower()
        if uuid not in mapping or uuid in seen:
            raise ValueError('GPU snapshot')
        seen.add(uuid)
        listing = gpu.find('processes')
        if listing is None or (listing.text or '').strip() not in ('', 'None'):
            raise ValueError('GPU process list')
        for process in listing.findall('process_info'):
            pid = process.findtext('pid', '').strip()
            kind = process.findtext('type', '').strip()
            processes.append((mapping[uuid], pid if pid.isdigit() and int(pid) > 0 else '?', kind))
    if not mapping or seen != set(mapping):
        raise ValueError('Incomplete GPU snapshot')
    pids = sorted({pid for _, pid, _ in processes if pid != '?'}, key=int)
    owners = {}
    if pids:
        result = subprocess.run(['ps', '-p', ','.join(pids), '-o', 'pid=,uid='],
                                capture_output=True, text=True, timeout=10)
        if result.returncode not in (0, 1):
            raise ValueError('Process owner query')
        for line in result.stdout.splitlines():
            fields = line.split()
            if len(fields) != 2 or not all(value.isdigit() for value in fields) or fields[0] not in pids:
                raise ValueError('Process owner data')
            try:
                owners[fields[0]] = pwd.getpwuid(int(fields[1])).pw_name
            except KeyError:
                owners[fields[0]] = 'UID=' + fields[1]
    usage = defaultdict(lambda: {'C': set(), 'G': set(), '?': set()})
    unresolved = set()
    for index, pid, kind in processes:
        owner = owners.get(pid, 'UNKNOWN')
        if owner == 'UNKNOWN':
            unresolved.add(pid)
        types = {'C', 'G'} if kind == 'C+G' else {kind} if kind in ('C', 'G') else {'?'}
        for category in types:
            usage[owner][category].add(index)
    def numbers(indices):
        return ','.join(map(str, sorted(indices))) or '-'
    print('確認時刻:', datetime.now(timezone(timedelta(hours=9), 'JST')).strftime('%Y-%m-%d %H:%M:%S %Z'))
    print(f'{"USER":32} {"C":>3} {"GPU(C)":15} {"G":>3} {"GPU(G)":15} {"?":>3} GPU(?)')
    for owner, groups in sorted(usage.items()):
        print(f'{owner:32} {len(groups["C"]):3} {numbers(groups["C"]):15} '
              f'{len(groups["G"]):3} {numbers(groups["G"]):15} {len(groups["?"]):3} {numbers(groups["?"])}')
    if not usage:
        print('GPUプロセスはありません。')
    print('C=計算、G=画面表示、?=種別不明。台数はユーザーごとの物理GPUの重複を除いて集計します。')
    if unresolved:
        print('所有者確認不可のPID:', ','.join(sorted(unresolved)), '（終了または権限等により未確認）')
except (OSError, ValueError, ET.ParseError, subprocess.SubprocessError) as error:
    print('GPU使用状況を確認できませんでした。nvidia-smi と ps の状態を確認してください。'
          f' [{type(error).__name__}]', file=sys.stderr)
    sys.exit(1)
GPU_USERS_PY
