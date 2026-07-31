from pathlib import Path

from deepgram_api import (
    AUDIO_DIR,
    DATABASE_PATH,
    OUTPUT_DIR,
    initialize_database,
    is_audio_file,
    upsert_episode,
)


def find_audio_path(stem: str) -> Path:
    matches = sorted(
        path for path in AUDIO_DIR.iterdir() if is_audio_file(path) and path.stem == stem
    )
    if not matches:
        raise FileNotFoundError(f"No audio file matches transcript {stem!r}.")
    return matches[0]


def remove_existing_database(database_path: Path) -> None:
    for path in (
        database_path,
        database_path.with_name(f"{database_path.name}-shm"),
        database_path.with_name(f"{database_path.name}-wal"),
    ):
        path.unlink(missing_ok=True)


def build_database(database_path: Path = DATABASE_PATH) -> int:
    transcript_paths = sorted(OUTPUT_DIR.glob("*.txt"))
    if not transcript_paths:
        raise FileNotFoundError(f"No transcripts found in {OUTPUT_DIR}.")

    remove_existing_database(database_path)
    count = 0
    with initialize_database(database_path) as database:
        for transcript_path in transcript_paths:
            audio_path = find_audio_path(transcript_path.stem)
            upsert_episode(
                database=database,
                audio_path=audio_path,
                transcript_path=transcript_path,
                transcript=transcript_path.read_text(encoding="utf-8"),
            )
            count += 1
        database.commit()

    return count


def main() -> None:
    count = build_database()
    print(f"Stored {count} episode(s) in {DATABASE_PATH}")


if __name__ == "__main__":
    main()
