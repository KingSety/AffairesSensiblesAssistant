from pathlib import Path
from unittest.mock import Mock
from urllib.parse import urlparse

import pytest
from deepgram.core.api_error import ApiError

from deepgram_api import (
    EMBEDDING_DIMENSIONS,
    create_embedding,
    create_summary,
    get_api_key,
    store_summary_vector,
    transcribe_file,
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

def test_download_file():
    url = "https://www.radiofrance.fr/franceinter/podcasts/affaires-sensibles/affaires-sensibles-du-lundi-05-janvier-2026-2623170"
    audio_dir = download_file(url)
    downloaded_file = audio_dir / "La Jégado, empoisonneuse en série.m4a"
    assert downloaded_file.exists(), (
        f"Expected downloaded file was not found: {downloaded_file}"
    )


def test_transcribe_downloads_file():
    # Test downloading and transcribing a file from a URL
    url = "https://www.radiofrance.fr/franceinter/podcasts/affaires-sensibles/affaires-sensibles-du-lundi-05-janvier-2026-2623170"
    response = download_file(url)
    assert response is not None, "Download failed, response is None."

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


def test_create_embedding_uses_requested_model_and_dimensions():
    openai_client = Mock()
    openai_client.embeddings.create.return_value.data = [
        Mock(embedding=[0.25] * EMBEDDING_DIMENSIONS)
    ]

    embedding = create_embedding(openai_client, "A short summary.")

    assert len(embedding) == EMBEDDING_DIMENSIONS
    openai_client.embeddings.create.assert_called_once_with(
        model="text-embedding-3-small",
        input="A short summary.",
        dimensions=EMBEDDING_DIMENSIONS,
        encoding_format="float",
    )


def test_store_summary_vector():
    s3vectors = Mock()

    store_summary_vector(
        s3vectors=s3vectors,
        bucket_name="videos",
        index_name="summaries",
        vector_key="audio-key",
        embedding=[0.1] * EMBEDDING_DIMENSIONS,
        metadata={"summary": "A short summary."},
    )

    request = s3vectors.put_vectors.call_args.kwargs
    assert request["vectorBucketName"] == "videos"
    assert request["indexName"] == "summaries"
    assert request["vectors"][0]["key"] == "audio-key"
    assert len(request["vectors"][0]["data"]["float32"]) == EMBEDDING_DIMENSIONS
    assert request["vectors"][0]["metadata"]["summary"] == "A short summary."


def test_store_summary_vector_rejects_wrong_dimensions():
    with pytest.raises(ValueError, match="received 1 dimension"):
        store_summary_vector(Mock(), "bucket", "index", "key", [0.1], {})


def test_vector_key_is_deterministic():
    assert vector_key_for(Path("Audio/example.mp3")) == vector_key_for(
        Path("elsewhere/example.mp3")
    )
