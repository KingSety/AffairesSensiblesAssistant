# Deepgram transcript pipeline with local iOS vector search

This project transcribes audio/video with Deepgram and writes transcripts to a
local SQLite database. The iOS app embeds and searches that text on-device.

## Python pipeline

Install dependencies:

```bash
python3 -m pip install -r requirements.txt
```

Copy `.env.example` to `.env` and configure:

```bash
DEEPGRAM_API_KEY=...
```

Place supported audio/video files in `Audio/`, then run:

```bash
python3 deepgram_api.py
```

If transcripts already exist, rebuild the database without calling Deepgram:

```bash
python3 build_local_database.py
```

Updating a transcript clears its old embedding so the iOS layer will regenerate
a compatible vector.

### Import every catalog transcript

To resolve each episode in `ios/Resources/imported_episodes.json`, have Deepgram
transcribe its media URL, and store only its transcript, run:

```bash
python3 import_catalog_transcripts.py
```

The importer does not keep audio files. It writes to `ios/Working/episodes.sqlite`
and atomically publishes a stable snapshot to `ios/Resources/episodes.sqlite`
every five episodes, so Xcode never bundles a partially written database. It
commits each episode individually, skips episodes already present in the working
database, retries temporary failures, and records any final failures in
`transcript_import_failures.json`. Re-run the same command to resume a stopped
import. Once every catalog transcript has been saved, it also creates the
HNSW-style chunk index before publishing the final database. This final step is
what makes the first local search as fast as later searches.

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

## Apple embeddings and local search

The Swift package in `ios/LocalVectorSearch` contains:

- `EpisodeDatabase`: SQLite storage and bundled-database installation.
- `AppleSentenceEmbedder`: versioned French `NLEmbedding` vectors.
- `LocalEpisodeSearch`: a persistent HNSW-style neighbor graph that uses
  cosine similarity only for a small set of nearby transcript chunks.
- `build-episode-embeddings`: the macOS builder for transcript chunks and the
  ready-to-use local search index.

See `ios/README.md` for Xcode integration and usage.

No OpenAI service or Python backend is required by the iOS app. Build the
index before bundling the database so the app opens a ready-to-search data pack
without creating vectors or copying the library during onboarding:


Build the Swift package:

```bash
cd ios/LocalVectorSearch
swift run build-episode-embeddings ../Working/episodes.sqlite
```
