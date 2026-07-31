"""Download and transcribe a Radio France catalog without retaining audio."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import time
from typing import Any

from deepgram import DeepgramClient
from dotenv import load_dotenv

from deepgram_api import (
    DATABASE_PATH,
    OUTPUT_DIR,
    get_api_key,
    initialize_database,
    transcribe_url,
    upsert_episode,
)
from download import resolve_audio_url


ROOT_DIR = Path(__file__).resolve().parent
DEFAULT_CATALOG_PATH = ROOT_DIR / "ios" / "Resources" / "imported_episodes.json"
DEFAULT_FAILURE_LOG_PATH = ROOT_DIR / "transcript_import_failures.json"
DEFAULT_WORKING_DATABASE_PATH = ROOT_DIR / "ios" / "Working" / "episodes.sqlite"


class EpisodeTimeoutError(TimeoutError):
    pass


@contextmanager
def episode_deadline(seconds: int):
    def raise_timeout(_: int, __: object) -> None:
        raise EpisodeTimeoutError(f"Episode request exceeded {seconds} seconds.")

    previous_handler = signal.signal(signal.SIGALRM, raise_timeout)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)


def load_catalog(catalog_path: Path) -> list[dict[str, Any]]:
    payload = json.loads(catalog_path.read_text(encoding="utf-8"))
    if not isinstance(payload, list):
        raise ValueError(f"Catalog at {catalog_path} must contain an episode list.")

    episodes: list[dict[str, Any]] = []
    for item in payload:
        if not isinstance(item, dict):
            continue
        required_fields = ("id", "title", "source_url")
        if all(isinstance(item.get(field), str) and item[field].strip() for field in required_fields):
            episodes.append(item)
    if not episodes:
        raise ValueError(f"Catalog at {catalog_path} has no valid episodes.")
    return episodes


def source_file_name(episode: dict[str, Any]) -> str:
    return f"{episode['title']}.m4a"


def is_permanently_unavailable_media(error: Exception) -> bool:
    message = str(error).casefold()
    return any(
        marker in message
        for marker in (
            "http error 404",
            "unable to extract audio data",
            "could not resolve an audio url",
        )
    )


def existing_episode_ids(database: sqlite3.Connection) -> set[str]:
    return {row[0] for row in database.execute("SELECT id FROM episodes")}


def existing_source_files(database: sqlite3.Connection) -> set[str]:
    return {row[0] for row in database.execute("SELECT source_file FROM episodes")}


def transcribe_episode(
    database: sqlite3.Connection,
    deepgram: DeepgramClient,
    episode: dict[str, Any],
    retries: int,
    timeout_seconds: int,
) -> None:
    for attempt in range(retries + 1):
        try:
            with episode_deadline(timeout_seconds):
                audio_url = resolve_audio_url(episode["source_url"])
                transcript = transcribe_url(deepgram, audio_url)

            transcript_path = OUTPUT_DIR / f"{episode['id']}.txt"
            transcript_path.write_text(transcript, encoding="utf-8")
            upsert_episode(
                database=database,
                audio_path=Path(source_file_name(episode)),
                transcript_path=transcript_path,
                transcript=transcript,
                episode_id=episode["id"],
                source_file=source_file_name(episode),
            )
            database.commit()
            return
        except KeyboardInterrupt:
            raise
        except Exception as error:
            if is_permanently_unavailable_media(error):
                raise
            if attempt == retries:
                raise
            time.sleep(2**attempt)


def write_failure_log(failures: list[dict[str, str]], path: Path) -> None:
    if failures:
        path.write_text(
            json.dumps(failures, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    else:
        path.unlink(missing_ok=True)


def copy_database(source_path: Path, destination_path: Path) -> None:
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = destination_path.with_name(f"{destination_path.name}.tmp")
    temporary_path.unlink(missing_ok=True)

    source = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True)
    destination = sqlite3.connect(temporary_path)
    try:
        source.backup(destination)
        destination.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        destination.execute("PRAGMA journal_mode=DELETE")
        destination.commit()
    finally:
        destination.close()
        source.close()
    os.replace(temporary_path, destination_path)


def prepare_working_database(database_path: Path, bundled_database_path: Path) -> None:
    if database_path.exists() or not bundled_database_path.exists():
        return
    copy_database(bundled_database_path, database_path)


def has_every_catalog_transcript(
    catalog_path: Path,
    database_path: Path,
) -> bool:
    expected_ids = {episode["id"] for episode in load_catalog(catalog_path)}
    with sqlite3.connect(database_path) as database:
        completed_ids = existing_episode_ids(database)
    return expected_ids.issubset(completed_ids)


def prebuild_local_search_index(database_path: Path) -> None:
    package_path = ROOT_DIR / "ios" / "LocalVectorSearch"
    subprocess.run(
        [
            "xcrun",
            "swift",
            "run",
            "--package-path",
            str(package_path),
            "build-episode-embeddings",
            str(database_path),
        ],
        check=True,
    )


def import_catalog(
    catalog_path: Path,
    database_path: Path,
    bundled_database_path: Path,
    failure_log_path: Path,
    retries: int,
    delay_seconds: float,
    timeout_seconds: int,
    limit: int | None,
    publish_every: int,
) -> tuple[int, int, int]:
    episodes = load_catalog(catalog_path)
    if limit is not None:
        episodes = episodes[:limit]
    if retries < 0:
        raise ValueError("Retries must be zero or greater.")
    if delay_seconds < 0:
        raise ValueError("Delay must be zero or greater.")
    if timeout_seconds <= 0:
        raise ValueError("Episode timeout must be greater than zero.")
    if publish_every <= 0:
        raise ValueError("Publish interval must be greater than zero.")

    load_dotenv()
    deepgram = DeepgramClient(api_key=get_api_key(), timeout=90, max_retries=1)
    imported = 0
    skipped = 0
    failures: list[dict[str, str]] = []
    prepare_working_database(database_path, bundled_database_path)

    with initialize_database(database_path) as database:
        completed_ids = existing_episode_ids(database)
        completed_source_files = existing_source_files(database)

        for index, episode in enumerate(episodes, start=1):
            episode_id = episode["id"]
            source_file = source_file_name(episode)
            if episode_id in completed_ids or source_file in completed_source_files:
                skipped += 1
                continue

            print(f"[{index}/{len(episodes)}] Transcribing {episode['title']}")
            try:
                transcribe_episode(
                    database,
                    deepgram,
                    episode,
                    retries,
                    timeout_seconds,
                )
            except KeyboardInterrupt:
                write_failure_log(failures, failure_log_path)
                raise
            except Exception as error:
                database.rollback()
                failures.append(
                    {
                        "id": episode_id,
                        "title": episode["title"],
                        "source_url": episode["source_url"],
                        "error": str(error),
                    }
                )
                print(f"Failed: {error}")
            else:
                completed_ids.add(episode_id)
                completed_source_files.add(source_file)
                imported += 1
                if imported % publish_every == 0:
                    copy_database(database_path, bundled_database_path)

            if delay_seconds:
                time.sleep(delay_seconds)

    write_failure_log(failures, failure_log_path)
    if limit is None and not failures and has_every_catalog_transcript(catalog_path, database_path):
        print("Building the persistent local transcript index…")
        prebuild_local_search_index(database_path)
    copy_database(database_path, bundled_database_path)
    return imported, skipped, len(failures)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Transcribe catalog episodes without retaining audio files."
    )
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG_PATH)
    parser.add_argument("--database", type=Path, default=DEFAULT_WORKING_DATABASE_PATH)
    parser.add_argument("--bundle-database", type=Path, default=DATABASE_PATH)
    parser.add_argument("--failure-log", type=Path, default=DEFAULT_FAILURE_LOG_PATH)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--delay", type=float, default=0.5)
    parser.add_argument(
        "--episode-timeout",
        type=int,
        default=300,
        help="Maximum seconds allowed for one media URL and Deepgram transcription.",
    )
    parser.add_argument("--limit", type=int)
    parser.add_argument("--publish-every", type=int, default=5)
    arguments = parser.parse_args()

    imported, skipped, failed = import_catalog(
        catalog_path=arguments.catalog,
        database_path=arguments.database,
        bundled_database_path=arguments.bundle_database,
        failure_log_path=arguments.failure_log,
        retries=arguments.retries,
        delay_seconds=arguments.delay,
        timeout_seconds=arguments.episode_timeout,
        limit=arguments.limit,
        publish_every=arguments.publish_every,
    )
    print(f"Imported: {imported}; skipped: {skipped}; failed: {failed}")


if __name__ == "__main__":
    main()
