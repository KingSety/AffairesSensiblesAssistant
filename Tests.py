import sqlite3
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.parse import urlparse

import pytest
from deepgram.core.api_error import ApiError

from deepgram_api import (
    get_api_key,
    initialize_database,
    mark_episode_unavailable,
    sync_catalog,
    transcribe_file,
    transcribe_url,
    upsert_episode,
    vector_key_for,
)
from download import (
    EpisodeAudioResolver,
    MediaUnavailableError,
    RadioFranceRSSResolver,
    download_file,
    resolve_audio_url,
)


def test_url_validation():
    # Test valid URL
    valid_url = "https://www.radiofrance.fr/franceinter/podcasts/affaires-sensibles/affaires-sensibles-du-lundi-05-janvier-2026-2623170"
    result = urlparse(valid_url)
    assert all([result.scheme, result.netloc]), "Valid URL failed validation."

    # Test invalid URL
    invalid_url = "not_a_valid_url"
    result = urlparse(invalid_url)
    assert not all([result.scheme, result.netloc]), "Invalid URL passed validation."

def test_download_file(tmp_path):
    url = "https://www.radiofrance.fr/franceinter/podcasts/affaires-sensibles/affaires-sensibles-du-lundi-05-janvier-2026-2623170"
    audio_dir = tmp_path / "audio"

    with patch("download.yt_dlp.YoutubeDL") as youtube_dl:
        downloader = youtube_dl.return_value.__enter__.return_value

        result = download_file(url, output_dir=audio_dir)

    youtube_dl.assert_called_once_with(
        {
            "paths": {"home": str(audio_dir)},
            "outtmpl": "%(title)s.%(ext)s",
        }
    )
    downloader.download.assert_called_once_with([url])
    assert result == audio_dir
    assert audio_dir.is_dir()


def test_download_file_accepts_string_output_path(tmp_path):
    url = "https://www.radiofrance.fr/franceinter/podcasts/affaires-sensibles/affaires-sensibles-du-lundi-05-janvier-2026-2623170"
    audio_dir = tmp_path / "audio"

    with patch("download.yt_dlp.YoutubeDL") as youtube_dl:
        result = download_file(url, output_dir=str(audio_dir))

    youtube_dl.return_value.__enter__.return_value.download.assert_called_once_with(
        [url]
    )
    assert result == audio_dir


def test_resolve_audio_url(tmp_path):
    url = "https://www.radiofrance.fr/franceinter/podcasts/example"
    with patch("download.yt_dlp.YoutubeDL") as youtube_dl:
        downloader = youtube_dl.return_value.__enter__.return_value
        downloader.extract_info.return_value = {"url": "https://cdn.example/audio.m4a"}

        audio_url = resolve_audio_url(url)

    assert audio_url == "https://cdn.example/audio.m4a"
    downloader.extract_info.assert_called_once_with(url, download=False)


def test_episode_audio_resolver_prefers_local_audio(tmp_path):
    local_audio = tmp_path / "8750596.mp3"
    local_audio.write_bytes(b"audio")
    resolver = EpisodeAudioResolver(audio_dir=tmp_path)

    resolved = resolver.resolve(
        {
            "id": "catalog-id",
            "title": "Charles Hernu",
            "source_url": "https://www.radiofrance.fr/example-8750596",
        }
    )

    assert resolved.location == local_audio
    assert resolved.source == "local audio"


def test_rss_resolver_matches_unique_episode_title():
    feed = b"""<?xml version="1.0"?>
    <rss><channel><item>
      <title>Episode title</title>
      <link>https://www.radiofrance.fr/example</link>
      <enclosure url="https://cdn.example/episode.m4a" type="audio/x-m4a" />
    </item></channel></rss>"""
    response = Mock(content=feed)
    response.raise_for_status.return_value = None

    with patch("download.httpx.get", return_value=response):
        resolver = RadioFranceRSSResolver("https://example.com/feed.xml")
        result = resolver.resolve(
            {
                "title": "Episode title",
                "source_url": "https://www.radiofrance.fr/different-link",
            }
        )

    assert result == "https://cdn.example/episode.m4a"


def test_episode_audio_resolver_marks_missing_publisher_audio_unavailable():
    resolver = EpisodeAudioResolver(audio_dir=None)
    resolver.rss._entries = []

    with patch(
        "download.resolve_audio_url",
        side_effect=Exception("Unable to extract audio data"),
    ), pytest.raises(MediaUnavailableError, match="no longer available"):
        resolver.resolve(
            {
                "title": "Unavailable episode",
                "source_url": "https://www.radiofrance.fr/example-1234567",
            }
        )

def test_missing_api_key(monkeypatch):
    monkeypatch.delenv("DEEPGRAM_API_KEY", raising=False)

    with pytest.raises(ValueError, match="DEEPGRAM_API_KEY not found"):
        get_api_key()
    
def test_faulty_api_key(tmp_path):
    audio_file = tmp_path / "test_audio.mp3"
    audio_file.write_bytes(b"dummy audio content")
    fake_deepgram = Mock()
    fake_deepgram.listen.v1.media.transcribe_file.side_effect = ApiError(status_code=401, 
                                                                         body={"message": "Invalid API key"})
    with pytest.raises(ApiError) as error:
        transcribe_file(fake_deepgram, audio_file)

    assert error.value.status_code == 401

def test_transcription_failure():
    # Test behavior when transcription fails
    with pytest.raises(Exception):
        transcribe_file(None, None)  # Assuming the function raises an exception on failure
        assert False, "Transcription should have failed but didn't."


def test_transcribe_url_uses_resolved_media_url():
    fake_deepgram = Mock()
    fake_deepgram.listen.v1.media.transcribe_url.return_value.results.channels = [
        Mock(alternatives=[Mock(transcript="Transcript")])
    ]

    transcript = transcribe_url(fake_deepgram, "https://cdn.example/audio.m4a")

    assert transcript == "Transcript"
    fake_deepgram.listen.v1.media.transcribe_url.assert_called_once()


def test_initialize_database_creates_episode_schema(tmp_path):
    database_path = tmp_path / "ios" / "episodes.sqlite"

    with initialize_database(database_path) as database:
        columns = {
            row[1] for row in database.execute("PRAGMA table_info(episodes)")
        }
        transcript_columns = {
            row[1]
            for row in database.execute("PRAGMA table_info(episode_transcripts)")
        }

    assert database_path.is_file()
    assert {
        "id",
        "title",
        "short_description",
        "catalog_position",
        "source_file",
        "transcript_status",
        "media_status",
        "availability_message",
    }.issubset(columns)
    assert {
        "episode_id",
        "transcript",
        "embedding",
        "embedding_dimension",
        "embedding_revision",
        "embedding_language",
    }.issubset(transcript_columns)
    assert "transcript" not in columns
    assert "summary" not in columns


def test_upsert_episode_invalidates_embedding_when_transcript_changes(tmp_path):
    audio_path = Path("Audio/episode.m4a")
    transcript_path = Path("Transcripts/episode.txt")

    with initialize_database(tmp_path / "episodes.sqlite") as database:
        episode_id = upsert_episode(
            database,
            audio_path,
            transcript_path,
            "Transcript",
        )
        database.execute(
            """
            UPDATE episode_transcripts
            SET embedding = ?, embedding_dimension = 2,
                embedding_revision = 1, embedding_language = 'fr'
            WHERE episode_id = ?
            """,
            (sqlite3.Binary(b"12345678"), episode_id),
        )

        upsert_episode(
            database,
            audio_path,
            transcript_path,
            "Changed transcript",
        )
        row = database.execute(
            """
            SELECT embedding, embedding_dimension,
                   embedding_revision, embedding_language
            FROM episode_transcripts WHERE episode_id = ?
            """,
            (episode_id,),
        ).fetchone()

    assert row == (None, None, None, None)


def test_vector_key_is_deterministic():
    assert vector_key_for(Path("Audio/example.mp3")) == vector_key_for(
        Path("elsewhere/example.mp3")
    )


def test_upsert_episode_accepts_catalog_metadata(tmp_path):
    with initialize_database(tmp_path / "episodes.sqlite") as database:
        episode_id = upsert_episode(
            database,
            Path("temporary-audio.m4a"),
            Path("Transcripts/catalog-id.txt"),
            "Transcript",
            episode_id="catalog-id",
            source_file="Catalog episode.m4a",
        )
        row = database.execute(
            "SELECT id, source_file FROM episodes WHERE id = ?", (episode_id,)
        ).fetchone()

    assert row == ("catalog-id", "Catalog episode.m4a")


def test_sync_catalog_keeps_every_episode_and_marks_transcript_availability(tmp_path):
    catalog = [
        {
            "id": "transcribed",
            "title": "Transcribed episode",
            "description": "A short description",
            "source_url": "https://example.com/transcribed",
            "artwork_url": "https://example.com/art.jpg",
            "language": "fr",
            "published_date": "2026-01-01",
            "duration_seconds": 1200,
        },
        {
            "id": "description-only",
            "title": "Description only",
            "description": "Short description",
            "source_url": "https://example.com/description",
        },
        {
            "id": "missing",
            "title": "Missing text",
            "description": "",
            "source_url": "https://example.com/missing",
        },
    ]

    with initialize_database(tmp_path / "episodes.sqlite") as database:
        upsert_episode(
            database,
            Path("transcribed.m4a"),
            Path("transcribed.txt"),
            "Full transcript",
            episode_id="transcribed",
        )
        sync_catalog(database, catalog)
        rows = database.execute(
            "SELECT id, title, transcript_status FROM episodes ORDER BY id"
        ).fetchall()

    assert rows == [
        ("description-only", "Description only", "description_only"),
        ("missing", "Missing text", "missing"),
        ("transcribed", "Transcribed episode", "available"),
    ]


def test_unavailable_status_survives_catalog_sync_and_clears_after_transcription(tmp_path):
    catalog = [
        {
            "id": "episode-id",
            "title": "Unavailable episode",
            "description": "Description",
            "source_url": "https://example.com/episode",
        }
    ]

    with initialize_database(tmp_path / "episodes.sqlite") as database:
        sync_catalog(database, catalog)
        mark_episode_unavailable(database, "episode-id", "Episode unavailable")
        sync_catalog(database, catalog)
        unavailable = database.execute(
            "SELECT media_status, availability_message FROM episodes WHERE id = ?",
            ("episode-id",),
        ).fetchone()

        upsert_episode(
            database,
            Path("episode.m4a"),
            Path("episode.txt"),
            "Transcript",
            episode_id="episode-id",
        )
        available = database.execute(
            "SELECT media_status, availability_message FROM episodes WHERE id = ?",
            ("episode-id",),
        ).fetchone()

    assert unavailable == ("unavailable", "Episode unavailable")
    assert available == ("available", "")


def test_initialize_database_migrates_legacy_transcript_and_removes_duplicate_summary(
    tmp_path,
):
    database_path = tmp_path / "episodes.sqlite"
    with sqlite3.connect(database_path) as database:
        database.execute(
            """
            CREATE TABLE episodes (
                id TEXT PRIMARY KEY,
                source_file TEXT NOT NULL,
                transcript_file TEXT NOT NULL,
                summary_file TEXT NOT NULL,
                transcript TEXT NOT NULL,
                summary TEXT NOT NULL,
                embedding BLOB,
                embedding_dimension INTEGER,
                embedding_revision INTEGER,
                embedding_language TEXT,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        database.execute(
            """
            INSERT INTO episodes (
                id, source_file, transcript_file, summary_file, transcript, summary
            ) VALUES ('episode-id', 'Episode.m4a', 'Episode.txt', 'Episode.txt',
                      'Full transcript', 'Full transcript')
            """
        )

    with initialize_database(database_path) as database:
        episode = database.execute(
            "SELECT id, transcript_status FROM episodes"
        ).fetchone()
        transcript = database.execute(
            "SELECT episode_id, transcript FROM episode_transcripts"
        ).fetchone()
        columns = {
            row[1] for row in database.execute("PRAGMA table_info(episodes)")
        }

    assert episode == ("episode-id", "available")
    assert transcript == ("episode-id", "Full transcript")
    assert "summary" not in columns
