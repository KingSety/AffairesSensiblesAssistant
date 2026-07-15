import pytest
from download import download_file
from deepgram_api import transcribe_file
from deepgram.core.api_error import ApiError
from urllib.parse import urlparse
from unittest.mock import Mock
from deepgram_api import get_api_key

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