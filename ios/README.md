# iOS integration

## Add the package and database

Before testing simulation, run the following commands inside the project directory:
1. git lfs install
2. git lfs pull
3. confirm the database was downloaded using `file ios/Resources/episodes.sqlite`
   (it should report a SQLite database)



1. Open deepgram_video_parser-master/PodcastTranslate/PodcastTranslate.xcodeproj on Xcode
2. In Xcode, add the local package at `ios/LocalVectorSearch` to the app target if not included.
3. Ensure `ios/Resources/episodes.sqlite` is a reference to the App target.
4. In the File inspector, confirm the application target is checked.
5. In Build Phases > Copy Bundle Resources, confirm `episodes.sqlite` appears.

The bundled database is the app's single read-only source for catalog metadata,
available transcripts, and prebuilt indexes. Open it directly for normal app
reads so launch does not copy the data pack:

```swift
let databaseURL = try EpisodeDatabase.bundledDatabaseURL()
let database = try EpisodeDatabase(url: databaseURL, accessMode: .readOnly)
let catalog = try database.fetchCatalogEpisodes()
let transcript = try database.fetchTranscript(episodeID: catalog[0].id)
```

Only install it into Application Support when a writable copy is specifically
needed for vector updates:

```swift
import LocalVectorSearch

let databaseURL = try EpisodeDatabase.installBundledDatabase()
let episodeSearch = try LocalEpisodeSearch(databaseURL: databaseURL)
```

French is a hard requirement. `AppleSentenceEmbedder.isAvailable` can be used
to disable the search UI before initialization. The package never falls back to
another language model.

Generate missing transcript vectors and search from an asynchronous task:

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


## Updating the catalog

Re-run `python3 build_local_database.py`, then replace the SQLite resource in
the Xcode target. During development, uninstall the app from the simulator or
device to force a fresh bundled database copy.

For production catalog updates, use a versioned resource name such as
`episodes-v2.sqlite`, or add a migration that merges new episode rows into the
database in Application Support.
