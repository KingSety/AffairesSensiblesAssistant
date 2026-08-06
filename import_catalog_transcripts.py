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

from deepgram import DeepgramClient
from dotenv import load_dotenv

from deepgram_api import (
    DATABASE_PATH,
    OUTPUT_DIR,
    get_api_key,
    initialize_database,
    load_catalog,
    mark_episode_unavailable,
    sync_catalog,
    transcribe_file,
    transcribe_url,
    upsert_episode,
)
from download import (
    DEFAULT_RADIO_FRANCE_RSS_URL,
    EpisodeAudioResolver,
    MediaUnavailableError,
)


ROOT_DIR = Path(__file__).resolve().parent
DEFAULT_CATALOG_PATH = ROOT_DIR / "ios" / "Resources" / "imported_episodes.json"
DEFAULT_FAILURE_LOG_PATH = ROOT_DIR / "transcript_import_failures.json"
DEFAULT_WORKING_DATABASE_PATH = ROOT_DIR / "ios" / "Working" / "episodes.sqlite"
DEFAULT_LOCAL_AUDIO_DIR = ROOT_DIR / "Audio"


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


def source_file_name(episode: dict[str, object]) -> str:
    return f"{episode['title']}.m4a"


def existing_episode_ids(database: sqlite3.Connection) -> set[str]:
    return {
        row[0]
        for row in database.execute(
            "SELECT episode_id FROM episode_transcripts WHERE trim(transcript) != ''"
        )
    }


def existing_source_files(database: sqlite3.Connection) -> set[str]:
    return {
        row[0]
        for row in database.execute(
            """
            SELECT e.source_file
            FROM episodes AS e
            JOIN episode_transcripts AS t ON t.episode_id = e.id
            WHERE trim(t.transcript) != ''
            """
        )
    }


def transcribe_episode(
    database: sqlite3.Connection,
    deepgram: DeepgramClient,
    audio_resolver: EpisodeAudioResolver,
    episode: dict[str, object],
    retries: int,
    timeout_seconds: int,
) -> None:
    for attempt in range(retries + 1):
        try:
            with episode_deadline(timeout_seconds):
                audio = audio_resolver.resolve(episode)
                if audio.is_local_file:
                    transcript = transcribe_file(deepgram, Path(audio.location))
                else:
                    transcript = transcribe_url(deepgram, str(audio.location))

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
        except MediaUnavailableError:
            raise
        except Exception as error:
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
    for sidecar in (
        destination_path.with_name(f"{destination_path.name}-wal"),
        destination_path.with_name(f"{destination_path.name}-shm"),
    ):
        sidecar.unlink(missing_ok=True)
    os.replace(temporary_path, destination_path)


def prepare_working_database(database_path: Path, bundled_database_path: Path) -> None:
    if database_path.exists() or not bundled_database_path.exists():
        return
    copy_database(bundled_database_path, database_path)


def has_resolved_every_catalog_episode(
    catalog_path: Path,
    database_path: Path,
) -> bool:
    expected_ids = {episode["id"] for episode in load_catalog(catalog_path)}
    with sqlite3.connect(database_path) as database:
        resolved_ids = {
            row[0]
            for row in database.execute(
                """
                SELECT id
                FROM episodes
                WHERE media_status = 'unavailable'
                   OR EXISTS (
                       SELECT 1 FROM episode_transcripts
                       WHERE episode_id = episodes.id AND trim(transcript) != ''
                   )
                """
            )
        }
    return expected_ids.issubset(resolved_ids)


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
    audio_dir: Path | None,
    rss_feed_url: str,
) -> tuple[int, int, int, int]:
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
    audio_resolver = EpisodeAudioResolver(
        audio_dir=audio_dir,
        rss_feed_url=rss_feed_url,
    )
    imported = 0
    skipped = 0
    unavailable = 0
    failures: list[dict[str, str]] = []
    prepare_working_database(database_path, bundled_database_path)

    with initialize_database(database_path) as database:
        sync_catalog(database, episodes)
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
                    audio_resolver,
                    episode,
                    retries,
                    timeout_seconds,
                )
            except KeyboardInterrupt:
                write_failure_log(failures, failure_log_path)
                raise
            except MediaUnavailableError as error:
                database.rollback()
                mark_episode_unavailable(database, episode_id, str(error))
                database.commit()
                unavailable += 1
                failures.append(
                    {
                        "id": episode_id,
                        "title": episode["title"],
                        "source_url": episode["source_url"],
                        "status": "unavailable",
                        "error": str(error),
                    }
                )
                print(f"Unavailable: {error}")
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
    unresolved_failures = [
        failure for failure in failures if failure.get("status") != "unavailable"
    ]
    if (
        limit is None
        and not unresolved_failures
        and has_resolved_every_catalog_episode(catalog_path, database_path)
    ):
        print("Building the persistent local transcript index…")
        prebuild_local_search_index(database_path)
    copy_database(database_path, bundled_database_path)
    return imported, skipped, unavailable, len(unresolved_failures)


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
    parser.add_argument(
        "--audio-dir",
        type=Path,
        default=DEFAULT_LOCAL_AUDIO_DIR,
        help=(
            "Folder containing fallback audio named by episode ID, Radio France ID, "
            "or exact episode title."
        ),
    )
    parser.add_argument(
        "--rss-feed-url",
        default=DEFAULT_RADIO_FRANCE_RSS_URL,
        help="Official podcast RSS feed used when an episode page has no audio URL.",
    )
    arguments = parser.parse_args()

    imported, skipped, unavailable, failed = import_catalog(
        catalog_path=arguments.catalog,
        database_path=arguments.database,
        bundled_database_path=arguments.bundle_database,
        failure_log_path=arguments.failure_log,
        retries=arguments.retries,
        delay_seconds=arguments.delay,
        timeout_seconds=arguments.episode_timeout,
        limit=arguments.limit,
        publish_every=arguments.publish_every,
        audio_dir=arguments.audio_dir,
        rss_feed_url=arguments.rss_feed_url,
    )
    print(
        f"Imported: {imported}; skipped: {skipped}; "
        f"unavailable: {unavailable}; failed: {failed}"
    )


if __name__ == "__main__":
    main()
