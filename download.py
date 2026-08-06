from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import unicodedata
from urllib.parse import urlparse, urlsplit, urlunsplit
import xml.etree.ElementTree as ET

import httpx
import yt_dlp


DEFAULT_RADIO_FRANCE_RSS_URL = (
    "https://radiofrance-podcast.net/podcast09/rss_13940.xml"
)
LOCAL_AUDIO_EXTENSIONS = {
    ".aac", ".flac", ".m4a", ".mkv", ".mov", ".mp3", ".mp4",
    ".ogg", ".opus", ".wav", ".webm",
}


class DownloadError(RuntimeError):
    pass


class MediaUnavailableError(DownloadError):
    """Raised after every configured source confirms that no audio is available."""


@dataclass(frozen=True)
class ResolvedAudio:
    location: str | Path
    source: str

    @property
    def is_local_file(self) -> bool:
        return isinstance(self.location, Path)


@dataclass(frozen=True)
class RSSAudioEntry:
    title: str
    page_url: str
    audio_url: str


def _normalized_text(value: str) -> str:
    value = unicodedata.normalize("NFKD", value.casefold())
    return "".join(character for character in value if character.isalnum())


def _normalized_url(value: str) -> str:
    parsed = urlsplit(value)
    return urlunsplit(
        (parsed.scheme.casefold(), parsed.netloc.casefold(), parsed.path.rstrip("/"), "", "")
    )


def _permanently_unavailable_error(error: Exception) -> bool:
    message = str(error).casefold()
    return any(
        marker in message
        for marker in (
            "http error 404",
            "unable to extract audio data",
            "could not resolve an audio url",
        )
    )


class LocalAudioResolver:
    def __init__(self, audio_dir: Path | None):
        self.audio_dir = audio_dir
        self._files_by_stem: dict[str, Path] | None = None

    def resolve(self, episode: dict[str, object]) -> Path | None:
        files_by_stem = self._indexed_files()
        if not files_by_stem:
            return None

        candidates = {
            _normalized_text(str(episode.get("id") or "")),
            _normalized_text(str(episode.get("title") or "")),
        }
        source_url = str(episode.get("source_url") or "")
        numeric_id = re.search(r"-(\d+)(?:/)?$", urlparse(source_url).path)
        if numeric_id:
            candidates.add(_normalized_text(numeric_id.group(1)))

        for candidate in candidates:
            if candidate and candidate in files_by_stem:
                return files_by_stem[candidate]
        return None

    def _indexed_files(self) -> dict[str, Path]:
        if self._files_by_stem is not None:
            return self._files_by_stem
        if self.audio_dir is None or not self.audio_dir.is_dir():
            self._files_by_stem = {}
            return self._files_by_stem

        self._files_by_stem = {
            _normalized_text(path.stem): path
            for path in sorted(self.audio_dir.iterdir())
            if path.is_file() and path.suffix.casefold() in LOCAL_AUDIO_EXTENSIONS
        }
        return self._files_by_stem


class RadioFranceRSSResolver:
    def __init__(self, feed_url: str = DEFAULT_RADIO_FRANCE_RSS_URL):
        self.feed_url = feed_url
        self._entries: list[RSSAudioEntry] | None = None

    def resolve(self, episode: dict[str, object]) -> str | None:
        entries = self._load_entries()
        source_url = _normalized_url(str(episode.get("source_url") or ""))
        if source_url:
            for entry in entries:
                if entry.page_url and _normalized_url(entry.page_url) == source_url:
                    return entry.audio_url

        title = _normalized_text(str(episode.get("title") or ""))
        title_matches = [
            entry.audio_url
            for entry in entries
            if title and _normalized_text(entry.title) == title
        ]
        if len(title_matches) == 1:
            return title_matches[0]
        return None

    def _load_entries(self) -> list[RSSAudioEntry]:
        if self._entries is not None:
            return self._entries

        response = httpx.get(
            self.feed_url,
            follow_redirects=True,
            headers={"User-Agent": "AffairesSensiblesAssistant/1.0"},
            timeout=30,
        )
        response.raise_for_status()
        root = ET.fromstring(response.content)
        entries: list[RSSAudioEntry] = []
        for item in root.findall("./channel/item"):
            enclosure = item.find("enclosure")
            audio_url = enclosure.get("url", "").strip() if enclosure is not None else ""
            if not audio_url.startswith(("https://", "http://")):
                continue
            entries.append(
                RSSAudioEntry(
                    title=(item.findtext("title") or "").strip(),
                    page_url=(item.findtext("link") or "").strip(),
                    audio_url=audio_url,
                )
            )
        self._entries = entries
        return entries


class EpisodeAudioResolver:
    def __init__(
        self,
        *,
        audio_dir: Path | None = None,
        rss_feed_url: str = DEFAULT_RADIO_FRANCE_RSS_URL,
    ):
        self.local = LocalAudioResolver(audio_dir)
        self.rss = RadioFranceRSSResolver(rss_feed_url)

    def resolve(self, episode: dict[str, object]) -> ResolvedAudio:
        local_path = self.local.resolve(episode)
        if local_path is not None:
            return ResolvedAudio(local_path, "local audio")

        source_url = str(episode.get("source_url") or "")
        page_error: Exception | None = None
        try:
            return ResolvedAudio(resolve_audio_url(source_url), "episode page")
        except KeyboardInterrupt:
            raise
        except Exception as error:
            page_error = error

        try:
            rss_audio_url = self.rss.resolve(episode)
        except (httpx.HTTPError, ET.ParseError) as rss_error:
            raise DownloadError(
                f"Could not check the Radio France RSS fallback: {rss_error}"
            ) from rss_error
        if rss_audio_url:
            return ResolvedAudio(rss_audio_url, "Radio France RSS")

        if page_error is not None and _permanently_unavailable_error(page_error):
            raise MediaUnavailableError(
                "This episode is no longer available from Radio France. "
                "No audio was found on its page, in the official RSS feed, "
                "or in the local audio folder."
            ) from page_error
        if page_error is not None:
            raise page_error
        raise DownloadError("Could not resolve audio for this episode.")


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
    result = urlparse(url)
    if not all([result.scheme, result.netloc]):
        raise DownloadError("Invalid URL. Please provide a valid video URL.")

    audio_dir.mkdir(parents=True, exist_ok=True)
    options = {
        "paths": {"home": str(audio_dir)},
        "outtmpl": "%(title)s.%(ext)s",
    }

    with yt_dlp.YoutubeDL(options) as downloader:
        try:
            downloader.download([url])
        except yt_dlp.utils.DownloadError as error:
            raise DownloadError(f"Download failed: {error}") from error

    return audio_dir


def main():
    url = input("Paste the video URL: ").strip()
    filename = download_file(url)
    print(f"Downloaded file: {filename}")


if __name__ == "__main__":
    main()
