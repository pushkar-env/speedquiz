"""Feed parsing and corpus helpers (no DB, no network)."""

from datetime import datetime, timezone

import pytest

from app.core.languages import ContentLanguage
from app.services.news_corpus import (
    CATEGORIES,
    DEFAULT_FEEDS,
    Feed,
    configured_feeds,
    document_hash,
    parse_feed,
)

FEED = Feed("https://www.example.com/rss", "world")

RSS = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Example News</title>
    <item>
      <title>Parliament passes the budget</title>
      <link>https://www.example.com/news/budget-2026</link>
      <description>&lt;p&gt;The bill cleared both houses.&lt;/p&gt;</description>
      <pubDate>Wed, 12 Aug 2026 09:30:00 +0000</pubDate>
    </item>
    <item>
      <title>Second story</title>
      <link>https://www.example.com/news/second</link>
      <description>More detail.</description>
      <pubDate>Tue, 11 Aug 2026 18:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>
"""

ATOM = """<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Example Atom</title>
  <entry>
    <title>Rover reaches the crater</title>
    <link href="https://www.example.com/atom/rover"/>
    <summary>It landed on Tuesday.</summary>
    <published>2026-08-12T14:05:00Z</published>
  </entry>
</feed>
"""


def test_parses_rss_items():
    docs = parse_feed(RSS, FEED, limit=10)
    assert len(docs) == 2
    first = docs[0]
    assert first["title"] == "Parliament passes the budget"
    assert first["url"] == "https://www.example.com/news/budget-2026"
    assert first["summary"] == "The bill cleared both houses."
    assert first["published_at"] == datetime(2026, 8, 12, 9, 30, tzinfo=timezone.utc)
    assert first["category"] == "world"
    assert first["language"] == "en"
    assert first["source"] == "example.com"


def test_parses_atom_entries_with_href_links():
    docs = parse_feed(ATOM, FEED, limit=10)
    assert len(docs) == 1
    assert docs[0]["url"] == "https://www.example.com/atom/rover"
    assert docs[0]["published_at"] == datetime(2026, 8, 12, 14, 5, tzinfo=timezone.utc)


def test_double_encoded_entities_are_decoded():
    """Aaj Tak and The Verge ship `&amp;#039;`, so the parser hands back a
    literal `&#039;` that would otherwise reach the model inside a headline it
    is being asked to build a question from."""
    xml = RSS.replace(
        "Parliament passes the budget",
        "&amp;#039;I was angry&amp;#039;, says minister &amp;#8216;now&amp;#8217;",
    )
    docs = parse_feed(xml, FEED, limit=10)
    assert docs[0]["title"] == "'I was angry', says minister ‘now’"
    assert "&#" not in docs[0]["title"]


def test_html_markup_is_stripped_from_summaries():
    xml = RSS.replace(
        "&lt;p&gt;The bill cleared both houses.&lt;/p&gt;",
        "&lt;div&gt;&lt;a href='x'&gt;Read&lt;/a&gt; the   full text&lt;/div&gt;",
    )
    docs = parse_feed(xml, FEED, limit=10)
    assert docs[0]["summary"] == "Read the full text"


def test_undated_items_are_dropped():
    """An undated document cannot anchor a TTL, and defaulting to now would let
    a month-old story mint a question with a fresh 30-day life."""
    xml = RSS.replace("<pubDate>Wed, 12 Aug 2026 09:30:00 +0000</pubDate>", "")
    docs = parse_feed(xml, FEED, limit=10)
    assert [d["title"] for d in docs] == ["Second story"]


def test_items_without_a_title_or_link_are_dropped():
    xml = RSS.replace("<title>Parliament passes the budget</title>", "<title></title>")
    assert len(parse_feed(xml, FEED, limit=10)) == 1


def test_limit_is_respected():
    assert len(parse_feed(RSS, FEED, limit=1)) == 1


def test_malformed_xml_returns_nothing_rather_than_raising():
    """Feeds are untrusted input from hosts we do not control; one bad response
    must not take down a harvest of thirteen others."""
    assert parse_feed("<rss><channel><item>", FEED, limit=10) == []
    assert parse_feed("", FEED, limit=10) == []


# --- dedupe ------------------------------------------------------------------


def test_hash_ignores_tracking_parameters_and_trailing_slashes():
    """Aggregators append per-fetch tracking params, so the same story would
    otherwise be inserted afresh on every harvest cycle."""
    a = document_hash("https://example.com/news/story", "A headline")
    b = document_hash("https://example.com/news/story/?utm_source=rss", "A headline")
    c = document_hash("https://WWW.example.com/news/story", "  a headline  ")
    assert a == b == c


def test_hash_separates_distinct_stories():
    a = document_hash("https://example.com/a", "Headline one")
    b = document_hash("https://example.com/b", "Headline one")
    c = document_hash("https://example.com/a", "Headline two")
    assert len({a, b, c}) == 3


# --- configuration -----------------------------------------------------------


def test_default_feeds_cover_every_category_and_both_languages():
    covered = {f.category for f in DEFAULT_FEEDS}
    assert covered == set(CATEGORIES)
    assert {f.language for f in DEFAULT_FEEDS} == {
        ContentLanguage.ENGLISH,
        ContentLanguage.HINDI,
    }


def test_feed_source_strips_the_www_prefix():
    assert Feed("https://www.thehindu.com/x.rss", "india").source == "thehindu.com"
    assert Feed("https://feeds.bbci.co.uk/x.xml", "world").source == "feeds.bbci.co.uk"


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("https://a.com/rss|sport|hi", Feed("https://a.com/rss", "sport", ContentLanguage.HINDI)),
        ("https://a.com/rss|sport", Feed("https://a.com/rss", "sport")),
        ("https://a.com/rss", Feed("https://a.com/rss", "general")),
    ],
)
def test_settings_override_parses_url_category_language(monkeypatch, raw, expected):
    monkeypatch.setattr("app.services.news_corpus.settings.news_feed_urls", raw)
    assert configured_feeds() == [expected]


def test_blank_override_falls_back_to_the_built_in_list(monkeypatch):
    monkeypatch.setattr("app.services.news_corpus.settings.news_feed_urls", "   ")
    assert configured_feeds() == list(DEFAULT_FEEDS)
