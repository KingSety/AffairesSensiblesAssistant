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
