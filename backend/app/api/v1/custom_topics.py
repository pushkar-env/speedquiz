"""Custom topic endpoints."""

from uuid import UUID

from fastapi import APIRouter, status
from sqlalchemy import select

from app.auth.deps import CurrentUser, DbSession
from app.models import GenerationJob
from app.schemas.custom_topics import (
    CreateCustomTopicRequest,
    CustomTopicResponse,
    GenerationJobOut,
)
from app.services import custom_topics as custom_topics_service

router = APIRouter(prefix="/custom-topics", tags=["custom-topics"])


@router.post("", response_model=CustomTopicResponse, status_code=status.HTTP_201_CREATED)
async def create_custom_topic(
    payload: CreateCustomTopicRequest,
    user: CurrentUser,
    db: DbSession,
) -> CustomTopicResponse:
    return await custom_topics_service.create_custom_topic_quiz(db, user, payload)


@router.get("/jobs/{job_id}", response_model=GenerationJobOut)
async def get_generation_job(
    job_id: UUID,
    user: CurrentUser,
    db: DbSession,
) -> GenerationJobOut:
    job = await db.scalar(
        select(GenerationJob).where(
            GenerationJob.id == job_id,
            GenerationJob.requested_by_user_id == user.id,
        )
    )
    if not job:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="Job not found")
    return GenerationJobOut(
        id=job.id,
        status=job.status.value,
        approved_count=job.approved_count,
        rejected_count=job.rejected_count,
        error_message=job.error_message,
    )
