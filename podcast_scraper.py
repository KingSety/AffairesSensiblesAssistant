"""Import podcast metadata from Radio France listing pages."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path
import re
import sys
import time
from typing import Iterable
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit

RADIO_FRANCE_ORIGIN = "https://www.radiofrance.fr"
DEFAULT_OUTPUT_PATH = Path("ios/Resources/imported_episodes.json")
JAVASCRIPT_STRING = r'(?P<{}>(?:\\.|[^"\\])*)'
EXPRESSION_PATTERN = re.compile(
    r'__typename:"Expression",'
    r'(?:(?!__typename:"Expression").)*?'
    r'type:"episode",'
    r'(?:(?!__typename:"Expression").)*?'
    r'titleProps:\{href:"' + JAVASCRIPT_STRING.format("href") + r'",\s*'
    r'text:"' + JAVASCRIPT_STRING.format("description") + r'",\s*'
    r'title:"' + JAVASCRIPT_STRING.format("title") + r'"\},\s*'
    r'visual:\{(?:(?!\},concept:).)*?'
    r'src:"' + JAVASCRIPT_STRING.format("artwork_url") + r'"',
    re.DOTALL,
)
PUBLISHED_DATE_PATTERN = re.compile(r'publishedDate:"(?P<date>(?:\\.|[^"\\])*)"')
DURATION_PATTERN = re.compile(r'duration:(?P<duration>\d+)')
LAST_PAGE_PATTERN = re.compile(r'lastPage:(?P<last_page>\d+)')


@dataclass(frozen=True)
class ImportedEpisode:
    id: str
    title: str
    description: str
    source_url: str
    artwork_url: str
    language: str
    published_date: str | None
    duration_seconds: int | None


class PodcastScraperError(RuntimeError):
    """A user-facing error raised while downloading or parsing a catalog."""


def decode_javascript_string(value: str) -> str:
    return json.loads(f'"{value.replace(chr(92) + chr(39), chr(39))}"')


def episode_id_for(source_url: str) -> str:
    return hashlib.sha256(source_url.encode("utf-8")).hexdigest()


def parse_radio_france_listing(html: str) -> list[ImportedEpisode]:
    """Extract episode metadata embedded in a Radio France listing page."""
    episodes: list[ImportedEpisode] = []
    seen_urls: set[str] = set()

    for match in EXPRESSION_PATTERN.finditer(html):
        href = decode_javascript_string(match.group("href"))
        if not href:
            continue

        source_url = urljoin(RADIO_FRANCE_ORIGIN, href)
        if source_url in seen_urls:
            continue

        expression = match.group(0)
        date_match = PUBLISHED_DATE_PATTERN.search(expression)
        duration_match = DURATION_PATTERN.search(expression)
        episodes.append(
            ImportedEpisode(
                id=episode_id_for(source_url),
                title=decode_javascript_string(match.group("title")).strip(),
                description=decode_javascript_string(match.group("description")).strip(),
                source_url=source_url,
                artwork_url=decode_javascript_string(match.group("artwork_url")),
                language="fr",
                published_date=(
                    decode_javascript_string(date_match.group("date"))
                    if date_match
                    else None
                ),
                duration_seconds=(
                    int(duration_match.group("duration")) if duration_match else None
                ),
            )
        )
        seen_urls.add(source_url)

    return episodes


def fetch_listing(url: str, retries: int, timeout_seconds: float) -> str:
    try:
        import httpx
    except ImportError as error:
        raise PodcastScraperError(
            "The scraper needs httpx. Run: python3 -m pip install -r requirements.txt"
        ) from error

    last_error: Exception | None = None
    for attempt in range(retries + 1):
        try:
            response = httpx.get(
                url,
                follow_redirects=True,
                headers={"User-Agent": "PodcastTranslate/1.0"},
                timeout=timeout_seconds,
            )
            response.raise_for_status()
            return response.text
        except httpx.HTTPStatusError as error:
            last_error = error
            status_code = error.response.status_code
            if status_code not in {429, 500, 502, 503, 504}:
                raise PodcastScraperError(
                    f"Radio France returned HTTP {status_code} for {url}."
                ) from error
            error_detail = f"Radio France returned HTTP {status_code}"
        except httpx.TimeoutException as error:
            last_error = error
            error_detail = "The request timed out"
        except httpx.NetworkError as error:
            last_error = error
            error_detail = f"Network or DNS error: {error}"

        if attempt == retries:
            raise PodcastScraperError(
                f"Could not fetch {url} after {retries + 1} attempts. "
                f"{error_detail}. Check your internet connection and try again."
            ) from last_error

        retry_delay = 2**attempt
        print(
            f"{error_detail}. Retrying {url} in {retry_delay} seconds "
            f"({attempt + 1}/{retries})...",
            file=sys.stderr,
        )
        time.sleep(retry_delay)


def listing_page_url(url: str, page: int) -> str:
    if page < 1:
        raise ValueError("Page numbers start at 1.")

    parsed_url = urlsplit(url)
    query = dict(parse_qsl(parsed_url.query, keep_blank_values=True))
    query["p"] = str(page)
    return urlunsplit(
        (
            parsed_url.scheme,
            parsed_url.netloc,
            parsed_url.path,
            urlencode(query),
            parsed_url.fragment,
        )
    )


def last_page_from_listing(html: str) -> int:
    match = LAST_PAGE_PATTERN.search(html)
    if not match:
        raise RuntimeError("Could not find the Radio France page count.")
    return int(match.group("last_page"))


def merge_episodes(*episode_lists: Iterable[ImportedEpisode]) -> list[ImportedEpisode]:
    episodes: list[ImportedEpisode] = []
    seen_urls: set[str] = set()

    for episode_list in episode_lists:
        for episode in episode_list:
            if episode.source_url in seen_urls:
                continue
            episodes.append(episode)
            seen_urls.add(episode.source_url)

    return episodes


def scrape_listing(
    url: str,
    all_pages: bool,
    delay_seconds: float,
    retries: int,
    timeout_seconds: float,
) -> list[ImportedEpisode]:
    if delay_seconds < 0:
        raise ValueError("The delay must be zero or greater.")
    if retries < 0:
        raise ValueError("The retry count must be zero or greater.")
    if timeout_seconds <= 0:
        raise ValueError("The request timeout must be greater than zero.")

    first_page_url = listing_page_url(url, 1) if all_pages else url
    first_page_html = fetch_listing(first_page_url, retries, timeout_seconds)
    episode_lists = [parse_radio_france_listing(first_page_html)]

    if not all_pages:
        return episode_lists[0]

    last_page = last_page_from_listing(first_page_html)
    for page in range(2, last_page + 1):
        if delay_seconds:
            time.sleep(delay_seconds)
        page_html = fetch_listing(
            listing_page_url(url, page), retries, timeout_seconds
        )
        episode_lists.append(parse_radio_france_listing(page_html))

    return merge_episodes(*episode_lists)


def write_catalog(episodes: Iterable[ImportedEpisode], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    payload = [asdict(episode) for episode in episodes]
    output_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Export Radio France episode metadata for PodcastTranslate."
    )
    parser.add_argument("url", help="A Radio France podcast listing URL")
    parser.add_argument(
        "--all-pages",
        action="store_true",
        help="Import every page in the podcast catalog, not only the supplied page.",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=0.25,
        help="Seconds to wait between catalog pages (default: 0.25).",
    )
    parser.add_argument(
        "--retries",
        type=int,
        default=3,
        help="Retries for temporary request failures (default: 3).",
    )
    parser.add_argument(
        "--request-timeout",
        type=float,
        default=30.0,
        help="Request timeout in seconds (default: 30).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT_PATH,
        help=f"Catalog output path (default: {DEFAULT_OUTPUT_PATH})",
    )
    arguments = parser.parse_args()

    try:
        episodes = scrape_listing(
            arguments.url,
            all_pages=arguments.all_pages,
            delay_seconds=arguments.delay,
            retries=arguments.retries,
            timeout_seconds=arguments.request_timeout,
        )
        if not episodes:
            raise PodcastScraperError(
                "No episode metadata found on the supplied listing page."
            )
    except PodcastScraperError as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    except KeyboardInterrupt:
        print("Import cancelled.", file=sys.stderr)
        raise SystemExit(130) from None

    write_catalog(episodes, arguments.output)
    print(f"Saved {len(episodes)} episodes to {arguments.output}")


if __name__ == "__main__":
    main()
