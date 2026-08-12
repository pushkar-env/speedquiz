"""A minimal async-session stand-in for payment tests.

The suite is otherwise DB-free, and spinning up Postgres to assert "a refund
revokes premium" would be a poor trade. This fake implements just the surface
the billing code touches, with an in-memory row store that `scalar`/`scalars`
query through a caller-supplied predicate.
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import Any, Callable, Iterable, Optional


class _Scalars:
    def __init__(self, rows: list[Any]):
        self._rows = rows

    def all(self) -> list[Any]:
        return list(self._rows)

    def __iter__(self):
        return iter(self._rows)


class FakeSession:
    """Stores model instances in a list and answers queries via `resolver`.

    `resolver(model, rows)` returns the rows a statement should match. The
    default returns everything of the requested type, which is enough for the
    billing paths because they filter on identity fields the tests set up
    explicitly.
    """

    def __init__(
        self,
        rows: Optional[Iterable[Any]] = None,
        *,
        resolver: Optional[Callable[[Any, list[Any]], list[Any]]] = None,
    ):
        self.rows: list[Any] = list(rows or [])
        self.added: list[Any] = []
        self.flush_count = 0
        self.rollbacks = 0
        self._resolver = resolver
        #: Queue of explicit results, consumed before falling back to `rows`.
        self.scalar_results: list[Any] = []

    # --- query surface ---

    def _entity(self, statement: Any) -> Any:
        try:
            return statement.column_descriptions[0]["entity"]
        except (AttributeError, IndexError, KeyError, TypeError):
            return None

    def _matching(self, statement: Any) -> list[Any]:
        model = self._entity(statement)
        candidates = [r for r in self.rows if model is None or isinstance(r, model)]
        if self._resolver is not None:
            return self._resolver(model, candidates)
        return candidates

    async def scalar(self, statement: Any) -> Any:
        if self.scalar_results:
            return self.scalar_results.pop(0)
        matches = self._matching(statement)
        return matches[0] if matches else None

    async def scalars(self, statement: Any) -> _Scalars:
        return _Scalars(self._matching(statement))

    async def execute(self, statement: Any) -> _Scalars:
        return _Scalars(self._matching(statement))

    # --- mutation surface ---

    def add(self, obj: Any) -> None:
        self.added.append(obj)
        self.rows.append(obj)

    async def flush(self) -> None:
        self.flush_count += 1

    async def rollback(self) -> None:
        self.rollbacks += 1

    @asynccontextmanager
    async def begin_nested(self):
        yield self


def predicate_resolver(
    predicates: dict[Any, Callable[[Any], bool]],
) -> Callable[[Any, list[Any]], list[Any]]:
    """Build a resolver that filters each model with its own predicate."""

    def _resolve(model: Any, rows: list[Any]) -> list[Any]:
        check = predicates.get(model)
        return [r for r in rows if check(r)] if check else rows

    return _resolve
