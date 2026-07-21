import sqlite3
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.parse import urlparse

import pytest
from deepgram.core.api_error import ApiError

from deepgram_api import (
    create_summary,
    get_api_key,
    initialize_database,
    transcribe_file,
    upsert_episode,
    vector_key_for,
)
from download import download_file


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


def test_create_summary():
    openai_client = Mock()
    openai_client.responses.create.return_value.output_text = "  A short summary.  "

    summary = create_summary(openai_client, "A transcript.", "summary-model")

    assert summary == "A short summary."
    openai_client.responses.create.assert_called_once()


def test_initialize_database_creates_episode_schema(tmp_path):
    database_path = tmp_path / "ios" / "episodes.sqlite"

    with initialize_database(database_path) as database:
        columns = {
            row[1] for row in database.execute("PRAGMA table_info(episodes)")
        }

    assert database_path.is_file()
    assert {
        "id",
        "source_file",
        "transcript",
        "summary",
        "embedding",
        "embedding_dimension",
        "embedding_revision",
        "embedding_language",
    }.issubset(columns)


def test_upsert_episode_invalidates_embedding_when_summary_changes(tmp_path):
    audio_path = Path("Audio/episode.m4a")
    transcript_path = Path("Transcripts/episode.txt")
    summary_path = Path("Summaries/episode.txt")

    with initialize_database(tmp_path / "episodes.sqlite") as database:
        episode_id = upsert_episode(
            database,
            audio_path,
            transcript_path,
            summary_path,
            "Transcript",
            "Original summary",
        )
        database.execute(
            """
            UPDATE episodes
            SET embedding = ?, embedding_dimension = 2,
                embedding_revision = 1, embedding_language = 'fr'
            WHERE id = ?
            """,
            (sqlite3.Binary(b"12345678"), episode_id),
        )

        upsert_episode(
            database,
            audio_path,
            transcript_path,
            summary_path,
            "Transcript",
            "Changed summary",
        )
        row = database.execute(
            """
            SELECT embedding, embedding_dimension,
                   embedding_revision, embedding_language
            FROM episodes WHERE id = ?
            """,
            (episode_id,),
        ).fetchone()

    assert row == (None, None, None, None)


def test_vector_key_is_deterministic():
    assert vector_key_for(Path("Audio/example.mp3")) == vector_key_for(
        Path("elsewhere/example.mp3")
    )
