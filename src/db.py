"""Пул соединений, миграции и журнал запусков.

Всё остальное в проекте ходит в базу только отсюда. ORM нет сознательно:
вся ценность системы в метриках, а метрики должны читаться человеком
в `.sql`, а не собираться из билдера.
"""

from __future__ import annotations

import argparse
import os
import sys
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

import psycopg
from dotenv import load_dotenv
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

REPO_ROOT = Path(__file__).resolve().parent.parent
MIGRATIONS_DIR = REPO_ROOT / "migrations"

# Реестр применённых миграций. Его нет в 001_schema.sql намеренно: схема —
# часть спеки и правится только через новый нумерованный файл, а реестр —
# служебная таблица самого мигратора.
LEDGER_DDL = """
create table if not exists schema_migration (
  filename   text primary key,
  applied_at timestamptz not null default now()
)
"""

_pool: ConnectionPool | None = None


def pool() -> ConnectionPool:
    """Ленивый пул. Открывается на первом обращении, живёт до close_pool()."""
    global _pool
    if _pool is None:
        load_dotenv(REPO_ROOT / ".env")
        dsn = os.environ.get("DATABASE_URL")
        if not dsn:
            raise RuntimeError(
                "DATABASE_URL не задан. Скопируй .env.example в .env и заполни."
            )
        _pool = ConnectionPool(
            dsn,
            min_size=1,
            max_size=4,
            kwargs={"row_factory": dict_row},
            open=True,
        )
    return _pool


def close_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


@contextmanager
def connection():
    """Соединение из пула. Транзакция коммитится на выходе из блока."""
    with pool().connection() as conn:
        yield conn


class RowCounter:
    """Счётчик записанных строк — уезжает в sync_run.rows_written."""

    def __init__(self) -> None:
        self.rows = 0

    def add(self, n: int) -> None:
        self.rows += n


@contextmanager
def sync_run(job: str) -> Iterator[RowCounter]:
    """Журналирует запуск в sync_run.

    Инвариант 5 из CLAUDE.md: строка пишется при любом запуске. Молча упавший
    крон — самый частый способ потерять две недели, поэтому статус `failed`
    фиксируется до того, как исключение уйдёт наверх.
    """
    with connection() as conn:
        run_id = conn.execute(
            "insert into sync_run (job) values (%s) returning id", (job,)
        ).fetchone()["id"]

    counter = RowCounter()
    try:
        yield counter
    except BaseException as exc:
        with connection() as conn:
            conn.execute(
                "update sync_run set finished_at = now(), status = 'failed',"
                " rows_written = %s, error = %s where id = %s",
                (counter.rows, f"{type(exc).__name__}: {exc}"[:2000], run_id),
            )
        raise
    else:
        with connection() as conn:
            conn.execute(
                "update sync_run set finished_at = now(), status = 'ok',"
                " rows_written = %s where id = %s",
                (counter.rows, run_id),
            )


def record_run(
    job: str,
    started_at: datetime,
    status: str,
    rows_written: int = 0,
    error: str | None = None,
) -> None:
    """Пишет в sync_run уже завершённую строку.

    Нужно ровно для миграций: таблицу sync_run создаёт миграция 001, поэтому
    журналировать собственный bootstrap в реальном времени нечем — строка
    добавляется задним числом, когда таблица уже появилась.
    """
    with connection() as conn:
        conn.execute(
            "insert into sync_run (job, started_at, finished_at, status,"
            " rows_written, error) values (%s, %s, now(), %s, %s, %s)",
            (job, started_at, status, rows_written, error),
        )


def schema_ready() -> bool:
    """Применена ли миграция 001 — по наличию sync_run."""
    with connection() as conn:
        return conn.execute(
            "select to_regclass('public.sync_run') is not null as ready"
        ).fetchone()["ready"]


def pending_migrations() -> list[Path]:
    """Файлы migrations/*.sql, которых ещё нет в реестре, в порядке имён."""
    with connection() as conn:
        conn.execute(LEDGER_DDL)
        done = {
            r["filename"]
            for r in conn.execute("select filename from schema_migration").fetchall()
        }
    return [p for p in sorted(MIGRATIONS_DIR.glob("*.sql")) if p.name not in done]


def migrate() -> list[str]:
    """Применяет миграции по порядку, каждую в своей транзакции.

    Файлы не идемпотентны (`create table` без `if not exists`) — от повторного
    применения защищает реестр, а не сам SQL.
    """
    applied: list[str] = []
    for path in pending_migrations():
        with connection() as conn:
            conn.execute(path.read_text(encoding="utf-8"))
            conn.execute(
                "insert into schema_migration (filename) values (%s)", (path.name,)
            )
        applied.append(path.name)
    return applied


def check() -> None:
    """Печатает список таблиц и содержимое config — критерий готовности T1."""
    with connection() as conn:
        objects = conn.execute(
            "select table_name, table_type from information_schema.tables"
            " where table_schema = 'public'"
            " order by table_type, table_name"
        ).fetchall()
        config_rows = conn.execute(
            "select key, value, comment from config order by key"
        ).fetchall()

    tables = [o["table_name"] for o in objects if o["table_type"] == "BASE TABLE"]
    views = [o["table_name"] for o in objects if o["table_type"] == "VIEW"]

    print(f"\nТаблицы ({len(tables)}):")
    for name in tables:
        print(f"  {name}")

    print(f"\nПредставления ({len(views)}):")
    for name in views:
        print(f"  {name}")

    print(f"\nconfig ({len(config_rows)}):")
    for row in config_rows:
        print(f"  {row['key']} = {row['value']}")
        if row["comment"]:
            print(f"      # {row['comment']}")

    pending = [p.name for p in pending_migrations()]
    if pending:
        print(f"\n⚠ Не применены миграции: {', '.join(pending)}")
    print()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="src.db", description="Миграции и проверка состояния базы."
    )
    parser.add_argument(
        "--migrate", action="store_true", help="применить непринятые миграции"
    )
    parser.add_argument(
        "--check", action="store_true", help="напечатать таблицы и содержимое config"
    )
    args = parser.parse_args(argv)

    if not (args.migrate or args.check):
        parser.error("нужен --migrate или --check")

    try:
        if args.migrate:
            started = datetime.now(timezone.utc)
            try:
                applied = migrate()
            except Exception as exc:
                # Если упала уже не первая миграция, журнал существует —
                # тогда провал надо зафиксировать. Если упала 001, писать некуда.
                try:
                    record_run(
                        "migrate", started, "failed",
                        error=f"{type(exc).__name__}: {exc}"[:2000],
                    )
                except psycopg.errors.UndefinedTable:
                    pass
                raise
            record_run("migrate", started, "ok", rows_written=len(applied))
            if applied:
                print("Применено: " + ", ".join(applied))
            else:
                print("Новых миграций нет.")
        if args.check:
            if not schema_ready():
                print(
                    "Схема не создана. Сначала: uv run python -m src.db --migrate",
                    file=sys.stderr,
                )
                return 3
            with sync_run("db_check"):
                check()
    except RuntimeError as exc:
        # Отсутствующий DATABASE_URL — не баг, трейсбек тут только мешает.
        print(exc, file=sys.stderr)
        return 2
    finally:
        close_pool()
    return 0


if __name__ == "__main__":
    sys.exit(main())
