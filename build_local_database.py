from pathlib import Path

from deepgram_api import (
    AUDIO_DIR,
    DATABASE_PATH,
    OUTPUT_DIR,
    SUMMARY_DIR,
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


def build_database(database_path: Path = DATABASE_PATH) -> int:
    summary_paths = sorted(SUMMARY_DIR.glob("*.txt"))
    if not summary_paths:
        raise FileNotFoundError(f"No summaries found in {SUMMARY_DIR}.")
    count = 0
    with initialize_database(database_path) as database:
        for summary_path in summary_paths:
            transcript_path = OUTPUT_DIR / summary_path.name
            if not transcript_path.is_file():
                raise FileNotFoundError(f"Missing transcript {transcript_path}.")
            audio_path = find_audio_path(summary_path.stem)
            upsert_episode(
                database=database,
                audio_path=audio_path,
                transcript_path=transcript_path,
                summary_path=summary_path,
                transcript=transcript_path.read_text(encoding="utf-8"),
                summary=summary_path.read_text(encoding="utf-8"),
            )
            count += 1
        database.commit()

    return count


def main() -> None:
    count = build_database()
    print(f"Stored {count} episode(s) in {DATABASE_PATH}")


if __name__ == "__main__":
    main()
