from fastapi import APIRouter

from app.api.v1 import auth, catalog, custom_topics, health, questions, quiz

api_router = APIRouter()
api_router.include_router(health.router)
api_router.include_router(auth.router)
api_router.include_router(catalog.router)
api_router.include_router(quiz.router)
api_router.include_router(custom_topics.router)
api_router.include_router(questions.router)
