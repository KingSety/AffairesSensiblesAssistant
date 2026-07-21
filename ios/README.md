# iOS integration

## Add the package and database

1. In Xcode, add the local package at `ios/LocalVectorSearch` to the app target.
2. Drag `ios/Resources/episodes.sqlite` into the app target.
3. In the File inspector, confirm the application target is checked.
4. In Build Phases > Copy Bundle Resources, confirm `episodes.sqlite` appears.

The bundled database is read-only. Install it into Application Support before
opening it for vector updates:

```swift
import LocalVectorSearch

let databaseURL = try EpisodeDatabase.installBundledDatabase()
let episodeSearch = try LocalEpisodeSearch(databaseURL: databaseURL)
```

French is a hard requirement. `AppleSentenceEmbedder.isAvailable` can be used
to disable the search UI before initialization. The package never falls back to
another language model.

Generate missing vectors and search from an asynchronous task:

```swift
Task {
    do {
        try await episodeSearch.prepareEmbeddings()
        let results = try await episodeSearch.search(
            "empoisonnements en Bretagne",
            limit: 10
        )

        for result in results {
            print(result.score, result.episode.sourceFile)
        }
    } catch {
        // Show an offline-search-unavailable state in the UI.
        print(error.localizedDescription)
    }
}
```

`prepareEmbeddings()` is idempotent during the app process. It regenerates a
row when its vector is absent or its dimension, language, or Apple embedding
revision differs from the model available on the device.

## Optional: precompute vectors on a Mac

To avoid first-launch indexing, try:

```bash
cd ios/LocalVectorSearch
swift run build-episode-embeddings ../Resources/episodes.sqlite
```

`NLEmbedding.sentenceEmbedding` returns `nil` when the requested OS-managed
model is not available. A Mac can therefore support a revision in the SDK while
not having its model asset installed. In that case, leave the vectors empty and
let a supported iPhone generate them on first launch.

Do not fall back to existing OpenAI vectors: Apple and OpenAI embeddings use
different vector spaces and cannot be compared.

## Updating the catalog

Re-run `python3 build_local_database.py`, then replace the SQLite resource in
the Xcode target. During development, uninstall the app from the simulator or
device to force a fresh bundled database copy.

For production catalog updates, use a versioned resource name such as
`episodes-v2.sqlite`, or add a migration that merges new episode rows into the
database in Application Support.
