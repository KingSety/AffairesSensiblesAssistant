# Deepgram video parser with local iOS vector search

This project transcribes audio/video with Deepgram, summarizes each transcript
with OpenAI, and writes the episode text to a local SQLite database.

## Python pipeline

Install dependencies:

```bash
python3 -m pip install -r requirements.txt
```

Copy `.env.example` to `.env` and configure:

```bash
DEEPGRAM_API_KEY=...
OPENAI_API_KEY=...
```

`OPENAI_SUMMARY_MODEL` is optional and defaults to `gpt-4.1-mini`

Place supported audio/video files in `Audio/`, then run:

```bash
python3 deepgram_api.py
```

If transcripts and summaries already exist, rebuild the database without
calling Deepgram or OpenAI:

```bash
python3 build_local_database.py
```

Updating a summary clears its old embedding so the iOS layer will regenerate a
compatible vector.

## Import a Radio France podcast catalog

Export the episodes from a Radio France podcast listing into a JSON catalog for
the iOS app:

```bash
python3 podcast_scraper.py 'https://www.radiofrance.fr/franceinter/podcasts/affaires-sensibles?p=3'
```

This writes `ios/Resources/imported_episodes.json`. Each item includes its
title, French source language, artwork URL, episode URL, publication date, and
duration. The Xcode project bundles this catalog in the `PodcastTranslate` app
target. Listening progress is intentionally not scraped: it belongs to each
user's device and is recorded by the app during playback.

To collect the full catalog rather than one page, use:

```bash
python3 podcast_scraper.py 'https://www.radiofrance.fr/franceinter/podcasts/affaires-sensibles' --all-pages
```

The scraper follows Radio France's published pagination, pauses briefly between
requests, and removes duplicate episode URLs before writing the catalog.
Temporary DNS, timeout, rate-limit, and server errors are retried three times;
use `--retries 5` to retry more often or `--request-timeout 60` for a slower
connection.

## iOS AI backend

The iOS app sends retrieved episode context to a backend; it never stores an
OpenAI API key in the app. For local simulator development, configure
`OPENAI_API_KEY` in `.env` and run:

```bash
python3 ai_server.py
```

The app defaults to `http://127.0.0.1:8080`. For a physical device, run the
backend behind an authenticated HTTPS endpoint and set `AIBackendURL` in the
app configuration. Do not expose the development server directly to the
internet.

## Apple embeddings and local search

The Swift package in `ios/LocalVectorSearch` contains:

- `EpisodeDatabase`: SQLite storage and bundled-database installation.
- `AppleSentenceEmbedder`: versioned French `NLEmbedding` vectors.
- `LocalEpisodeSearch`: exact cosine-equivalent search with Accelerate.
- `build-episode-embeddings`: an optional macOS seed-index builder.

See `ios/README.md` for Xcode integration and usage.


Build the Swift package:

```bash
cd ios/LocalVectorSearch
swift build
```
