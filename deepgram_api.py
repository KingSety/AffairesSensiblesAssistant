from pathlib import Path
from dotenv import load_dotenv
from deepgram import DeepgramClient
from deepgram.core.api_error import ApiError
import os
import mimetypes
import sys
import httpx


load_dotenv()

DEEPGRAM_API_KEY = os.getenv("DEEPGRAM_API_KEY")
ROOT_DIR = Path(__file__).resolve().parent
AUDIO_DIR = ROOT_DIR / "Audio"
OUTPUT_DIR = ROOT_DIR / "Transcripts"
OUTPUT_DIR.mkdir(exist_ok=True)

if DEEPGRAM_API_KEY is None:
    raise ValueError("API_KEY not found. Please check your .env file.")

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


def main():
    deepgram = DeepgramClient(api_key=DEEPGRAM_API_KEY)
    AUDIO_DIR.mkdir(parents=True, exist_ok=True)

    audio_files = sorted([p for p in AUDIO_DIR.iterdir() if is_audio_file(p)])

    if not audio_files:
        exts = ", ".join(sorted(AUDIO_EXTENSIONS))
        raise FileNotFoundError(
            f"No audio files found in {AUDIO_DIR}. Supported extensions: {exts}"
        )

    for audio_path in audio_files:
        try:
            transcript = transcribe_file(deepgram, audio_path)
            output_path = OUTPUT_DIR / f"{audio_path.stem}.txt"
            output_path.write_text(transcript, encoding="utf-8")
            print(f"Saved {output_path.name}")
        except ApiError as e:
            print(f"API error for {audio_path.name}: {e}")
            sys.exit(1)
        except httpx.NetworkError as e:
            # Handles dropped internet connection, DNS failure, etc.
            print(f"Network Connection Issue: {e}")

        except httpx.TimeoutException as e:
            # Handles cases where Deepgram took too long to reply
            print(f"Request Timed Out: {e}")
        except Exception as e:
            print(f"Failed on {audio_path.name}: {e}")
            sys.exit(1)


if __name__ == "__main__":
    main()