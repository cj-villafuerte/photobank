"""Photobank desktop entry point.

Launching this (or the frozen Photobank.exe) configures a self-contained
environment in %LOCALAPPDATA%\\Photobank (SQLite database, generated secret),
starts the server in a background thread, and opens a native window on the
web UI. Closing the window shuts the server down. The server still binds
0.0.0.0 so phones on the LAN can sync to it while the app is open.
"""

import json
import os
import secrets
import socket
import sys
import threading
import time
import urllib.request
from pathlib import Path

APP_DIR = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "Photobank"
CONFIG_FILE = APP_DIR / "config.json"


def load_or_create_config() -> dict:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    if CONFIG_FILE.is_file():
        # utf-8-sig tolerates a BOM if the file was edited by a Windows tool
        cfg = json.loads(CONFIG_FILE.read_text(encoding="utf-8-sig"))
    else:
        cfg = {}
    changed = False
    if "secret_key" not in cfg:
        cfg["secret_key"] = secrets.token_hex(32)
        changed = True
    if "storage_root" not in cfg:
        cfg["storage_root"] = str(Path.home() / "Pictures" / "Photobank")
        changed = True
    if "db_path" not in cfg:
        cfg["db_path"] = str(APP_DIR / "photobank.db")
        changed = True
    if "port" not in cfg:
        cfg["port"] = 8000
        changed = True
    if changed:
        CONFIG_FILE.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    return cfg


def pick_port(preferred: int) -> int:
    for port in (preferred, 8420, 0):
        with socket.socket() as s:
            try:
                s.bind(("0.0.0.0", port))
                return s.getsockname()[1]
            except OSError:
                continue
    return preferred


def main() -> None:
    # windowed PyInstaller apps have no console: stdout/stderr are None, which
    # crashes uvicorn's logging setup (isatty on None). Give them a sink and
    # keep real logs in a file next to the config.
    if sys.stdout is None:
        sys.stdout = open(os.devnull, "w", encoding="utf-8")
    if sys.stderr is None:
        sys.stderr = open(os.devnull, "w", encoding="utf-8")

    import logging

    APP_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=str(APP_DIR / "photobank.log"),
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    cfg = load_or_create_config()
    port = pick_port(int(cfg["port"]))
    db = str(cfg["db_path"]).replace("\\", "/")

    # must be set before app.config is imported
    os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{db}"
    os.environ["DATABASE_URL_SYNC"] = f"sqlite:///{db}"
    os.environ["STORAGE_ROOT"] = str(cfg["storage_root"])
    os.environ["SECRET_KEY"] = cfg["secret_key"]
    os.environ["PORT"] = str(port)
    os.environ["HOST"] = "0.0.0.0"

    import uvicorn

    from app.main import app  # noqa: E402  (env is ready now)

    server = uvicorn.Server(
        uvicorn.Config(app, host="0.0.0.0", port=port, log_level="warning", log_config=None)
    )
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()

    url = f"http://127.0.0.1:{port}"
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"{url}/api/health", timeout=1):
                break
        except Exception:
            time.sleep(0.2)

    if os.environ.get("PHOTOBANK_NO_WINDOW") == "1":
        # headless mode (used by automated build verification)
        print(f"server ready on {url}", flush=True)
        try:
            while thread.is_alive():
                time.sleep(1)
        except KeyboardInterrupt:
            pass
    else:
        import webview

        webview.create_window(
            "Photobank", url, width=1280, height=850, min_size=(700, 500)
        )
        webview.start()

    server.should_exit = True
    thread.join(timeout=10)


if __name__ == "__main__":
    main()
