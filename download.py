from pathlib import Path
from urllib.parse import urlparse
import yt_dlp

def download_file(url: str, output_dir=None):

    root_dir = Path(__file__).resolve().parent
    audio_dir = Path(output_dir) if output_dir is not None else root_dir / "Audio"
    try:
    
        result = urlparse(url)
        if not all([result.scheme, result.netloc]):
            raise ValueError("Invalid URL. Please provide a valid video URL.")
    except KeyboardInterrupt:
        print("Operation cancelled by user.")
        exit(1)

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
            print(f"Download failed: {e}")
            exit(1)

    return audio_dir

def main():
    url = input("Paste the video URL: ").strip()
    filename = download_file(url)
    print(f"Downloaded file: {filename}")
    
if __name__ == "__main__":
    main()
