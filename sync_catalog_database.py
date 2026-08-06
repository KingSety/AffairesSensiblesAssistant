"""Merge catalog metadata into the SQLite data pack without transcribing audio."""

from __future__ import annotations

import argparse
from pathlib import Path
import sqlite3

from deepgram_api import (
    CATALOG_PATH,
    DATABASE_PATH,
    initialize_database,
    load_catalog,
    sync_catalog,
)
from import_catalog_transcripts import (
    DEFAULT_WORKING_DATABASE_PATH,
    copy_database,
    prepare_working_database,
)


def sync_catalog_database(
    catalog_path: Path = CATALOG_PATH,
    database_path: Path = DEFAULT_WORKING_DATABASE_PATH,
    bundled_database_path: Path = DATABASE_PATH,
    *,
    vacuum: bool = True,
) -> tuple[int, int]:
    prepare_working_database(database_path, bundled_database_path)
    episodes = load_catalog(catalog_path)

    with initialize_database(database_path) as database:
        catalog_count = sync_catalog(database, episodes)
        transcript_count = database.execute(
            "SELECT COUNT(*) FROM episode_transcripts"
        ).fetchone()[0]
        if vacuum:
            database.execute("VACUUM")

    copy_database(database_path, bundled_database_path)
    return catalog_count, transcript_count


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Merge the JSON catalog into the unified SQLite app data pack."
    )
    parser.add_argument("--catalog", type=Path, default=CATALOG_PATH)
    parser.add_argument("--database", type=Path, default=DEFAULT_WORKING_DATABASE_PATH)
    parser.add_argument("--bundle-database", type=Path, default=DATABASE_PATH)
    parser.add_argument(
        "--no-vacuum",
        action="store_true",
        help="Skip reclaiming space left by the legacy transcript/summary table.",
    )
    arguments = parser.parse_args()

    try:
        catalog_count, transcript_count = sync_catalog_database(
            catalog_path=arguments.catalog,
            database_path=arguments.database,
            bundled_database_path=arguments.bundle_database,
            vacuum=not arguments.no_vacuum,
        )
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.error(str(error))

    print(
        f"Published {catalog_count} catalog episodes with "
        f"{transcript_count} transcripts to {arguments.bundle_database}."
    )


if __name__ == "__main__":
    main()
