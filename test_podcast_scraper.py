from podcast_scraper import (
    ImportedEpisode,
    last_page_from_listing,
    listing_page_url,
    merge_episodes,
    parse_radio_france_listing,
)


def test_parse_radio_france_listing_extracts_importable_episode_metadata():
    html = '''
    __typename:"Expression",kind:"antenne",publishedDate:"Mardi 23 juin 2026",
    type:"episode",duration:2898,titleProps:{href:"/franceinter/podcasts/affaires-sensibles/example-123",
    text:"Une description de l\\'épisode.",title:"Un épisode \\u00e0 découvrir"},
    visual:{src:"https://www.radiofrance.fr/pikapi/images/example"},concept:void 0
    __typename:"Expression",kind:"antenne",type:"episode",duration:120,
    titleProps:{href:"",text:" ",title:"Un extrait"},
    visual:{src:"https://www.radiofrance.fr/pikapi/images/extrait"},concept:void 0
    '''

    episodes = parse_radio_france_listing(html)

    assert len(episodes) == 1
    assert episodes[0].title == "Un épisode à découvrir"
    assert episodes[0].description == "Une description de l'épisode."
    assert episodes[0].source_url == (
        "https://www.radiofrance.fr/franceinter/podcasts/affaires-sensibles/example-123"
    )
    assert episodes[0].artwork_url.endswith("/example")
    assert episodes[0].language == "fr"
    assert episodes[0].published_date == "Mardi 23 juin 2026"
    assert episodes[0].duration_seconds == 2898


def test_listing_page_url_replaces_the_page_parameter():
    assert listing_page_url(
        "https://www.radiofrance.fr/franceinter/podcasts/affaires-sensibles?p=3",
        168,
    ) == "https://www.radiofrance.fr/franceinter/podcasts/affaires-sensibles?p=168"


def test_last_page_from_listing_reads_radio_france_pagination():
    assert last_page_from_listing('pagination:{lastPage:168}') == 168


def test_merge_episodes_deduplicates_episodes_by_source_url():
    episode = ImportedEpisode(
        id="one",
        title="Episode one",
        description="",
        source_url="https://example.com/episode-one",
        artwork_url="https://example.com/artwork",
        language="fr",
        published_date=None,
        duration_seconds=None,
    )

    assert merge_episodes([episode], [episode]) == [episode]


def test_parse_radio_france_listing_excludes_series_pages_without_episode_id():
    html = '''
    __typename:"Expression",kind:"antenne",type:"episode",duration:2898,
    titleProps:{href:"/franceinter/podcasts/serie-le-grand-charles-attend",
    text:"Une série.",title:"Le Grand Charles attend"},
    visual:{src:"https://www.radiofrance.fr/pikapi/images/example"},concept:void 0
    '''

    assert parse_radio_france_listing(html) == []
