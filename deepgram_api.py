from pathlib import Path
from dotenv import load_dotenv
from deepgram import DeepgramClient
import os

load_dotenv()

DEEPGRAM_API_KEY = os.getenv("DEEPGRAM_API_KEY")
ROOT_DIR = Path(__file__).resolve().parent
AUDIO_DIR = ROOT_DIR / "Audio"
OUTPUT_DIR = ROOT_DIR / "Transcripts"
OUTPUT_DIR.mkdir(exist_ok=True)

if DEEPGRAM_API_KEY is None:
    raise ValueError("API_KEY not found. Please check your .env file.")

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
    audio_files = sorted(AUDIO_DIR.glob("*.m4a"))

    if not audio_files:
        raise FileNotFoundError(f"No .m4a files found in {AUDIO_DIR}")

    for audio_path in audio_files:
        try:
            transcript = transcribe_file(deepgram, audio_path)
            output_path = OUTPUT_DIR / f"{audio_path.stem}.txt"
            output_path.write_text(transcript, encoding="utf-8")
            print(f"Saved {output_path.name}")
        except Exception as e:
            print(f"Failed on {audio_path.name}: {e}")

if __name__ == "__main__":
    main()