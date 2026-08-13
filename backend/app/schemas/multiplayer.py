"""Wire contract for friends, matches and the ranked ladder.

Two conventions worth stating, because they are load-bearing:

* **Deadlines travel as absolute timestamps, not durations.** A duration is
  wrong by the time it arrives, and the error is exactly the network latency
  the round clock is trying to be fair about. The client renders a countdown by
  subtracting from its own clock, corrected by the `server_time` every state
  response carries.
* **No response ever contains an answer key for an unanswered round.** The
  correct option appears in [MatchAnswerFeedbackOut] and in the round-end
  event, both of which are only produced after the round is closed for the
  recipient.
"""

from __future__ import annotations

from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field, field_validator

from app.core.languages import ContentLanguage
from app.models import (
    DevicePlatform,
    DifficultyLabel,
    MatchDelivery,
    MatchFormat,
    MatchKind,
    MatchOutcome,
    MatchStatus,
    NotificationType,
    ParticipantStatus,
)

# --- Players ---------------------------------------------------------------


class PlayerBriefOut(BaseModel):
    """The identity card shown wherever a player appears next to their name."""

    user_id: UUID
    username: str
    display_name: Optional[str] = None
    avatar_id: str = "avatar_01"
    level: int = 1
    is_premium: bool = False
    #: Ranked standing, when the viewer is allowed to see it. None for players
    #: who have never played ranked or are still in placements.
    rating: Optional[int] = None
    tier: Optional[str] = None
    tier_icon: Optional[str] = None

    model_config = {"from_attributes": True}


class HeadToHeadOut(BaseModel):
    wins: int = 0
    losses: int = 0
    draws: int = 0


class FriendOut(BaseModel):
    friendship_id: UUID
    player: PlayerBriefOut
    friends_since: Optional[datetime] = None
    head_to_head: HeadToHeadOut = Field(default_factory=HeadToHeadOut)
    #: True when this friend currently holds a realtime connection, so the UI
    #: can offer "challenge now" rather than "send a challenge".
    is_online: bool = False
    #: Set when there is an open match between the two of you.
    open_match_id: Optional[UUID] = None


class FriendListResponse(BaseModel):
    items: list[FriendOut]
    total: int


class FriendRequestOut(BaseModel):
    id: UUID
    player: PlayerBriefOut
    #: "incoming" — they asked you. "outgoing" — you asked them.
    direction: str
    created_at: datetime


class FriendRequestListResponse(BaseModel):
    incoming: list[FriendRequestOut]
    outgoing: list[FriendRequestOut]


class PlayerSearchResponse(BaseModel):
    items: list[PlayerBriefOut]
    #: Relationship to the searcher, keyed by user id: none / friends /
    #: request_sent / request_received. Lets one screen render every state
    #: without a second call per row.
    relationships: dict[UUID, str] = Field(default_factory=dict)


class SendFriendRequestRequest(BaseModel):
    user_id: Optional[UUID] = None
    username: Optional[str] = None
    friend_code: Optional[str] = None


# --- Usernames -------------------------------------------------------------


class UsernameAvailabilityResponse(BaseModel):
    username: str
    available: bool
    #: Populated when `available` is false, so the client can explain why
    #: rather than just refusing.
    reason: Optional[str] = None
    suggestions: list[str] = Field(default_factory=list)


class ChangeUsernameRequest(BaseModel):
    username: str = Field(min_length=3, max_length=20)


class UsernameStatusResponse(BaseModel):
    username: str
    friend_code: str
    #: None when the player may change their name right now.
    change_available_at: Optional[datetime] = None


# --- Matches ---------------------------------------------------------------


class MatchParticipantOut(BaseModel):
    user_id: UUID
    player: PlayerBriefOut
    status: ParticipantStatus
    is_host: bool = False
    is_me: bool = False
    #: Holding a live realtime connection right now.
    is_connected: bool = False
    score: int = 0
    correct_count: int = 0
    rounds_answered: int = 0
    best_streak: int = 0
    #: Whether they have answered the round currently in play. Deliberately
    #: carries no correctness — seeing that an opponent got it right before you
    #: have answered would leak the answer.
    answered_current_round: bool = False
    placement: Optional[int] = None
    outcome: Optional[MatchOutcome] = None
    rating_before: Optional[int] = None
    rating_after: Optional[int] = None
    rating_delta: Optional[int] = None
    xp_earned: int = 0
    coins_earned: int = 0


class MatchOut(BaseModel):
    id: UUID
    code: Optional[str] = None
    format: MatchFormat
    kind: MatchKind
    delivery: MatchDelivery
    status: MatchStatus
    topic_id: UUID
    topic_name: str
    difficulty: DifficultyLabel
    language: str
    question_count: int
    question_time_limit_ms: int
    max_players: int
    current_round_index: int
    host_user_id: UUID
    participants: list[MatchParticipantOut]
    created_at: datetime
    started_at: Optional[datetime] = None
    finished_at: Optional[datetime] = None
    expires_at: Optional[datetime] = None
    #: When the round in play closes. The client counts down to this.
    round_deadline_at: Optional[datetime] = None
    #: Server's clock at the moment this response was built. The client offsets
    #: every deadline by (server_time - local_time) so a device with a skewed
    #: clock still sees an honest timer.
    server_time: datetime
    #: How far this player has got — the async cursor, and what the client uses
    #: to decide whether to show the lobby, the board, or the result.
    my_rounds_answered: int = 0
    my_outcome: Optional[MatchOutcome] = None


class MatchOptionOut(BaseModel):
    index: int
    text: str


class MatchRoundOut(BaseModel):
    """One playable question, as this player should see it right now."""

    round_index: int
    total_rounds: int
    question_id: UUID
    prompt: str
    options: list[MatchOptionOut]
    time_limit_ms: int
    #: Absolute close time. In a live match this is the shared clock; in an
    #: async match it starts when this player is served.
    deadline_at: datetime
    served_at: datetime
    server_time: datetime
    #: True once this player has answered and is waiting on everyone else.
    already_answered: bool = False


class OpponentRoundStateOut(BaseModel):
    user_id: UUID
    answered: bool
    #: Only ever populated after the round has closed.
    is_correct: Optional[bool] = None
    points_awarded: Optional[int] = None


class MatchAnswerFeedbackOut(BaseModel):
    round_index: int
    is_correct: bool
    correct_option_index: int
    selected_option_index: Optional[int] = None
    points_awarded: int
    speed_bonus: int
    streak: int
    score: int
    explanation: Optional[str] = None
    #: Whether the match moved on as a result of this answer.
    round_closed: bool = False
    match_finished: bool = False
    opponents: list[OpponentRoundStateOut] = Field(default_factory=list)
    server_time: datetime


class MatchResultOut(BaseModel):
    match: MatchOut
    standings: list[MatchParticipantOut]
    my_outcome: Optional[MatchOutcome] = None
    my_placement: Optional[int] = None
    rating_delta: Optional[int] = None
    xp_earned: int = 0
    coins_earned: int = 0


class CreateMatchRequest(BaseModel):
    topic_id: UUID
    difficulty: DifficultyLabel = DifficultyLabel.MEDIUM
    language: Optional[ContentLanguage] = None
    question_count: Optional[int] = None
    question_time_limit_ms: Optional[int] = None
    format: MatchFormat = MatchFormat.DUEL
    #: Who to challenge. Omitted for an open room, which is joined by code.
    opponent_user_id: Optional[UUID] = None
    #: Room seats, 2-8. Ignored for a duel.
    max_players: Optional[int] = None

    @field_validator("question_count")
    @classmethod
    def _sane_count(cls, value: Optional[int]) -> Optional[int]:
        if value is not None and not 3 <= value <= 20:
            raise ValueError("question_count must be between 3 and 20")
        return value


class JoinMatchRequest(BaseModel):
    code: str = Field(min_length=4, max_length=12)


class SubmitMatchAnswerRequest(BaseModel):
    round_index: int = Field(ge=0)
    #: None means the clock ran out with nothing chosen.
    selected_option_index: Optional[int] = Field(default=None, ge=0, le=3)
    client_elapsed_ms: Optional[int] = Field(default=None, ge=0)


class MatchListResponse(BaseModel):
    #: Matches waiting on this player: an unanswered invite, or their turn.
    active: list[MatchOut]
    recent: list[MatchOut]


# --- Ranked ----------------------------------------------------------------


class RankedProfileOut(BaseModel):
    season_key: str
    rating: int
    peak_rating: int
    tier: str
    tier_name: str
    tier_icon: str
    #: None at the top of the ladder.
    next_tier: Optional[str] = None
    next_tier_at: Optional[int] = None
    placements_remaining: int
    matches_played: int
    wins: int
    losses: int
    draws: int
    win_streak: int
    rank: Optional[int] = None


class RankedLeaderboardEntryOut(BaseModel):
    rank: int
    player: PlayerBriefOut
    rating: int
    wins: int
    losses: int
    is_me: bool = False


class RankedLeaderboardResponse(BaseModel):
    season_key: str
    items: list[RankedLeaderboardEntryOut]
    me: Optional[RankedLeaderboardEntryOut] = None


class QueueTicketResponse(BaseModel):
    """State of a ranked matchmaking search."""

    #: searching | matched | timeout | cancelled
    state: str
    match_id: Optional[UUID] = None
    #: How long this ticket has been waiting, so the UI can show progress.
    waited_seconds: int = 0
    #: Current rating band being searched, for the "widening search" copy.
    band: int = 0
    players_searching: Optional[int] = None


class QueueJoinRequest(BaseModel):
    topic_id: Optional[UUID] = None
    language: Optional[ContentLanguage] = None


# --- Realtime --------------------------------------------------------------


class RealtimeTicketResponse(BaseModel):
    ticket: str
    #: Path to open, relative to the API host. Saves the client from
    #: reconstructing the URL and getting the prefix wrong.
    url: str
    expires_in_seconds: int


# --- Notifications and devices ---------------------------------------------


class RegisterDeviceRequest(BaseModel):
    token: str = Field(min_length=8, max_length=4096)
    platform: DevicePlatform = DevicePlatform.ANDROID
    app_version: Optional[str] = Field(default=None, max_length=32)
    language: Optional[ContentLanguage] = None
    #: Minutes east of UTC, from the device. Used for quiet hours; a server
    #: that guesses this silences the wrong six hours for most of the world.
    utc_offset_minutes: int = Field(default=0, ge=-840, le=840)


class NotificationOut(BaseModel):
    id: UUID
    type: NotificationType
    actor: Optional[PlayerBriefOut] = None
    match_id: Optional[UUID] = None
    payload: dict = Field(default_factory=dict)
    deep_link: Optional[str] = None
    read_at: Optional[datetime] = None
    created_at: datetime


class NotificationListResponse(BaseModel):
    items: list[NotificationOut]
    unread_count: int


class NotificationPrefsRequest(BaseModel):
    """Per-type opt-outs. Absent keys are left unchanged."""

    prefs: dict[str, bool]
