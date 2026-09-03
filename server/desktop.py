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

        class DesktopApi:
            """Exposed to the web UI as window.pywebview.api (native dialogs)."""

            def pick_folder(self):
                result = window.create_file_dialog(webview.FOLDER_DIALOG)
                if result:
                    return result[0] if isinstance(result, (list, tuple)) else result
                return None

        window = webview.create_window(
            "Photobank", url, width=1280, height=850, min_size=(700, 500),
            js_api=DesktopApi(),
        )
        tray = _make_tray(window, url)

        def on_closing():
            # closing the window hides it; the server keeps serving the LAN
            # (phones keep syncing). Quit is on the tray icon.
            if tray is not None:
                window.hide()
                return False
            return True

        window.events.closing += on_closing
        webview.start()  # returns only after window.destroy() (tray Quit)
        if tray is not None:
            tray.stop()

    server.should_exit = True
    thread.join(timeout=10)


def _make_tray(window, url: str):
    """System tray icon: Open / Quit. Returns None if pystray is unavailable."""
    try:
        import webbrowser

        import pystray
        from PIL import Image, ImageDraw
    except ImportError:
        return None

    icon_img = Image.new("RGBA", (64, 64), (16, 20, 24, 255))
    d = ImageDraw.Draw(icon_img)
    d.rounded_rectangle((8, 18, 56, 50), radius=8, fill=(74, 158, 255, 255))
    d.ellipse((24, 26, 40, 42), fill=(16, 20, 24, 255))

    def open_window(*_):
        window.show()
        window.restore()

    def open_browser(*_):
        webbrowser.open(url)

    def quit_app(icon, *_):
        icon.visible = False
        window.destroy()

    menu = pystray.Menu(
        pystray.MenuItem("Open Photobank", open_window, default=True),
        pystray.MenuItem("Open in browser", open_browser),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit (stops the server)", quit_app),
    )
    tray = pystray.Icon("Photobank", icon_img, "Photobank - server running", menu)
    tray.run_detached()
    return tray


if __name__ == "__main__":
    main()
