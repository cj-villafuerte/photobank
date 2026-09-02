from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

ENV_FILE = Path(__file__).resolve().parents[2] / ".env"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=ENV_FILE, env_file_encoding="utf-8", extra="ignore")

    database_url: str = "postgresql+asyncpg://photobank:photobank@localhost:5432/photobank"
    database_url_sync: str = "postgresql+psycopg://photobank:photobank@localhost:5432/photobank"
    storage_root: Path = Path("C:/photobank-data")
    secret_key: str = "dev-insecure-secret"
    host: str = "0.0.0.0"
    port: int = 8000
    allow_registration: bool = True
    session_days: int = 14

    @property
    def library_dir(self) -> Path:
        return self.storage_root / "library"

    @property
    def thumbs_dir(self) -> Path:
        return self.storage_root / "thumbs"

    @property
    def tmp_dir(self) -> Path:
        return self.storage_root / "tmp"


settings = Settings()
