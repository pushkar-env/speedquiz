"""Server-authoritative scoring service.

Client-provided scores are never trusted. All point awards happen here.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from app.core.config import get_settings
from app.models import GameMode


@dataclass(frozen=True)
class ScoreBreakdown:
    base_points: int
    speed_bonus: int
    streak_multiplier: Decimal
    points_awarded: int
    new_streak: int
    lives_delta: int = 0


class ScoringService:
    def __init__(self) -> None:
        self.settings = get_settings()
        self._tiers = self._parse_tiers(self.settings.streak_multiplier_tiers)

    @staticmethod
    def _parse_tiers(raw: str) -> list[tuple[int, Decimal]]:
        tiers: list[tuple[int, Decimal]] = []
        for part in raw.split(","):
            threshold, multiplier = part.split(":")
            tiers.append((int(threshold), Decimal(multiplier)))
        return sorted(tiers, key=lambda t: t[0])

    def streak_multiplier(self, streak: int) -> Decimal:
        multiplier = Decimal("1.0")
        for threshold, value in self._tiers:
            if streak >= threshold:
                multiplier = value
        return multiplier

    def speed_bonus(self, remaining_ms: int, total_ms: int) -> int:
        if total_ms <= 0 or remaining_ms <= 0:
            return 0
        ratio = min(max(remaining_ms / total_ms, 0.0), 1.0)
        return int(round(ratio * self.settings.score_speed_bonus_max))

    def score_answer(
        self,
        *,
        is_correct: bool,
        current_streak: int,
        remaining_ms: int,
        total_ms: int,
        mode: GameMode,
    ) -> ScoreBreakdown:
        if not is_correct:
            new_streak = 0
            if mode == GameMode.NEGATIVE:
                return ScoreBreakdown(0, 0, Decimal("1.0"), -150, new_streak)
            if mode == GameMode.SPEEDRUN:
                return ScoreBreakdown(0, 0, Decimal("1.0"), -50, new_streak)
            if mode == GameMode.SURVIVAL:
                return ScoreBreakdown(0, 0, Decimal("1.0"), 0, new_streak, lives_delta=-1)
            if mode == GameMode.SUDDEN_DEATH:
                return ScoreBreakdown(0, 0, Decimal("1.0"), 0, new_streak)
            return ScoreBreakdown(0, 0, Decimal("1.0"), 0, new_streak)

        new_streak = current_streak + 1
        multiplier = self.streak_multiplier(new_streak)
        base = self.settings.score_base_points
        speed = self.speed_bonus(remaining_ms, total_ms)
        awarded = int(round((base + speed) * float(multiplier)))

        lives_delta = 0
        if mode == GameMode.SURVIVAL and new_streak > 0 and new_streak % 10 == 0:
            lives_delta = 1

        return ScoreBreakdown(
            base_points=base,
            speed_bonus=speed,
            streak_multiplier=multiplier,
            points_awarded=awarded,
            new_streak=new_streak,
            lives_delta=lives_delta,
        )


scoring_service = ScoringService()
