import hashlib
import json
import mimetypes
import os
from pathlib import Path
import sqlite3
import sys
from typing import Any, Iterable

import httpx
from deepgram import DeepgramClient
from deepgram.core.api_error import ApiError
from dotenv import load_dotenv


load_dotenv()


def get_required_env(name: str) -> str:
    value = os.getenv(name)

    if not value or not value.strip():
        raise ValueError(f"{name} not found.")

    return value.strip()


def get_api_key() -> str:
    return get_required_env("DEEPGRAM_API_KEY")


ROOT_DIR = Path(__file__).resolve().parent
AUDIO_DIR = ROOT_DIR / "Audio"
OUTPUT_DIR = ROOT_DIR / "Transcripts"
OUTPUT_DIR.mkdir(exist_ok=True)
IOS_RESOURCES_DIR = ROOT_DIR / "ios" / "Resources"
DATABASE_PATH = IOS_RESOURCES_DIR / "episodes.sqlite"
CATALOG_PATH = IOS_RESOURCES_DIR / "imported_episodes.json"
DATABASE_SCHEMA_VERSION = 3

# Common audio/video extensions we want to accept
AUDIO_EXTENSIONS = {
    ".m4a",
    ".mp3",
    ".wav",
    ".flac",
    ".aac",
    ".ogg",
    ".opus",
    ".webm",
    ".mp4",
    ".mov",
    ".mkv",
}


def is_audio_file(path: Path) -> bool:
    if not path.is_file():
        return False
    suffix = path.suffix.lower()
    if suffix in AUDIO_EXTENSIONS:
        return True
    mime, _ = mimetypes.guess_type(str(path))
    if mime and (mime.startswith("audio/") or mime.startswith("video/")):
        return True
    return False


def transcribe_file(deepgram, audio_path: Path):
    with audio_path.open("rb") as audio_file:
        response = deepgram.listen.v1.media.transcribe_file(
            request=audio_file.read(),
            model="nova-3",
            language="fr",
            smart_format=True,
            paragraphs=True,
        )
    return response.results.channels[0].alternatives[0].transcript


def transcribe_url(deepgram, audio_url: str):
    response = deepgram.listen.v1.media.transcribe_url(
        url=audio_url,
        model="nova-3",
        language="fr",
        smart_format=True,
        paragraphs=True,
    )
    return response.results.channels[0].alternatives[0].transcript


def _table_columns(database: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in database.execute(f"PRAGMA table_info({table})")}


def _create_episode_schema(database: sqlite3.Connection) -> None:
    database.execute(
        """
        CREATE TABLE IF NOT EXISTS episodes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            short_description TEXT NOT NULL DEFAULT '',
            source_url TEXT NOT NULL DEFAULT '',
            artwork_url TEXT NOT NULL DEFAULT '',
            language TEXT NOT NULL DEFAULT 'fr',
            published_date TEXT,
            duration_seconds INTEGER,
            catalog_position INTEGER NOT NULL DEFAULT 0,
            transcript_status TEXT NOT NULL DEFAULT 'missing'
                CHECK (transcript_status IN ('available', 'description_only', 'missing')),
            media_status TEXT NOT NULL DEFAULT 'unknown'
                CHECK (media_status IN ('available', 'unavailable', 'unknown')),
            availability_message TEXT NOT NULL DEFAULT '',
            source_file TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    database.execute(
        """
        CREATE TABLE IF NOT EXISTS episode_transcripts (
            episode_id TEXT PRIMARY KEY,
            transcript_file TEXT NOT NULL DEFAULT '',
            transcript TEXT NOT NULL,
            embedding BLOB,
            embedding_dimension INTEGER,
            embedding_revision INTEGER,
            embedding_language TEXT,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (episode_id) REFERENCES episodes(id) ON DELETE CASCADE
        )
        """
    )
    if "catalog_position" not in _table_columns(database, "episodes"):
        database.execute(
            "ALTER TABLE episodes ADD COLUMN catalog_position INTEGER NOT NULL DEFAULT 0"
        )
    if "media_status" not in _table_columns(database, "episodes"):
        database.execute(
            "ALTER TABLE episodes ADD COLUMN media_status TEXT NOT NULL "
            "DEFAULT 'unknown' CHECK (media_status IN "
            "('available', 'unavailable', 'unknown'))"
        )
    if "availability_message" not in _table_columns(database, "episodes"):
        database.execute(
            "ALTER TABLE episodes ADD COLUMN availability_message TEXT NOT NULL DEFAULT ''"
        )
    database.execute(
        "CREATE INDEX IF NOT EXISTS episodes_source_file_idx ON episodes(source_file)"
    )
    database.execute(
        "CREATE INDEX IF NOT EXISTS episodes_published_date_idx "
        "ON episodes(published_date DESC)"
    )
    database.execute(
        "CREATE INDEX IF NOT EXISTS episodes_catalog_position_idx "
        "ON episodes(catalog_position)"
    )


def _migrate_legacy_episode_schema(database: sqlite3.Connection) -> None:
    columns = _table_columns(database, "episodes")
    if not columns or "transcript" not in columns:
        return

    database.execute("PRAGMA foreign_keys = OFF")
    database.execute("BEGIN IMMEDIATE")
    try:
        database.execute("ALTER TABLE episodes RENAME TO episodes_legacy")
        _create_episode_schema(database)
        database.execute(
            """
            INSERT INTO episodes (
                id, title, short_description, source_url, artwork_url,
                language, transcript_status, media_status,
                availability_message, source_file, updated_at
            )
            SELECT id, source_file, '', '', '',
                   COALESCE(NULLIF(embedding_language, ''), 'fr'),
                   CASE WHEN trim(transcript) = '' THEN 'missing' ELSE 'available' END,
                   CASE WHEN trim(transcript) = '' THEN 'unknown' ELSE 'available' END,
                   '', source_file, updated_at
            FROM episodes_legacy
            """
        )
        database.execute(
            """
            INSERT INTO episode_transcripts (
                episode_id, transcript_file, transcript, embedding,
                embedding_dimension, embedding_revision, embedding_language, updated_at
            )
            SELECT id, transcript_file, transcript, embedding,
                   embedding_dimension, embedding_revision, embedding_language, updated_at
            FROM episodes_legacy
            WHERE trim(transcript) != ''
            """
        )
        database.execute("DROP TABLE episodes_legacy")
        database.execute(f"PRAGMA user_version = {DATABASE_SCHEMA_VERSION}")
        database.commit()
    except Exception:
        database.rollback()
        raise
    finally:
        database.execute("PRAGMA foreign_keys = ON")


def initialize_database(database_path: Path = DATABASE_PATH) -> sqlite3.Connection:
    database_path.parent.mkdir(parents=True, exist_ok=True)
    database = sqlite3.connect(database_path)
    _migrate_legacy_episode_schema(database)
    database.execute("PRAGMA foreign_keys = ON")
    _create_episode_schema(database)
    database.execute(f"PRAGMA user_version = {DATABASE_SCHEMA_VERSION}")
    database.commit()
    return database


def load_catalog(catalog_path: Path = CATALOG_PATH) -> list[dict[str, Any]]:
    payload = json.loads(catalog_path.read_text(encoding="utf-8"))
    if not isinstance(payload, list):
        raise ValueError(f"Catalog at {catalog_path} must contain an episode list.")

    episodes: list[dict[str, Any]] = []
    for item in payload:
        if not isinstance(item, dict):
            continue
        required_fields = ("id", "title", "source_url")
        if all(
            isinstance(item.get(field), str) and item[field].strip()
            for field in required_fields
        ):
            episodes.append(item)
    if not episodes:
        raise ValueError(f"Catalog at {catalog_path} has no valid episodes.")
    return episodes


def sync_catalog(
    database: sqlite3.Connection,
    episodes: Iterable[dict[str, Any]],
) -> int:
    rows = []
    for position, episode in enumerate(episodes):
        description = str(episode.get("description") or "").strip()
        title = str(episode["title"]).strip()
        rows.append(
            (
                str(episode["id"]),
                title,
                description,
                str(episode.get("source_url") or ""),
                str(episode.get("artwork_url") or ""),
                str(episode.get("language") or "fr"),
                episode.get("published_date"),
                episode.get("duration_seconds"),
                position,
                "description_only" if description else "missing",
                "unknown",
                "",
                f"{title}.m4a",
            )
        )

    database.executemany(
        """
        INSERT INTO episodes (
            id, title, short_description, source_url, artwork_url, language,
            published_date, duration_seconds, catalog_position,
            transcript_status, media_status, availability_message, source_file
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            short_description = excluded.short_description,
            source_url = excluded.source_url,
            artwork_url = excluded.artwork_url,
            language = excluded.language,
            published_date = excluded.published_date,
            duration_seconds = excluded.duration_seconds,
            catalog_position = excluded.catalog_position,
            transcript_status = CASE
                WHEN EXISTS (
                    SELECT 1 FROM episode_transcripts
                    WHERE episode_id = excluded.id AND trim(transcript) != ''
                ) THEN 'available'
                ELSE excluded.transcript_status
            END,
            media_status = CASE
                WHEN EXISTS (
                    SELECT 1 FROM episode_transcripts
                    WHERE episode_id = excluded.id AND trim(transcript) != ''
                ) THEN 'available'
                ELSE episodes.media_status
            END,
            availability_message = CASE
                WHEN EXISTS (
                    SELECT 1 FROM episode_transcripts
                    WHERE episode_id = excluded.id AND trim(transcript) != ''
                ) THEN ''
                ELSE episodes.availability_message
            END,
            source_file = CASE
                WHEN episodes.source_file = '' THEN excluded.source_file
                ELSE episodes.source_file
            END,
            updated_at = CURRENT_TIMESTAMP
        """,
        rows,
    )
    database.commit()
    return len(rows)


def upsert_episode(
    database: sqlite3.Connection,
    audio_path: Path,
    transcript_path: Path,
    transcript: str,
    *,
    episode_id: str | None = None,
    source_file: str | None = None,
) -> str:
    if not transcript.strip():
        raise ValueError("Transcript must not be empty.")
    episode_id = episode_id or vector_key_for(audio_path)
    source_file = source_file or audio_path.name
    database.execute(
        """
        INSERT INTO episodes (
            id, title, transcript_status, media_status,
            availability_message, source_file
        )
        VALUES (?, ?, 'available', 'available', '', ?)
        ON CONFLICT(id) DO UPDATE SET
            transcript_status = 'available',
            media_status = 'available',
            availability_message = '',
            source_file = excluded.source_file,
            updated_at = CURRENT_TIMESTAMP
        """,
        (episode_id, Path(source_file).stem, source_file),
    )
    database.execute(
        """
        INSERT INTO episode_transcripts (
            episode_id, transcript_file, transcript
        ) VALUES (?, ?, ?)
        ON CONFLICT(episode_id) DO UPDATE SET
            transcript_file = excluded.transcript_file,
            transcript = excluded.transcript,
            embedding = CASE
                WHEN episode_transcripts.transcript = excluded.transcript
                THEN episode_transcripts.embedding
                ELSE NULL
            END,
            embedding_dimension = CASE
                WHEN episode_transcripts.transcript = excluded.transcript
                THEN episode_transcripts.embedding_dimension ELSE NULL
            END,
            embedding_revision = CASE
                WHEN episode_transcripts.transcript = excluded.transcript
                THEN episode_transcripts.embedding_revision ELSE NULL
            END,
            embedding_language = CASE
                WHEN episode_transcripts.transcript = excluded.transcript
                THEN episode_transcripts.embedding_language ELSE NULL
            END,
            updated_at = CURRENT_TIMESTAMP
        """,
        (episode_id, transcript_path.name, transcript),
    )
    return episode_id


def mark_episode_unavailable(
    database: sqlite3.Connection,
    episode_id: str,
    message: str,
) -> None:
    """Persist publisher-level unavailability without replacing a transcript."""
    database.execute(
        """
        UPDATE episodes
        SET media_status = 'unavailable',
            availability_message = ?,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
          AND NOT EXISTS (
              SELECT 1 FROM episode_transcripts
              WHERE episode_id = episodes.id AND trim(transcript) != ''
          )
        """,
        (message.strip(), episode_id),
    )


def vector_key_for(audio_path: Path) -> str:
    return hashlib.sha256(audio_path.name.encode("utf-8")).hexdigest()


def main():
    deepgram_api_key = get_api_key()
    deepgram = DeepgramClient(api_key=deepgram_api_key)
    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    audio_files = sorted([p for p in AUDIO_DIR.iterdir() if is_audio_file(p)])
    if not audio_files:
        exts = ", ".join(sorted(AUDIO_EXTENSIONS))
        raise FileNotFoundError(
            f"No audio files found in {AUDIO_DIR}. Supported extensions: {exts}"
        )

    with initialize_database() as database:
        if CATALOG_PATH.is_file():
            sync_catalog(database, load_catalog())
        for audio_path in audio_files:
            try:
                transcript = transcribe_file(deepgram, audio_path)
                output_path = OUTPUT_DIR / f"{audio_path.stem}.txt"
                output_path.write_text(transcript, encoding="utf-8")
                print(f"Saved {output_path.name}")

                episode_id = upsert_episode(
                    database=database,
                    audio_path=audio_path,
                    transcript_path=output_path,
                    transcript=transcript,
                )
                database.commit()
                print(f"Stored local episode {episode_id} in {DATABASE_PATH}")
            except ApiError as e:
                print(f"API error for {audio_path.name}: {e}")
                sys.exit(1)
            except httpx.NetworkError as e:
                # Handles dropped internet connection, DNS failure, etc.
                print(f"Network Connection Issue: {e}")
                sys.exit(1)
            except httpx.TimeoutException as e:
                # Handles cases where Deepgram took too long to reply
                print(f"Request Timed Out: {e}")
                sys.exit(1)
            except sqlite3.Error as e:
                print(f"SQLite error for {audio_path.name}: {e}")
                sys.exit(1)
            except Exception as e:
                print(f"Failed on {audio_path.name}: {e}")
                sys.exit(1)


if __name__ == "__main__":
    main()
