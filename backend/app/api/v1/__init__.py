from fastapi import APIRouter

from app.api.v1 import (
    achievements,
    auth,
    billing_webhooks,
    catalog,
    custom_quizzes,
    custom_topics,
    daily,
    entitlements,
    health,
    leaderboards,
    multiplayer,
    questions,
    quiz,
    share,
    social,
)

api_router = APIRouter()
api_router.include_router(health.router)
api_router.include_router(auth.router)
api_router.include_router(catalog.router)
api_router.include_router(quiz.router)
api_router.include_router(custom_topics.router)
api_router.include_router(custom_quizzes.router)
api_router.include_router(questions.router)
api_router.include_router(achievements.router)
api_router.include_router(daily.router)
api_router.include_router(leaderboards.router)
api_router.include_router(entitlements.router)
api_router.include_router(billing_webhooks.router)
api_router.include_router(share.router)
api_router.include_router(social.router)
api_router.include_router(multiplayer.router)
