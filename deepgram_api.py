from pathlib import Path
from dotenv import load_dotenv
from deepgram import DeepgramClient
import os


load_dotenv()

DEEPGRAM_API_KEY = os.getenv("DEEPGRAM_API_KEY")
ROOT_DIR = Path(__file__).resolve().parent
AUDIO_FILE = ROOT_DIR / "Audio" / "La Jégado, empoisonneuse en série [2623170].mp3"

if DEEPGRAM_API_KEY is None:
    raise ValueError("API_KEY not found. Please check your .env file.")

def main():
    try:
        
        deepgram = DeepgramClient(api_key=DEEPGRAM_API_KEY)

        with AUDIO_FILE.open("rb") as audio_file:
            response = deepgram.listen.v1.media.transcribe_file(
                request=audio_file.read(),
                model="nova-3",
                language="fr",
                smart_format=True,
                paragraphs=True,
            )




    except Exception as e:
        print(f"Exception: {e}")
        
    with open("output.txt", "w") as file:
        file.write(response.results.channels[0].alternatives[0].transcript)

if __name__ == "__main__":
    main()