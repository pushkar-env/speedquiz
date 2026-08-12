"""Server-authoritative scoring service.

Client-provided scores are never trusted. All point awards happen here.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from app.core.config import get_settings
from app.models import GameMode
from app.services import speedrun, survival


@dataclass(frozen=True)
class ScoreBreakdown:
    base_points: int
    speed_bonus: int
    streak_multiplier: Decimal
    points_awarded: int
    new_streak: int
    lives_delta: int = 0
    #: Lump bonus for crossing a streak milestone. Already inside
    #: [points_awarded]; carried separately so the HUD can celebrate it.
    milestone_bonus: int = 0


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

    def _score_speedrun(
        self,
        *,
        is_correct: bool,
        current_streak: int,
        remaining_ms: int,
        total_ms: int,
    ) -> ScoreBreakdown:
        """Speedrun pays for speed, not for turning up.

        Its own curves live in [app.services.speedrun]: a steeper speed bonus,
        multipliers that climb to x3, and a lump bonus every fifth answer of a
        streak. The real punishment for a miss is the clock and the broken
        streak — the point penalty is only there so the number moves.
        """
        if not is_correct:
            return ScoreBreakdown(
                0, 0, Decimal("1.0"), -speedrun.WRONG_PENALTY_POINTS, 0
            )

        new_streak = current_streak + 1
        multiplier = speedrun.streak_multiplier(new_streak)
        base = self.settings.score_base_points
        speed = speedrun.speed_bonus_points(remaining_ms, total_ms)
        milestone = speedrun.milestone_bonus(new_streak)
        awarded = int(round((base + speed) * float(multiplier))) + milestone

        return ScoreBreakdown(
            base_points=base,
            speed_bonus=speed,
            streak_multiplier=multiplier,
            points_awarded=awarded,
            new_streak=new_streak,
            milestone_bonus=milestone,
        )

    def _score_survival(
        self,
        *,
        is_correct: bool,
        current_streak: int,
        remaining_ms: int,
        total_ms: int,
        lives: int,
        lives_regained: int,
        correct_count: int,
    ) -> ScoreBreakdown:
        """Survival pays most when you are closest to dying.

        Its curves live in [app.services.survival]: a last-stand multiplier on
        the final life, checkpoint bonuses every tenth correct answer, and
        lives that come back on a streak that gets longer each time.
        """
        if not is_correct:
            return ScoreBreakdown(0, 0, Decimal("1.0"), 0, 0, lives_delta=-1)

        new_streak = current_streak + 1
        multiplier = survival.streak_multiplier(new_streak)
        if survival.is_last_stand(lives):
            multiplier *= survival.LAST_STAND_MULTIPLIER

        base = self.settings.score_base_points
        speed = survival.speed_bonus_points(remaining_ms, total_ms)
        checkpoint = survival.checkpoint_bonus(correct_count + 1)
        awarded = int(round((base + speed) * float(multiplier))) + checkpoint

        lives_delta = (
            1
            if survival.should_regain_life(
                streak=new_streak,
                lives=lives,
                lives_regained=lives_regained,
            )
            else 0
        )

        return ScoreBreakdown(
            base_points=base,
            speed_bonus=speed,
            streak_multiplier=multiplier,
            points_awarded=awarded,
            new_streak=new_streak,
            lives_delta=lives_delta,
            milestone_bonus=checkpoint,
        )

    def score_answer(
        self,
        *,
        is_correct: bool,
        current_streak: int,
        remaining_ms: int,
        total_ms: int,
        mode: GameMode,
        lives: int = 0,
        lives_regained: int = 0,
        correct_count: int = 0,
    ) -> ScoreBreakdown:
        if mode == GameMode.SPEEDRUN:
            return self._score_speedrun(
                is_correct=is_correct,
                current_streak=current_streak,
                remaining_ms=remaining_ms,
                total_ms=total_ms,
            )

        if mode == GameMode.SURVIVAL:
            return self._score_survival(
                is_correct=is_correct,
                current_streak=current_streak,
                remaining_ms=remaining_ms,
                total_ms=total_ms,
                lives=lives,
                lives_regained=lives_regained,
                correct_count=correct_count,
            )

        if not is_correct:
            return ScoreBreakdown(0, 0, Decimal("1.0"), 0, 0)

        new_streak = current_streak + 1
        multiplier = self.streak_multiplier(new_streak)
        base = self.settings.score_base_points
        speed = self.speed_bonus(remaining_ms, total_ms)
        awarded = int(round((base + speed) * float(multiplier)))

        return ScoreBreakdown(
            base_points=base,
            speed_bonus=speed,
            streak_multiplier=multiplier,
            points_awarded=awarded,
            new_streak=new_streak,
        )


scoring_service = ScoringService()
