#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import json
import os
import re
import signal
import subprocess
import threading
import time
import zipfile
from pathlib import Path
from typing import BinaryIO

IMPORT_ROOT = Path('/opt/hyper-host/imports')
JOBS_DIR = IMPORT_ROOT / 'jobs'
LOGS_DIR = IMPORT_ROOT / 'logs'
UPLOADS_DIR = IMPORT_ROOT / 'uploads'
CANCEL_DIR = IMPORT_ROOT / 'cancel'


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def parse_iso(value: str) -> dt.datetime | None:
    try:
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except Exception:
        return None


def safe_db_name(value: str) -> str:
    if not re.fullmatch(r'[A-Za-z0-9_]{2,64}', value or ''):
        raise ValueError('Некорректное имя базы данных')
    return value


def safe_job_id(value: str) -> str:
    if not re.fullmatch(r'[A-Za-z0-9_.-]{5,160}', value or ''):
        raise ValueError('Некорректный ID задания')
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


def tail_text(path: Path, limit: int = 16000) -> str:
    try:
        with path.open('rb') as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - limit))
            return fh.read().decode('utf-8', errors='replace')
    except Exception:
        return ''


def find_job_pid(job_id: str) -> int:
    try:
        cp = subprocess.run(['pgrep', '-f', rf'hyper_sql_import\.py run .*--job-id {re.escape(job_id)}(?: |$)'],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5)
        for raw in cp.stdout.splitlines():
            try:
                pid=int(raw.strip())
                if pid > 1 and pid != os.getpid():
                    return pid
            except Exception:
                continue
    except Exception:
        pass
    return 0


def process_alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def database_metrics(database: str) -> tuple[int, int]:
    query = (
        "SELECT COUNT(*),COALESCE(SUM(DATA_LENGTH+INDEX_LENGTH),0) "
        "FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=" + repr(database) + ";"
    )
    try:
        cp = subprocess.run(
            ['mysql', '--protocol=socket', '-uroot', '--batch', '--skip-column-names', '-e', query],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15,
        )
        if cp.returncode == 0:
            parts = cp.stdout.strip().split('\t')
            if len(parts) >= 2:
                return int(parts[0] or 0), int(parts[1] or 0)
    except Exception:
        pass
    return 0, 0


def run_import(database: str, source: Path, job_id: str, delete_after: bool = True) -> int:
    database = safe_db_name(database)
    job_id = safe_job_id(job_id)
    source = source.resolve()
    for d in (IMPORT_ROOT, JOBS_DIR, LOGS_DIR, UPLOADS_DIR, CANCEL_DIR):
        d.mkdir(parents=True, exist_ok=True)
    job_path = JOBS_DIR / f'{job_id}.json'
    log_path = LOGS_DIR / f'{job_id}.log'
    cancel_path = CANCEL_DIR / job_id
    meta = inspect_source(source)
    total = int(meta.get('uncompressed_size') or meta.get('compressed_size') or 0)
    started_monotonic = time.monotonic()
    status = {
        'ok': True, 'job_id': job_id, 'status': 'running', 'database': database,
        'source': str(source), 'source_name': source.name, 'format': meta.get('format'),
        'member': meta.get('member', ''), 'compressed_size': int(meta.get('compressed_size') or 0),
        'bytes_total': total, 'bytes_processed': 0, 'progress': 0.0,
        'speed_mib_s': 0.0, 'eta_seconds': None, 'elapsed_seconds': 0,
        'tables_count': 0, 'database_size_bytes': 0,
        'pid': os.getpid(), 'mysql_pid': 0, 'heartbeat_at': now_iso(),
        'last_progress_at': now_iso(), 'started_at': now_iso(), 'updated_at': now_iso(),
        'finished_at': '', 'log': str(log_path), 'log_tail': '', 'error': '',
    }
    atomic_json(job_path, status)

    mysql_base = [
        'mysql', '--protocol=socket', '-uroot', '--default-character-set=utf8mb4',
        '--binary-mode=1', '--max_allowed_packet=1G', '--connect-timeout=60',
        '--init-command=SET SESSION foreign_key_checks=0; SET SESSION unique_checks=0;',
    ]
    create = subprocess.run(
        mysql_base + ['-e', f'CREATE DATABASE IF NOT EXISTS `{database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    if create.returncode != 0:
        status.update(status='failed', ok=False, error=create.stdout.strip(), finished_at=now_iso(), updated_at=now_iso())
        atomic_json(job_path, status)
        return 1

    stream: BinaryIO | None = None
    owner: object | None = None
    proc: subprocess.Popen | None = None
    shared = {'processed': 0, 'last_progress': time.monotonic(), 'error': '', 'finished': False}
    lock = threading.Lock()

    try:
        stream, total_from_stream, owner = source_stream(source)
        if total_from_stream > 0:
            total = total_from_stream
            status['bytes_total'] = total
        log_fh = log_path.open('ab', buffering=0)
        proc = subprocess.Popen(
            mysql_base + [database], stdin=subprocess.PIPE, stdout=log_fh, stderr=log_fh,
            start_new_session=True,
        )
        status['mysql_pid'] = proc.pid
        atomic_json(job_path, status)
        assert proc.stdin is not None

        def feeder() -> None:
            try:
                while True:
                    if cancel_path.exists():
                        raise RuntimeError('Импорт отменён пользователем')
                    chunk = stream.read(8 * 1024 * 1024)
                    if not chunk:
                        break
                    proc.stdin.write(chunk)
                    with lock:
                        shared['processed'] += len(chunk)
                        shared['last_progress'] = time.monotonic()
                proc.stdin.close()
            except Exception as exc:
                with lock:
                    shared['error'] = str(exc)
                try:
                    proc.stdin.close()
                except Exception:
                    pass
            finally:
                with lock:
                    shared['finished'] = True

        thread = threading.Thread(target=feeder, name=f'hyper-sql-{job_id}', daemon=True)
        thread.start()
        last_metrics = 0.0
        while thread.is_alive() or proc.poll() is None:
            now_mono = time.monotonic()
            with lock:
                processed = int(shared['processed'])
                last_progress = float(shared['last_progress'])
                feeder_error = str(shared['error'])
            elapsed = max(0.001, now_mono - started_monotonic)
            speed = processed / elapsed / 1024 / 1024
            remaining = max(0, total - processed)
            eta = int(remaining / (speed * 1024 * 1024)) if speed > 0.01 and total else None
            waiting = now_mono - last_progress > 60 and proc.poll() is None
            if now_mono - last_metrics >= 10:
                tables, db_size = database_metrics(database)
                last_metrics = now_mono
            else:
                tables = int(status.get('tables_count') or 0)
                db_size = int(status.get('database_size_bytes') or 0)
            status.update(
                status='waiting_mysql' if waiting else 'running', ok=True,
                bytes_processed=processed,
                progress=round(processed / total * 100.0, 2) if total else 0.0,
                speed_mib_s=round(speed, 2), eta_seconds=eta,
                elapsed_seconds=int(elapsed), tables_count=tables, database_size_bytes=db_size,
                heartbeat_at=now_iso(), updated_at=now_iso(), log_tail=tail_text(log_path, 3000),
            )
            atomic_json(job_path, status)
            if cancel_path.exists() or feeder_error:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except Exception:
                    proc.terminate()
            if proc.poll() is not None and thread.is_alive():
                break
            time.sleep(3)

        thread.join(timeout=30)
        rc = proc.wait(timeout=60)
        log_fh.close()
        with lock:
            processed = int(shared['processed'])
            feeder_error = str(shared['error'])
        if cancel_path.exists():
            raise RuntimeError('Импорт отменён пользователем')
        if feeder_error:
            raise RuntimeError(feeder_error)
        if rc != 0:
            raise RuntimeError(tail_text(log_path) or f'mysql завершился с кодом {rc}')
        tables, db_size = database_metrics(database)
        elapsed = max(0.001, time.monotonic() - started_monotonic)
        status.update(
            status='done', ok=True, bytes_processed=processed, progress=100.0,
            speed_mib_s=round(processed / elapsed / 1024 / 1024, 2), eta_seconds=0,
            elapsed_seconds=int(elapsed), tables_count=tables, database_size_bytes=db_size,
            heartbeat_at=now_iso(), updated_at=now_iso(), finished_at=now_iso(),
            log_tail=tail_text(log_path, 3000), error='',
        )
        atomic_json(job_path, status)
        if delete_after:
            try:
                source.unlink()
            except Exception:
                pass
        cancel_path.unlink(missing_ok=True)
        return 0
    except Exception as exc:
        if proc and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except Exception:
                proc.terminate()
        processed = int(shared.get('processed') or 0)
        tables, db_size = database_metrics(database)
        status.update(
            status='cancelled' if 'отменён' in str(exc).lower() else 'failed', ok=False,
            bytes_processed=processed,
            progress=round(processed / total * 100.0, 2) if total else 0.0,
            elapsed_seconds=int(max(0, time.monotonic() - started_monotonic)),
            tables_count=tables, database_size_bytes=db_size,
            heartbeat_at=now_iso(), updated_at=now_iso(), finished_at=now_iso(),
            log_tail=tail_text(log_path, 6000), error=str(exc)[-12000:],
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
                owner.close()  # type: ignore[attr-defined]
        except Exception:
            pass


def normalize_job(item: dict, path: Path) -> dict:
    status = str(item.get('status') or '')
    pid = int(item.get('pid') or 0)
    if pid <= 1 and status in {'queued', 'running', 'waiting_mysql'}:
        pid=find_job_pid(str(item.get('job_id') or ''))
        if pid > 1:
            item['pid']=pid
    heartbeat = parse_iso(str(item.get('heartbeat_at') or item.get('updated_at') or ''))
    age = int((dt.datetime.now(dt.timezone.utc) - heartbeat).total_seconds()) if heartbeat else 999999
    if status in {'queued', 'running', 'waiting_mysql'} and not process_alive(pid) and age > 20:
        launcher = LOGS_DIR / f"{item.get('job_id','')}-launcher.log"
        item.update(
            ok=False, status='failed', finished_at=now_iso(), updated_at=now_iso(),
            error=(tail_text(launcher) or tail_text(Path(str(item.get('log') or ''))) or 'Процесс импорта завершился без результата')[-12000:],
        )
        atomic_json(path, item)
    item['worker_alive'] = process_alive(pid)
    item['heartbeat_age_seconds'] = age
    if status in {'queued','running','waiting_mysql'} and item.get('database'):
        tables, db_size=database_metrics(str(item['database']))
        item['tables_count']=max(int(item.get('tables_count') or 0), tables)
        item['database_size_bytes']=max(int(item.get('database_size_bytes') or 0), db_size)
    return item


def list_jobs(limit: int = 20) -> list[dict]:
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    files = sorted(JOBS_DIR.glob('*.json'), key=lambda p: p.stat().st_mtime, reverse=True)[:limit]
    out = []
    for path in files:
        try:
            item = json.loads(path.read_text('utf-8'))
            if isinstance(item, dict):
                out.append(normalize_job(item, path))
        except Exception:
            continue
    return out


def cancel_job(job_id: str) -> dict:
    job_id = safe_job_id(job_id)
    CANCEL_DIR.mkdir(parents=True, exist_ok=True)
    (CANCEL_DIR / job_id).write_text(now_iso(), encoding='utf-8')
    job_path = JOBS_DIR / f'{job_id}.json'
    pid = 0
    if job_path.exists():
        try:
            item = json.loads(job_path.read_text('utf-8'))
            pid = int(item.get('mysql_pid') or item.get('pid') or 0)
        except Exception:
            pass
    if pid > 1:
        try:
            os.killpg(pid, signal.SIGTERM)
        except Exception:
            try: os.kill(pid, signal.SIGTERM)
            except Exception: pass
    return {'ok': True, 'job_id': job_id, 'cancel_requested': True}


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    p_inspect = sub.add_parser('inspect'); p_inspect.add_argument('file')
    p_run = sub.add_parser('run')
    p_run.add_argument('--database', required=True); p_run.add_argument('--file', required=True); p_run.add_argument('--job-id', required=True); p_run.add_argument('--keep-file', action='store_true')
    p_list = sub.add_parser('list'); p_list.add_argument('--limit', type=int, default=20)
    p_cancel = sub.add_parser('cancel'); p_cancel.add_argument('job_id')
    p_log = sub.add_parser('log'); p_log.add_argument('job_id')
    args = parser.parse_args()
    try:
        if args.command == 'inspect':
            print(json.dumps(inspect_source(Path(args.file)), ensure_ascii=False)); return 0
        if args.command == 'list':
            print(json.dumps(list_jobs(max(1, min(args.limit, 100))), ensure_ascii=False)); return 0
        if args.command == 'cancel':
            print(json.dumps(cancel_job(args.job_id), ensure_ascii=False)); return 0
        if args.command == 'log':
            print(tail_text(LOGS_DIR / f'{safe_job_id(args.job_id)}.log', 50000)); return 0
        if args.command == 'run':
            return run_import(args.database, Path(args.file), args.job_id, delete_after=not args.keep_file)
    except Exception as exc:
        print(json.dumps({'ok': False, 'error': str(exc)}, ensure_ascii=False)); return 1
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
