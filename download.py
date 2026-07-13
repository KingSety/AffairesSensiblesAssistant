from pathlib import Path
import yt_dlp

ROOT_DIR = Path(__file__).resolve().parent
AUDIO_DIR = ROOT_DIR / "Audio"

url = input("Paste the video URL: ")

AUDIO_DIR.mkdir(parents=True, exist_ok=True)

options = {
    "paths": {
        "home": str(AUDIO_DIR),
    },
    "outtmpl": "%(title)s.%(ext)s",
}

with yt_dlp.YoutubeDL(options) as downloader:
    downloader.download([url])