#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path
from typing import BinaryIO, Iterator

IMPORT_ROOT = Path('/opt/hyper-host/imports')
JOBS_DIR = IMPORT_ROOT / 'jobs'
LOGS_DIR = IMPORT_ROOT / 'logs'
UPLOADS_DIR = IMPORT_ROOT / 'uploads'


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def safe_db_name(value: str) -> str:
    if not re.fullmatch(r'[A-Za-z0-9_]{2,48}', value or ''):
        raise ValueError('Некорректное имя базы данных')
    return value


def atomic_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f'.{os.getpid()}.tmp')
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(tmp, path)


def choose_zip_member(path: Path) -> zipfile.ZipInfo:
    with zipfile.ZipFile(path) as zf:
        candidates = [i for i in zf.infolist() if not i.is_dir() and i.filename.lower().endswith('.sql')]
        if not candidates:
            raise ValueError('В ZIP не найден файл .sql')
        candidates.sort(key=lambda i: i.file_size, reverse=True)
        return candidates[0]


def inspect_source(path: Path) -> dict:
    if not path.is_file():
        raise FileNotFoundError(str(path))
    suffix = path.suffix.lower()
    result = {
        'ok': True,
        'file': str(path),
        'name': path.name,
        'compressed_size': path.stat().st_size,
        'format': 'sql',
        'uncompressed_size': path.stat().st_size,
    }
    if suffix == '.zip':
        info = choose_zip_member(path)
        result.update({'format': 'zip', 'member': info.filename, 'uncompressed_size': info.file_size})
    elif suffix == '.gz':
        result['format'] = 'gzip'
        # ISIZE is modulo 2^32; only use it as a hint.
        try:
            with path.open('rb') as fh:
                fh.seek(-4, os.SEEK_END)
                result['uncompressed_size_hint'] = int.from_bytes(fh.read(4), 'little')
        except Exception:
            pass
    elif suffix != '.sql':
        raise ValueError('Поддерживаются только .sql, .sql.gz и .zip')
    return result


def source_stream(path: Path) -> tuple[BinaryIO, int, object | None]:
    suffix = path.suffix.lower()
    if suffix == '.zip':
        zf = zipfile.ZipFile(path)
        info = choose_zip_member(path)
        return zf.open(info, 'r'), int(info.file_size), zf
    if suffix == '.gz':
        return gzip.open(path, 'rb'), int(path.stat().st_size), None
    if suffix == '.sql':
        return path.open('rb'), int(path.stat().st_size), None
    raise ValueError('Поддерживаются только .sql, .sql.gz и .zip')


def tail_text(path: Path, limit: int = 12000) -> str:
    try:
        with path.open('rb') as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - limit))
            return fh.read().decode('utf-8', errors='replace')
    except Exception:
        return ''


def run_import(database: str, source: Path, job_id: str, delete_after: bool = True) -> int:
    database = safe_db_name(database)
    source = source.resolve()
    IMPORT_ROOT.mkdir(parents=True, exist_ok=True)
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
    job_path = JOBS_DIR / f'{job_id}.json'
    log_path = LOGS_DIR / f'{job_id}.log'
    meta = inspect_source(source)
    total = int(meta.get('uncompressed_size') or meta.get('compressed_size') or 0)
    status = {
        'ok': True,
        'job_id': job_id,
        'status': 'running',
        'database': database,
        'source': str(source),
        'source_name': source.name,
        'format': meta.get('format'),
        'member': meta.get('member', ''),
        'compressed_size': int(meta.get('compressed_size') or 0),
        'bytes_total': total,
        'bytes_processed': 0,
        'progress': 0.0,
        'started_at': now_iso(),
        'updated_at': now_iso(),
        'finished_at': '',
        'log': str(log_path),
        'error': '',
    }
    atomic_json(job_path, status)

    mysql_base = [
        'mysql', '--protocol=socket', '-uroot', '--default-character-set=utf8mb4',
        '--binary-mode=1', '--max_allowed_packet=1G', '--connect-timeout=60',
    ]
    create = subprocess.run(mysql_base + ['-e', f'CREATE DATABASE IF NOT EXISTS `{database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if create.returncode != 0:
        status.update(status='failed', ok=False, error=create.stdout.strip(), finished_at=now_iso(), updated_at=now_iso())
        atomic_json(job_path, status)
        return 1

    stream = None
    owner = None
    processed = 0
    last_update = 0.0
    try:
        stream, total_from_stream, owner = source_stream(source)
        if total_from_stream > 0:
            total = total_from_stream
            status['bytes_total'] = total
        with log_path.open('ab', buffering=0) as log_fh:
            proc = subprocess.Popen(mysql_base + [database], stdin=subprocess.PIPE, stdout=log_fh, stderr=log_fh)
            assert proc.stdin is not None
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                proc.stdin.write(chunk)
                processed += len(chunk)
                now = time.monotonic()
                if now - last_update >= 2:
                    status['bytes_processed'] = processed
                    status['progress'] = round((processed / total * 100.0), 2) if total else 0.0
                    status['updated_at'] = now_iso()
                    atomic_json(job_path, status)
                    last_update = now
            proc.stdin.close()
            rc = proc.wait()
        if rc != 0:
            raise RuntimeError(tail_text(log_path) or f'mysql завершился с кодом {rc}')
        status.update(
            status='done', ok=True, bytes_processed=processed,
            progress=100.0, updated_at=now_iso(), finished_at=now_iso(), error=''
        )
        atomic_json(job_path, status)
        if delete_after:
            try:
                source.unlink()
            except Exception:
                pass
        return 0
    except Exception as exc:
        status.update(
            status='failed', ok=False, bytes_processed=processed,
            progress=round((processed / total * 100.0), 2) if total else 0.0,
            updated_at=now_iso(), finished_at=now_iso(), error=str(exc)[-12000:]
        )
        atomic_json(job_path, status)
        return 1
    finally:
        try:
            if stream is not None:
                stream.close()
        except Exception:
            pass
        try:
            if owner is not None:
                owner.close()
        except Exception:
            pass


def list_jobs(limit: int = 20) -> list[dict]:
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    files = sorted(JOBS_DIR.glob('*.json'), key=lambda p: p.stat().st_mtime, reverse=True)[:limit]
    out = []
    for path in files:
        try:
            item = json.loads(path.read_text('utf-8'))
            if isinstance(item, dict):
                out.append(item)
        except Exception:
            continue
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    p_inspect = sub.add_parser('inspect')
    p_inspect.add_argument('file')
    p_run = sub.add_parser('run')
    p_run.add_argument('--database', required=True)
    p_run.add_argument('--file', required=True)
    p_run.add_argument('--job-id', required=True)
    p_run.add_argument('--keep-file', action='store_true')
    p_list = sub.add_parser('list')
    p_list.add_argument('--limit', type=int, default=20)
    args = parser.parse_args()
    try:
        if args.command == 'inspect':
            print(json.dumps(inspect_source(Path(args.file)), ensure_ascii=False))
            return 0
        if args.command == 'list':
            print(json.dumps(list_jobs(max(1, min(args.limit, 100))), ensure_ascii=False))
            return 0
        if args.command == 'run':
            return run_import(args.database, Path(args.file), args.job_id, delete_after=not args.keep_file)
    except Exception as exc:
        print(json.dumps({'ok': False, 'error': str(exc)}, ensure_ascii=False))
        return 1
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
