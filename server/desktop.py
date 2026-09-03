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

if sys.platform == "win32":
    APP_DIR = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "Photobank"
elif sys.platform == "darwin":
    APP_DIR = Path.home() / "Library" / "Application Support" / "Photobank"
else:
    APP_DIR = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share"))) / "Photobank"
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
    if "local_admin_token" not in cfg:
        cfg["local_admin_token"] = secrets.token_hex(24)
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


def _acquire_single_instance() -> bool:
    """Returns False if another Photobank is already running.

    Windows: named mutex. macOS/Linux: an exclusive flock on a lock file
    (released automatically when the process exits, even on a crash).
    """
    global _INSTANCE_LOCK
    if os.name == "nt":
        import ctypes

        kernel32 = ctypes.windll.kernel32
        handle = kernel32.CreateMutexW(None, False, "Local\\PhotobankDesktopSingleton")
        if kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
            kernel32.CloseHandle(handle)
            return False
        _INSTANCE_LOCK = handle
        return True
    import fcntl

    APP_DIR.mkdir(parents=True, exist_ok=True)
    lock = open(APP_DIR / "instance.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        lock.close()
        return False
    _INSTANCE_LOCK = lock  # keep the descriptor (and the lock) for the process lifetime
    return True


_INSTANCE_LOCK = None


def _raise_existing_instance() -> None:
    """Ask the running instance to show its window, then let this one exit."""
    try:
        cfg = json.loads(CONFIG_FILE.read_text(encoding="utf-8-sig")) if CONFIG_FILE.is_file() else {}
    except json.JSONDecodeError:
        cfg = {}
    for port in (int(cfg.get("port", 8000)), 8420):
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{port}/api/desktop/show", method="POST")
            with urllib.request.urlopen(req, timeout=2):
                return
        except Exception:
            continue


def main() -> None:
    if not _acquire_single_instance():
        _raise_existing_instance()
        return

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
    os.environ["LOCAL_ADMIN_TOKEN"] = cfg["local_admin_token"]

    import uvicorn
    from fastapi import HTTPException, Request

    from app.main import app  # noqa: E402  (env is ready now)

    ui = {"window": None}  # filled in once the window exists

    @app.post("/api/desktop/show", include_in_schema=False)
    async def desktop_show(request: Request):
        # only this machine may raise the window (a second launch calls this)
        if request.client is None or request.client.host not in ("127.0.0.1", "::1"):
            raise HTTPException(status_code=403)
        w = ui["window"]
        if w is not None:
            try:
                w.show()
                w.restore()
            except Exception:
                pass
        return {"ok": True}

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
            """Exposed to the web UI as window.pywebview.api (native dialogs, local auth)."""

            def pick_folder(self):
                result = window.create_file_dialog(webview.FOLDER_DIALOG)
                if result:
                    return result[0] if isinstance(result, (list, tuple)) else result
                return None

            def local_token(self):
                # only code running inside this window can obtain it
                return cfg["local_admin_token"]

            def set_storage_root(self, path):
                """First-run setup: move the photo folder. Applies live and persists."""
                from pathlib import Path as _P

                from app import storage
                from app.config import settings as _s

                p = _P(path)
                p.mkdir(parents=True, exist_ok=True)
                _s.storage_root = p
                storage.ensure_dirs()
                cfg["storage_root"] = str(p)
                CONFIG_FILE.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
                return str(p)

        window = webview.create_window(
            "Photobank", url, width=1280, height=850, min_size=(700, 500),
            js_api=DesktopApi(),
        )
        ui["window"] = window
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

    # the real mark (assets/icon, bundled by the build scripts); a drawn stand-in
    # keeps the tray working from a source checkout that hasn't run make-icons
    bundle = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
    candidates = (
        bundle / "assets" / "photobank-256.png",
        Path(__file__).resolve().parents[1] / "assets" / "icon" / "photobank-256.png",
    )
    icon_img = None
    for p in candidates:
        if p.is_file():
            icon_img = Image.open(p).convert("RGBA")
            break
    if icon_img is None:
        icon_img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        d = ImageDraw.Draw(icon_img)
        d.rounded_rectangle((0, 0, 63, 63), radius=8, fill=(255, 255, 255, 255))
        d.rectangle((18, 14, 26, 50), fill=(16, 20, 24, 255))
        d.rectangle((40, 42, 48, 50), fill=(255, 74, 28, 255))

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
