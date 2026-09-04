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
    # desktop app only: secret that lets the app's own window sign in as the
    # passwordless local administrator (loopback requests only)
    local_admin_token: str | None = None
    disable_mdns: bool = False  # containers / cloud hosts: no LAN to announce on

    # Demo server (public instance for App Review and for trying the app): one
    # shared non-admin account, a seeded read-only sample library, image uploads
    # that are purged after a few seconds, no admin/backup/password endpoints.
    demo_mode: bool = False
    demo_email: str = "demo@photobank.app"
    demo_password: str = "photobank-demo"
    demo_upload_ttl_seconds: int = 5
    demo_max_uploads: int = 100  # live uploads at once, across every user
    demo_max_upload_mb: int = 12  # per file
    demo_max_total_upload_mb: int = 300  # live upload bytes, across every user
    demo_reset_minutes: int = 60  # favorites/albums/hidden on the sample library reset
    demo_seed_count: int = 36

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
