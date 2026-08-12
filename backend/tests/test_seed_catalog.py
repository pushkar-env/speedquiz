"""Catalog seeding is upsert-by-slug, not seed-once.

The bug this covers: the original `seed_reference_data` only inserted anything
when the categories table was empty, so every topic added to `TOPICS` after a
deployment's first boot never appeared in that database — and neither did the
curated questions targeting it.
"""

from uuid import uuid4

import pytest

from app.models import Topic, TopicCategory
from app.services.seed import (
    CATEGORIES,
    TOPICS,
    _upsert_categories,
    _upsert_topics,
    refresh_catalog_translations,
)


class _SeedSession:
    """Enough of an async session for the seed helpers: a typed row store."""

    def __init__(self, rows=()):
        self.rows = list(rows)
        self.flushes = 0

    def add(self, row):
        self.rows.append(row)

    async def flush(self):
        self.flushes += 1

    async def execute(self, statement):
        entity = statement.column_descriptions[0]["entity"]
        # `select(Topic.slug)` describes the column's owning entity, so a
        # scalar-column select and a whole-entity select both resolve here.
        selecting_column = statement.column_descriptions[0]["name"] == "slug"
        matched = [r for r in self.rows if isinstance(r, entity)]
        if selecting_column:
            matched = [r.slug for r in matched]
        return _Result(matched)

    async def scalar(self, statement):
        result = await self.execute(statement)
        rows = result.scalars().all()
        return rows[0] if rows else None


class _Result:
    def __init__(self, rows):
        self._rows = rows

    def scalars(self):
        return self

    def all(self):
        return list(self._rows)


def _category(slug="science", name="Science"):
    # `id` is normally assigned on insert; set it here so the topic upsert has
    # a real foreign key to point at without a database round trip.
    return TopicCategory(
        id=uuid4(),
        slug=slug,
        name=name,
        icon="🔬",
        sort_order=10,
        name_i18n={},
    )


def _topic(slug, category, name="Existing"):
    return Topic(
        slug=slug,
        name=name,
        icon="📗",
        category_id=category.id,
        name_i18n={},
        description_i18n={},
    )


@pytest.mark.asyncio
async def test_categories_are_inserted_only_when_missing():
    db = _SeedSession([_category()])

    added = await _upsert_categories(db)

    assert added == len(CATEGORIES) - 1
    slugs = [c.slug for c in db.rows if isinstance(c, TopicCategory)]
    assert len(slugs) == len(set(slugs)), "an existing category was duplicated"


@pytest.mark.asyncio
async def test_a_topic_added_after_first_boot_still_lands():
    """The regression: a database seeded before `cricket` existed gets it."""
    categories = [_category(slug, name) for slug, name, _, _ in CATEGORIES]
    db = _SeedSession([*categories, _topic("science", categories[0])])

    added = await _upsert_topics(db)

    assert added == len(TOPICS) - 1
    inserted = {t.slug for t in db.rows if isinstance(t, Topic)}
    assert "cricket" in inserted
    assert "indian-history" in inserted


@pytest.mark.asyncio
async def test_reseeding_a_complete_catalog_writes_nothing():
    categories = [_category(slug, name) for slug, name, _, _ in CATEGORIES]
    by_slug = {c.slug: c for c in categories}
    topics = [
        _topic(slug, by_slug[category_slug], name)
        for slug, name, category_slug, _, _ in TOPICS
    ]
    db = _SeedSession([*categories, *topics])
    before = len(db.rows)

    assert await _upsert_categories(db) == 0
    assert await _upsert_topics(db) == 0
    assert len(db.rows) == before
    assert db.flushes == 0, "a steady-state boot should not write"


@pytest.mark.asyncio
async def test_existing_rows_keep_their_live_values():
    """Names and icons are operator-tunable; only translations are refreshed."""
    categories = [_category(slug, name) for slug, name, _, _ in CATEGORIES]
    tuned = _topic("cricket", categories[0], name="Cricket (India)")
    tuned.icon = "🇮🇳"
    db = _SeedSession([*categories, tuned])

    await _upsert_topics(db)
    await refresh_catalog_translations(db)

    assert tuned.name == "Cricket (India)"
    assert tuned.icon == "🇮🇳"
    # Translations *are* content that ships with a deploy.
    assert tuned.name_i18n == {"hi": "क्रिकेट"}


@pytest.mark.asyncio
async def test_a_topic_in_no_known_category_is_skipped_not_orphaned():
    db = _SeedSession([_category()])

    added = await _upsert_topics(db)

    # Only the topics whose category exists were created.
    science_topics = sum(1 for _, _, cat, _, _ in TOPICS if cat == "science")
    assert added == science_topics
    assert all(
        t.category_id is not None for t in db.rows if isinstance(t, Topic)
    )
