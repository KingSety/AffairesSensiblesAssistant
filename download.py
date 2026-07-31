from pathlib import Path
from urllib.parse import urlparse
import yt_dlp


class DownloadError(RuntimeError):
    pass


def resolve_audio_url(url: str) -> str:
    result = urlparse(url)
    if not all([result.scheme, result.netloc]):
        raise DownloadError("Invalid URL. Please provide a valid podcast URL.")

    options = {
        "noplaylist": True,
        "quiet": True,
        "skip_download": True,
        "format": "bestaudio/best",
    }
    with yt_dlp.YoutubeDL(options) as downloader:
        info = downloader.extract_info(url, download=False)

    if isinstance(info, dict) and "entries" in info:
        entries = info["entries"]
        info = next((entry for entry in entries if entry), None)
    audio_url = info.get("url") if isinstance(info, dict) else None
    if not isinstance(audio_url, str) or not audio_url:
        raise DownloadError("Could not resolve an audio URL from the podcast page.")
    return audio_url


def download_file(url: str, output_dir=None):

    root_dir = Path(__file__).resolve().parent
    audio_dir = Path(output_dir) if output_dir is not None else root_dir / "Audio"
    try:
        result = urlparse(url)
        if not all([result.scheme, result.netloc]):
            raise DownloadError("Invalid URL. Please provide a valid video URL.")
    except KeyboardInterrupt:
        raise

    audio_dir.mkdir(parents=True, exist_ok=True)

    options = {
        "paths": {
            "home": str(audio_dir),
        },
        "outtmpl": "%(title)s.%(ext)s",
    }

    with yt_dlp.YoutubeDL(options) as downloader:
        try:
            downloader.download([url])
        except yt_dlp.utils.DownloadError as e:
            raise DownloadError(f"Download failed: {e}") from e

    return audio_dir

def main():
    url = input("Paste the video URL: ").strip()
    filename = download_file(url)
    print(f"Downloaded file: {filename}")
    
if __name__ == "__main__":
    main()
