import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: str
    display_name: str
    is_admin: bool
    is_active: bool
    created_at: datetime


class RegisterIn(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8)
    display_name: str = Field(min_length=1, max_length=100)


class LoginIn(BaseModel):
    email: EmailStr
    password: str


class PasswordChange(BaseModel):
    current_password: str
    new_password: str = Field(min_length=8)


class AssetOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    original_filename: str
    file_size: int
    mime_type: str
    asset_type: str
    width: int | None
    height: int | None
    duration_sec: float | None
    taken_at: datetime
    taken_at_source: str
    gps_lat: float | None
    gps_lon: float | None
    camera_make: str | None
    camera_model: str | None
    is_favorite: bool
    trashed_at: datetime | None
    hidden_at: datetime | None = None
    thumb_status: str
    has_live_video: bool = False
    created_at: datetime


class AssetThin(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    asset_type: str
    width: int | None
    height: int | None
    duration_sec: float | None
    taken_at: datetime
    is_favorite: bool
    thumb_status: str
    has_live_video: bool = False
    file_size: int = 0


class UploadResult(BaseModel):
    duplicate: bool = False
    asset: AssetOut | None = None
    asset_id: uuid.UUID | None = None


class AssetPatch(BaseModel):
    is_favorite: bool | None = None


class TimelineBucket(BaseModel):
    bucket: str
    count: int


class AlbumOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    cover_asset_id: uuid.UUID | None
    created_at: datetime
    asset_count: int = 0


class AlbumDetail(AlbumOut):
    assets: list[AssetThin] = []


class AlbumCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)


class AlbumPatch(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    cover_asset_id: uuid.UUID | None = None


class AssetIds(BaseModel):
    asset_ids: list[uuid.UUID]


class ChecksumsIn(BaseModel):
    checksums: list[str] = Field(max_length=2000)


class ExistsDetail(BaseModel):
    checksum: str
    asset_id: uuid.UUID
    has_live_video: bool


class ChecksumsOut(BaseModel):
    existing: list[str]
    details: list[ExistsDetail] = []


class MatchItem(BaseModel):
    key: str  # opaque client id echoed back
    name: str
    taken_at: str | None = None  # device wall-clock time, "YYYY-MM-DDTHH:MM:SS"
    width: int | None = None
    height: int | None = None
    duration_sec: float | None = None


class MatchIn(BaseModel):
    items: list[MatchItem] = Field(max_length=500)


class MatchResult(BaseModel):
    key: str
    asset_id: uuid.UUID
    checksum: str
    has_live_video: bool


class MatchOut(BaseModel):
    matches: list[MatchResult]


class DuplicateGroup(BaseModel):
    assets: list[AssetThin]
    wasted_bytes: int


class TextMatch(BaseModel):
    word: str
    x: float
    y: float
    w: float
    h: float


class TextSearchResult(BaseModel):
    asset: AssetThin
    matches: list[TextMatch]


class DailyStat(BaseModel):
    date: str
    count: int
    bytes: int


class StatsOut(BaseModel):
    total_count: int
    total_bytes: int
    image_count: int
    video_count: int
    daily: list[DailyStat]


class AdminUserCreate(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8)
    display_name: str = Field(min_length=1, max_length=100)
    is_admin: bool = False


class AdminUserPatch(BaseModel):
    is_active: bool | None = None
    is_admin: bool | None = None
    password: str | None = Field(default=None, min_length=8)
