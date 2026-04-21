import sys
import os
import flet as ft
import json
import threading
import time
from typing import Optional

from .config import settings, logger, get_local_ip
from .parser import parse_library


def _agent_icon_path() -> str:
    """Absolute path to rimeo1024.png — works in dev and PyInstaller bundles."""
    import sys as _sys
    if getattr(_sys, "frozen", False) and hasattr(_sys, "_MEIPASS"):
        from pathlib import Path as _P
        return str(_P(_sys._MEIPASS) / "rimeo1024.png")
    from pathlib import Path as _P
    return str(_P(__file__).parent / "rimeo1024.png")

# ── Palette ───────────────────────────────────────────────────────────────────
C = {
    "bg":   "#0b1120",
    "surf": "#151c2c",
    "acc":  "#3b82f6",
    "text": "#f1f3f4",
    "brd":  "#1e293b",
    "dim":  "#64748b",
}

# ── Global state ──────────────────────────────────────────────────────────────
_instance: Optional['RimeoUI'] = None
_flet_running = False          # True while ft.app() is active
_reopen_event = threading.Event()   # set by status bar "Open" when Flet is down
_statusbar_created = False     # prevent double-creation on Flet restart

# ── macOS: NSObject delegate (module-level — ObjC class can only be defined once)
_macos_delegate = None

def _build_macos_delegate():
    global _macos_delegate
    if _macos_delegate is not None:
        return _macos_delegate
    try:
        import AppKit

        class _RimeoDelegate(AppKit.NSObject):
            def openWindow_(self, sender):
                if _flet_running and _instance and _instance.page:
                    # Flet is running — just show/focus the window
                    try:
                        _instance.page.window.visible = True
                        _instance.page.update()
                        AppKit.NSApp.activateIgnoringOtherApps_(True)
                        return
                    except Exception:
                        pass
                # Flet window is gone — signal the outer loop to restart it
                _reopen_event.set()

            def quitApp_(self, sender):
                sys.exit(0)

        _macos_delegate = _RimeoDelegate.new()
    except Exception as e:
        logger.warning("Could not build macOS delegate: %s", e)
    return _macos_delegate


# ── UI helpers ────────────────────────────────────────────────────────────────

def _section_label(text: str) -> ft.Text:
    """Uppercase dimmed section header — matches rimeo web-app style."""
    return ft.Text(
        text,
        size=10, weight=ft.FontWeight.W_800,
        color=C["dim"],
    )


def _step_row(n: str, text: str) -> ft.Row:
    return ft.Row([
        ft.Container(
            ft.Text(n, size=11, weight=ft.FontWeight.BOLD, color="white"),
            bgcolor=C["acc"], border_radius=99,
            width=20, height=20,
            alignment=ft.alignment.center,
        ),
        ft.Text(text, color=C["dim"], size=12, expand=True),
    ], spacing=10, vertical_alignment=ft.CrossAxisAlignment.START)


def _btn(label: str, on_click, *, icon: str = None, bgcolor: str = None,
         color: str = "white", height: int = 42, border=None,
         visible: bool = True) -> ft.Container:
    """Button with guaranteed border_radius=16 — bypasses Material3 pill default."""
    items = []
    if icon:
        items.append(ft.Icon(icon, color=color, size=16))
    items.append(ft.Text(label, color=color, size=13, weight=ft.FontWeight.W_500))
    return ft.Container(
        content=ft.Row(items, spacing=8, tight=True),
        bgcolor=bgcolor,
        border_radius=16,
        border=border,
        height=height,
        on_click=on_click,
        ink=True,
        padding=ft.padding.symmetric(horizontal=20),
        alignment=ft.alignment.center,
        visible=visible,
    )


def _get_cache_size_gb() -> float:
    """Return total size of CACHE_DIR in gigabytes."""
    total = 0
    try:
        for f in settings.CACHE_DIR.iterdir():
            if f.is_file():
                total += f.stat().st_size
    except Exception:
        pass
    return total / (1024 ** 3)


class RimeoUI:
    def __init__(self, page: ft.Page):
        global _instance, _flet_running
        _instance = self
        _flet_running = True
        self.page = page
        self._setup_window()
        self._setup_system_tray()
        if not os.path.exists(settings.DB_PATH):
            self._show_onboarding()
        else:
            self.show_main_layout()
        # Check for updates a few seconds after startup (non-blocking)
        self.page.run_task(self._check_updates_after_delay)

    # ── Window ────────────────────────────────────────────────────────────────
    def _setup_window(self):
        p = self.page
        p.title = "Rimeo Agent"
        p.bgcolor = C["bg"]
        p.theme_mode = ft.ThemeMode.DARK
        p.padding = 0
        # Fixed initial size — don't reset if already visible (avoids jumping)
        if not getattr(RimeoUI, "_window_sized", False):
            p.window.width = 860
            p.window.height = 860
            p.window.center()
            RimeoUI._window_sized = True
        p.window.min_width = 760
        p.window.min_height = 760
        p.window.prevent_close = True
        p.window.on_event = self._on_window_event

    def _on_window_event(self, e):
        if e.data == "close":
            self.page.window.visible = False
            self.page.update()

    # ── System tray / status bar ──────────────────────────────────────────────
    def _setup_system_tray(self):
        if sys.platform == "darwin":
            # page.run_task() schedules the coroutine on Flet's own event loop
            # (main asyncio thread) — NSApp/NSStatusBar are safe there.
            self.page.run_task(self._async_setup_macos_statusbar)
        else:
            threading.Thread(target=self._setup_windows_tray, daemon=True).start()

    async def _async_setup_macos_statusbar(self):
        """
        Runs on the main asyncio thread (via page.run_task).
        Creates the status bar once, then keeps pumping NSRunLoop so
        menu callbacks fire while Flet is running.
        """
        import asyncio
        global _statusbar_created
        try:
            import AppKit

            if not _statusbar_created:
                _statusbar_created = True

                ns_app = AppKit.NSApplication.sharedApplication()
                # Accessory = status-bar only, no separate Dock entry for the
                # Python process (the Flet subprocess owns the Dock icon).
                ns_app.setActivationPolicy_(
                    AppKit.NSApplicationActivationPolicyAccessory
                )

                delegate = _build_macos_delegate()
                if delegate is None:
                    logger.error("macOS delegate is None — status bar not created")
                    return

                sb = AppKit.NSStatusBar.systemStatusBar()
                # Keep reference at class level so it survives Flet restarts
                RimeoUI._status_item = sb.statusItemWithLength_(
                    AppKit.NSVariableStatusItemLength
                )
                btn = RimeoUI._status_item.button()
                btn.setToolTip_("Rimeo Agent")

                # Use Rimeo PNG as status-bar icon (template image scales to menu-bar size)
                try:
                    ns_img = AppKit.NSImage.alloc().initWithContentsOfFile_(
                        _agent_icon_path()
                    )
                    if ns_img:
                        ns_img.setSize_(AppKit.NSMakeSize(18, 18))
                        ns_img.setTemplate_(True)   # auto dark/light adaptation
                        btn.setImage_(ns_img)
                    else:
                        btn.setTitle_("R")
                except Exception:
                    btn.setTitle_("R")


                menu = AppKit.NSMenu.new()
                open_item = AppKit.NSMenuItem.alloc() \
                    .initWithTitle_action_keyEquivalent_("Open Rimeo Agent", "openWindow:", "")
                open_item.setTarget_(delegate)
                menu.addItem_(open_item)
                menu.addItem_(AppKit.NSMenuItem.separatorItem())
                quit_item = AppKit.NSMenuItem.alloc() \
                    .initWithTitle_action_keyEquivalent_("Quit", "quitApp:", "")
                quit_item.setTarget_(delegate)
                menu.addItem_(quit_item)
                RimeoUI._status_item.setMenu_(menu)
                logger.info("macOS status bar icon created")

            # Pump NSRunLoop every 50 ms while Flet is running
            while True:
                AppKit.NSRunLoop.currentRunLoop().runMode_beforeDate_(
                    AppKit.NSDefaultRunLoopMode,
                    AppKit.NSDate.distantPast(),
                )
                await asyncio.sleep(0.05)

        except Exception as e:
            logger.error("macOS status bar setup failed: %s", e)

    def _setup_windows_tray(self):
        """Windows: pystray in a background thread (Win32 has no main-thread req)."""
        try:
            import pystray
            from RimeoAgent.tray import _make_icon

            def on_open(_icon=None, _item=None):
                if _instance and _instance.page:
                    _instance.page.window.visible = True
                    _instance.page.update()

            def on_quit(_icon=None, _item=None):
                _tray.stop()
                sys.exit(0)

            menu = pystray.Menu(
                pystray.MenuItem("Open Rimeo Agent", on_open, default=True),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("Quit", on_quit),
            )
            _tray = pystray.Icon("Rimeo", _make_icon(), "Rimeo Agent", menu)
            _tray.run()  # blocks this background thread
        except Exception as e:
            logger.error("Windows tray setup failed: %s", e)

    # ── Onboarding ────────────────────────────────────────────────────────────
    def _show_onboarding(self):
        """Shown when Rekordbox master.db is not found — offers manual selection."""
        self.page.controls.clear()

        if sys.platform == "darwin":
            db_hint = "~/Library/Pioneer/rekordbox/master.db"
        else:
            db_hint = r"%APPDATA%\Pioneer\rekordbox6\master.db"

        if sys.platform != "darwin":
            self._ob_db_picker  = ft.FilePicker(on_result=self._ob_db_selected)
            self._ob_xml_picker = ft.FilePicker(on_result=self._ob_xml_selected)
            self.page.overlay += [self._ob_db_picker, self._ob_xml_picker]

        self._onboarding_status = ft.Text("", color="#f87171", size=13)

        def _retry(_):
            if os.path.exists(settings.DB_PATH):
                self.page.controls.clear()
                self.show_main_layout()
            else:
                self._onboarding_status.value = f"Not found: {settings.DB_PATH}"
                self.page.update()

        self.page.add(
            ft.Container(
                expand=True, bgcolor=C["bg"],
                padding=ft.padding.symmetric(horizontal=80, vertical=60),
                content=ft.Column([
                    ft.Text("Welcome to Rimeo Agent",
                            size=30, weight=ft.FontWeight.BOLD, color=C["text"]),
                    ft.Text("Rekordbox library not found at the default location.",
                            size=14, color=C["dim"]),
                    ft.Container(height=24),

                    ft.Container(
                        bgcolor=C["surf"], border=ft.border.all(1, C["brd"]),
                        border_radius=16, padding=24,
                        content=ft.Column([
                            ft.Row([
                                ft.Icon("warning_amber_outlined", color="#f59e0b", size=20),
                                ft.Text("master.db not found", color="#f59e0b",
                                        size=14, weight=ft.FontWeight.W_600),
                            ], spacing=10),
                            ft.Text(f"Expected: {db_hint}", color=C["dim"], size=12),
                            ft.Container(
                                bgcolor="#0d2137", border_radius=12,
                                padding=ft.padding.symmetric(horizontal=14, vertical=10),
                                content=ft.Row([
                                    ft.Icon("info_outline", color=C["acc"], size=16),
                                    ft.Text(
                                        "Make sure Rekordbox 6 or 7 is installed and launched at least once.",
                                        color=C["dim"], size=12, expand=True,
                                    ),
                                ], spacing=10),
                            ),
                            _btn("Retry auto-detect", _retry,
                                 icon="refresh", bgcolor=C["surf"], color=C["text"],
                                 height=40, border=ft.border.all(1, C["brd"])),
                        ], spacing=12),
                    ),

                    ft.Container(height=16),
                    ft.Text("Or select the file manually:",
                            size=14, weight=ft.FontWeight.W_600, color=C["text"]),
                    ft.Container(height=4),

                    ft.Row([
                        ft.Container(
                            expand=True,
                            bgcolor=C["surf"], border=ft.border.all(1, C["brd"]),
                            border_radius=16, padding=20,
                            content=ft.Column([
                                ft.Row([
                                    ft.Icon("storage", color=C["acc"], size=20),
                                    ft.Text("Rekordbox 6/7", color=C["text"],
                                            size=13, weight=ft.FontWeight.W_600),
                                ], spacing=8),
                                ft.Text("master.db  (recommended)", color=C["dim"], size=12),
                                ft.Container(height=4),
                                _btn("Select master.db", self._ob_browse_db,
                                     icon="folder_open_outlined", bgcolor=C["acc"], height=40),
                            ], spacing=8),
                        ),
                        ft.Container(
                            expand=True,
                            bgcolor=C["surf"], border=ft.border.all(1, C["brd"]),
                            border_radius=16, padding=20,
                            content=ft.Column([
                                ft.Row([
                                    ft.Icon("insert_drive_file_outlined",
                                            color=C["dim"], size=20),
                                    ft.Text("Rekordbox XML", color=C["text"],
                                            size=13, weight=ft.FontWeight.W_600),
                                ], spacing=8),
                                ft.Text("rekordbox.xml  (fallback)", color=C["dim"], size=12),
                                ft.Container(height=4),
                                _btn("Select .xml", self._ob_browse_xml,
                                     icon="folder_open_outlined",
                                     bgcolor=C["surf"], color=C["text"], height=40,
                                     border=ft.border.all(1, C["brd"])),
                            ], spacing=8),
                        ),
                    ], spacing=16),

                    self._onboarding_status,
                ], spacing=8, scroll=ft.ScrollMode.AUTO),
            )
        )
        self.page.update()

    # -- Onboarding file pickers -----------------------------------------------
    def _ob_browse_db(self, _):
        if sys.platform == "darwin":
            threading.Thread(target=self._ob_browse_db_macos, daemon=True).start()
        else:
            self._ob_db_picker.pick_files(
                allowed_extensions=["db"], dialog_title="Select master.db")

    def _ob_browse_xml(self, _):
        if sys.platform == "darwin":
            threading.Thread(target=self._ob_browse_xml_macos, daemon=True).start()
        else:
            self._ob_xml_picker.pick_files(
                allowed_extensions=["xml"], dialog_title="Select rekordbox.xml")

    def _ob_browse_db_macos(self):
        import subprocess
        r = subprocess.run(
            ["osascript", "-e",
             'POSIX path of (choose file with prompt "Select master.db")'],
            capture_output=True, text=True, timeout=120,
        )
        if r.returncode == 0 and r.stdout.strip():
            self._ob_finish_db(r.stdout.strip())

    def _ob_browse_xml_macos(self):
        import subprocess
        r = subprocess.run(
            ["osascript", "-e",
             'POSIX path of (choose file with prompt "Select rekordbox.xml" of type {"xml"})'],
            capture_output=True, text=True, timeout=120,
        )
        if r.returncode == 0 and r.stdout.strip():
            self._ob_finish_xml(r.stdout.strip())

    def _ob_db_selected(self, e: ft.FilePickerResultEvent):
        if e.files:
            self._ob_finish_db(e.files[0].path)

    def _ob_xml_selected(self, e: ft.FilePickerResultEvent):
        if e.files:
            self._ob_finish_xml(e.files[0].path)

    def _ob_finish_db(self, path: str):
        settings.DB_PATH = path
        env_path = settings.BASE_DIR / ".env"
        lines = env_path.read_text(encoding="utf-8").splitlines() if env_path.exists() else []
        lines = [l for l in lines if not l.startswith("RIMEO_DB_PATH=")]
        lines.append(f"RIMEO_DB_PATH={path}")
        env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.page.controls.clear()
        self.show_main_layout()

    def _ob_finish_xml(self, path: str):
        settings.XML_PATH = path
        env_path = settings.BASE_DIR / ".env"
        lines = env_path.read_text(encoding="utf-8").splitlines() if env_path.exists() else []
        lines = [l for l in lines if not l.startswith("RIMEO_XML_PATH=")]
        lines.append(f"RIMEO_XML_PATH={path}")
        env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.page.controls.clear()
        self.show_main_layout()

    # ── Auto-update ───────────────────────────────────────────────────────────
    async def _check_updates_after_delay(self):
        import asyncio
        await asyncio.sleep(4)
        from .updater import check_update_async
        check_update_async(self._on_update_found)

    def _on_update_found(self, info):
        if info is None:
            return
        logger.info("Showing update banner for %s", info.version)

        def _do_update(_):
            self._start_update_download(info)

        def _dismiss(_):
            self.page.banner.open = False
            self.page.update()

        self.page.banner = ft.Banner(
            bgcolor="#0d2137",
            leading=ft.Icon("system_update_alt", color=C["acc"], size=22),
            content=ft.Text(
                f"Update available: {info.version}  —  "
                + (info.notes.split("\n")[0] if info.notes else ""),
                color=C["text"],
                size=13,
            ),
            actions=[
                ft.TextButton(
                    "Update & Restart",
                    on_click=_do_update,
                    style=ft.ButtonStyle(color=C["acc"]),
                ),
                ft.TextButton(
                    "Later",
                    on_click=_dismiss,
                    style=ft.ButtonStyle(color=C["dim"]),
                ),
            ],
        )
        self.page.banner.open = True
        self.page.update()

    def _start_update_download(self, info):
        from .updater import download_and_apply

        self._upd_progress = ft.ProgressBar(
            value=0, color=C["acc"], bgcolor="white10", width=360,
        )
        self._upd_status = ft.Text("Starting download…", color=C["dim"], size=13)

        self.page.banner = ft.Banner(
            bgcolor="#0b1120",
            leading=ft.Icon("downloading", color=C["acc"], size=22),
            content=ft.Column(
                [self._upd_status, self._upd_progress], spacing=8
            ),
            actions=[],
        )
        self.page.banner.open = True
        self.page.update()

        def _task():
            def _progress(fraction: float):
                self._upd_progress.value = fraction
                self._upd_status.value = f"Downloading… {int(fraction * 100)}%"
                self.page.update()

            try:
                download_and_apply(info, progress_cb=_progress)
                # download_and_apply calls sys.exit(0) on success — never reached
            except Exception as e:
                self._upd_status.value = f"Update failed: {e}"
                self._upd_status.color = "#f87171"
                self.page.update()

        threading.Thread(target=_task, daemon=True).start()

    # ── Main layout ───────────────────────────────────────────────────────────
    def show_main_layout(self):
        self.page.controls.clear()

        self.rail = ft.NavigationRail(
            selected_index=0,
            label_type=ft.NavigationRailLabelType.ALL,
            min_width=90,
            bgcolor=C["surf"],
            destinations=[
                ft.NavigationRailDestination(
                    icon="folder_outlined", selected_icon="folder", label="Library"),
                ft.NavigationRailDestination(
                    icon="analytics_outlined", selected_icon="analytics", label="Analysis"),
                ft.NavigationRailDestination(
                    icon="qr_code", label="Pairing"),
                ft.NavigationRailDestination(
                    icon="cloud_outlined", selected_icon="cloud", label="Account"),
                ft.NavigationRailDestination(
                    icon="terminal_outlined", selected_icon="terminal", label="Logs"),
            ],
            on_change=self._on_tab_change,
        )
        self.content = ft.Container(
            expand=True,
            padding=ft.padding.only(left=36, right=36, top=32, bottom=24),
            alignment=ft.alignment.top_left,
        )

        self.page.add(ft.Row([
            self.rail,
            ft.VerticalDivider(width=1, color=C["brd"]),
            self.content,
        ], expand=True, spacing=0))
        self._show_library_tab()

    def _on_tab_change(self, e):
        idx = e.control.selected_index
        if idx == 0:   self._show_library_tab()
        elif idx == 1: self._show_analysis_tab()
        elif idx == 2: self._show_pairing_tab()
        elif idx == 3: self._show_cloud_tab()
        elif idx == 4: self._show_logs_tab()

    # ── Tab: Library ──────────────────────────────────────────────────────────
    def _show_library_tab(self):
        db_path = settings.DB_PATH
        db_exists = os.path.exists(db_path)

        db_age_text = ""
        db_age_color = C["dim"]
        if db_exists:
            try:
                import time as _time
                from datetime import datetime as _dt
                mtime = os.path.getmtime(db_path)
                age_sec = _time.time() - mtime
                updated_str = _dt.fromtimestamp(mtime).strftime("%d %b %Y, %H:%M")
                if age_sec < 3600:
                    age_label = f"{int(age_sec // 60)} min ago"
                elif age_sec < 86400:
                    age_label = f"{int(age_sec // 3600)} h ago"
                else:
                    age_label = f"{int(age_sec // 86400)} days ago"
                db_age_text = f"Last modified: {updated_str}  ·  {age_label}"
            except Exception:
                pass

        status_icon = "check_circle_outline" if db_exists else "error_outline"
        status_color = "#4ade80" if db_exists else "#f87171"
        status_text = "Connected" if db_exists else "Not found"

        self._lib_status = ft.Text("", color=C["dim"], size=13)

        self.content.content = ft.Column([
            ft.Text("Library", size=24, weight=ft.FontWeight.BOLD, color=C["text"]),
            ft.Text("Reads your Rekordbox library automatically and serves tracks to rimeo.app.",
                    color=C["dim"], size=13),
            ft.Container(height=4),
            _section_label("REKORDBOX DATABASE"),
            ft.Container(
                bgcolor=C["surf"], border=ft.border.all(1, C["brd"]),
                border_radius=16, padding=20,
                content=ft.Column([
                    ft.Row([
                        ft.Icon(status_icon, color=status_color, size=18),
                        ft.Text(status_text, color=status_color,
                                size=13, weight=ft.FontWeight.W_600),
                    ], spacing=8),
                    ft.Text(
                        db_path,
                        color=C["dim"], size=11,
                        no_wrap=True, overflow=ft.TextOverflow.ELLIPSIS,
                    ),
                    ft.Text(db_age_text, color=db_age_color, size=12) if db_age_text else ft.Container(height=0),
                    self._lib_status,
                    ft.Row([
                        _btn("Reload Library", self._reload_library,
                             icon="refresh", bgcolor=C["acc"]),
                    ], spacing=16),
                ], spacing=10),
            ),
        ], spacing=12, scroll=ft.ScrollMode.AUTO, expand=True)
        self.page.update()

    def _reload_library(self, _):
        self._lib_status.value = "Loading…"
        self.page.update()
        def task():
            result = parse_library()
            tracks = len(result.get("tracks", []))
            playlists = len(result.get("playlists", []))
            source = result.get("source", "db")
            self._lib_status.value = f"✓ {tracks} tracks, {playlists} playlists  ({source})"
            self.page.update()
        threading.Thread(target=task, daemon=True).start()

    # ── Tab: Analysis ─────────────────────────────────────────────────────────
    def _show_analysis_tab(self):
        self._analysis_status = ft.Text("Ready", color=C["dim"], size=13)
        self._analysis_pb = ft.ProgressBar(
            value=0, color=C["acc"], bgcolor="white10", width=400)
        self._analysis_table = ft.Column([], spacing=0, scroll=ft.ScrollMode.AUTO)
        self._is_analyzing = False
        self._stop_requested = False

        self._start_btn = _btn("Start Analysis", self._run_analysis,
                               icon="play_circle_outlined", bgcolor=C["acc"])
        self._stop_btn = _btn("Stop", self._stop_analysis,
                              icon="stop_circle_outlined", bgcolor="#ef4444", visible=False)

        self.content.content = ft.Column([
            ft.Text("Analysis", size=24, weight=ft.FontWeight.BOLD, color=C["text"]),
            ft.Text("Extracts CLAP audio embeddings from the best 30s segment of each track.",
                    color=C["dim"], size=13),
            ft.Container(height=4),
            _section_label("ANALYSIS ENGINE"),
            ft.Container(
                bgcolor=C["surf"], border=ft.border.all(1, C["brd"]),
                border_radius=16, padding=20,
                content=ft.Column([
                    self._analysis_status,
                    self._analysis_pb,
                    ft.Row([self._start_btn, self._stop_btn], spacing=12),
                ], spacing=14),
            ),
            _section_label("RESULTS"),
            self._analysis_table,
        ], spacing=12, scroll=ft.ScrollMode.AUTO, expand=True)
        self.page.update()

    def _stop_analysis(self, _):
        self._stop_requested = True
        self._stop_btn.visible = False
        self._analysis_status.value = "Stopping…"
        self.page.update()

    def _run_analysis(self, _):
        if self._is_analyzing:
            return
        self._is_analyzing = True
        self._stop_requested = False
        self._start_btn.visible = False
        self._stop_btn.visible = True
        self._analysis_table.controls.clear()
        self.page.update()

        def task():
            from .analyzer import analyze_track
            from .api_server import _load_analysis, _save_analysis

            data = parse_library()
            tracks = data.get("tracks", [])
            # Deduplicate by id
            seen = {}
            for t in tracks:
                seen[t["id"]] = t
            unique = list(seen.values())
            total = len(unique)

            store = _load_analysis()
            done = 0
            errors = 0
            logger.info("Analysis started: %d tracks total", total)

            for i, track in enumerate(unique):
                if self._stop_requested:
                    break
                label = f"{track.get('artist', '?')} — {track.get('title', '?')}"
                self._analysis_pb.value = (i + 1) / max(total, 1)
                self._analysis_status.value = (
                    f"Analyzing {i + 1} / {total}: {label}")
                self.page.update()

                if track["id"] in store and "clap" in store[track["id"]]:
                    feat = store[track["id"]]
                    logger.info("[%d/%d] SKIP (cached+clap): %s", i + 1, total, label)
                    self._analysis_table.controls.append(
                        _result_row(track, feat["segment_start"], feat["segment_end"],
                                    has_clap="clap" in feat))
                    done += 1
                    self.page.update()
                    continue

                logger.info("[%d/%d] Analyzing: %s", i + 1, total, label)
                try:
                    result = analyze_track(track)
                    if result:
                        store[track["id"]] = result
                        _save_analysis(store)
                        clap_ok = "clap" in result
                        logger.info(
                            "[%d/%d] OK  CLAP=%s  seg=%ds-%ds  %s",
                            i + 1, total,
                            "✓" if clap_ok else "✗",
                            result.get("segment_start", 0), result.get("segment_end", 0),
                            label,
                        )
                        self._analysis_table.controls.append(
                            _result_row(track, result["segment_start"], result["segment_end"],
                                        has_clap="clap" in result))
                        done += 1
                    else:
                        logger.warning("[%d/%d] FAIL (no result): %s", i + 1, total, label)
                        errors += 1
                except Exception as ex:
                    logger.error("[%d/%d] ERROR: %s — %s", i + 1, total, label, ex)
                    errors += 1
                self.page.update()

            _save_analysis(store)
            if self._stop_requested:
                self._analysis_status.value = f"Stopped — {done} tracks analyzed, {errors} errors"
            else:
                self._analysis_status.value = f"Done — {done} tracks analyzed, {errors} errors"
            self._analysis_pb.value = 1.0
            self._is_analyzing = False
            self._start_btn.visible = True
            self._stop_btn.visible = False
            self.page.update()

        threading.Thread(target=task, daemon=True).start()

    # ── Tab: Pairing ──────────────────────────────────────────────────────────
    def _show_pairing_tab(self):
        from .api_server import _load_data
        data = _load_data()
        is_linked   = bool(data.get("cloud_url"))
        cloud_email = data.get("cloud_user_id", "") or data.get("cloud_url", "")

        # Browser connection status badge
        if is_linked:
            browser_status = ft.Container(
                bgcolor="#052e16",
                border=ft.border.all(1, "#166534"),
                border_radius=16,
                padding=ft.padding.symmetric(horizontal=12, vertical=6),
                content=ft.Row([
                    ft.Icon("check_circle_outline", color="#4ade80", size=14),
                    ft.Text(f"Connected as {cloud_email}", color="#4ade80", size=12),
                ], spacing=6, tight=True),
            )
        else:
            browser_status = ft.Container(
                bgcolor="#1c1917",
                border=ft.border.all(1, C["brd"]),
                border_radius=16,
                padding=ft.padding.symmetric(horizontal=12, vertical=6),
                content=ft.Row([
                    ft.Icon("link_off", color=C["dim"], size=14),
                    ft.Text("Not connected — link your agent in the Account tab",
                            color=C["dim"], size=12),
                ], spacing=6, tight=True),
            )

        # Cache section helpers
        cache_gb = _get_cache_size_gb()
        max_cache_gb = float(data.get("max_cache_gb", 3.0))
        cache_bar_value = min(cache_gb / max_cache_gb, 1.0) if max_cache_gb > 0 else 0
        cache_bar_color = "#ef4444" if cache_bar_value > 0.9 else (
            "#f59e0b" if cache_bar_value > 0.7 else C["acc"]
        )

        self._cache_status = ft.Text("", color=C["dim"], size=12)
        self._cache_max_field = ft.TextField(
            value=str(int(max_cache_gb)),
            hint_text="3",
            width=72, height=40,
            text_align=ft.TextAlign.CENTER,
            bgcolor=C["surf"], border_color=C["brd"], color=C["text"],
            focused_border_color=C["acc"],
            input_filter=ft.NumbersOnlyInputFilter(),
            border_radius=16,
        )

        def _clear_cache(_):
            self._cache_status.value = "Clearing…"
            self.page.update()
            def _task():
                import shutil as _sh
                try:
                    for f in settings.CACHE_DIR.iterdir():
                        try: f.unlink()
                        except Exception: pass
                    self._cache_status.value = "✓ Cache cleared"
                    self._cache_status.color = "#4ade80"
                except Exception as ex:
                    self._cache_status.value = f"Error: {ex}"
                    self._cache_status.color = "#f87171"
                self.page.update()
            threading.Thread(target=_task, daemon=True).start()

        def _save_max_cache(_):
            from .api_server import _load_data, _save_data as _sd
            try:
                val = max(1, int(self._cache_max_field.value or "3"))
                d = _load_data(); d["max_cache_gb"] = val; _sd(d)
                self._cache_status.value = f"✓ Max cache set to {val} GB"
                self._cache_status.color = "#4ade80"
            except Exception as ex:
                self._cache_status.value = f"Error: {ex}"
                self._cache_status.color = "#f87171"
            self.page.update()

        def _open_rimeo(_):
            import webbrowser
            webbrowser.open(settings.RIMEO_APP_URL)

        self.content.content = ft.Column([
            ft.Text("Pairing", size=24, weight=ft.FontWeight.BOLD, color=C["text"]),
            ft.Container(height=4),

            # ── Web browser ──────────────────────────────────────────────────
            _section_label("WEB BROWSER"),
            ft.Container(
                bgcolor=C["surf"], border=ft.border.all(1, C["brd"]),
                border_radius=16, padding=20,
                content=ft.Column([
                    ft.Text(
                        "To listen to your music from any web browser:",
                        color=C["text"], size=13,
                    ),
                    ft.Container(
                        bgcolor=C["bg"], border_radius=16,
                        padding=ft.padding.symmetric(horizontal=14, vertical=10),
                        content=ft.Column([
                            _step_row("1", "Open rimeo.app and log in to your account."),
                            _step_row("2", "Go to Account → click «Generate Link Token»."),
                            _step_row("3", "Enter the token in the Agent's Account tab and press Link."),
                        ], spacing=8),
                    ),
                    browser_status,
                ], spacing=10),
            ),

            ft.Container(height=4),

            # ── iOS app ──────────────────────────────────────────────────────
            _section_label("iOS APP"),
            ft.Container(
                bgcolor=C["surf"], border=ft.border.all(1, C["brd"]),
                border_radius=16, padding=20,
                content=ft.Column([
                    ft.Text(
                        "To use the Rimeo iOS app on your iPhone:",
                        color=C["text"], size=13,
                    ),
                    ft.Container(
                        bgcolor=C["bg"], border_radius=16,
                        padding=ft.padding.symmetric(horizontal=14, vertical=10),
                        content=ft.Column([
                            _step_row("1", "Open the Rimeo iOS app on your iPhone."),
                            _step_row("2", "Tap «Pair» and scan the QR code shown on rimeo.app."),
                            _step_row("3", "Log in to your account — your library will sync automatically."),
                        ], spacing=8),
                    ),
                    _btn("Open rimeo.app", _open_rimeo, icon="open_in_new",
                         bgcolor=C["surf"], color=C["acc"], height=40,
                         border=ft.border.all(1, C["brd"])),
                ], spacing=10),
            ),

            ft.Container(height=4),

            # ── Cache ────────────────────────────────────────────────────────
            _section_label("CACHE"),
            ft.Container(
                bgcolor=C["surf"], border=ft.border.all(1, C["brd"]),
                border_radius=16, padding=20,
                content=ft.Column([
                    ft.Text(
                        "The cache stores converted audio (WAV), waveform data and artwork "
                        "so tracks load faster on repeat plays.",
                        color=C["dim"], size=12,
                    ),
                    ft.Container(height=4),
                    ft.Row([
                        ft.Column([
                            ft.Text(
                                f"{cache_gb:.2f} GB used",
                                size=22, weight=ft.FontWeight.BOLD, color=C["text"],
                            ),
                            ft.ProgressBar(
                                value=cache_bar_value,
                                color=cache_bar_color,
                                bgcolor="white10",
                                width=280, height=6,
                            ),
                            ft.Text(f"of {int(max_cache_gb)} GB max", color=C["dim"], size=12),
                        ], spacing=6),
                        ft.Container(expand=True),
                        ft.Column([
                            ft.Text("Max cache (GB)", color=C["dim"], size=11),
                            ft.Row([
                                self._cache_max_field,
                                _btn("Save", _save_max_cache,
                                     bgcolor=C["acc"], height=40),
                            ], spacing=8),
                        ], spacing=4, horizontal_alignment=ft.CrossAxisAlignment.END),
                    ], vertical_alignment=ft.CrossAxisAlignment.CENTER),
                    ft.Row([
                        _btn("Clear Cache", _clear_cache, icon="delete_sweep_outlined",
                             bgcolor=C["surf"], color="#f87171", height=40,
                             border=ft.border.all(1, "#7f1d1d")),
                        self._cache_status,
                    ], spacing=12),
                ], spacing=12),
            ),
        ], spacing=12, scroll=ft.ScrollMode.AUTO, expand=True)
        self.page.update()


    # ── Tab: Cloud Account ────────────────────────────────────────────────────
    def _show_cloud_tab(self):
        from .api_server import _load_data
        data = _load_data()
        is_linked   = bool(data.get("cloud_url"))
        cloud_url   = data.get("cloud_url", "")
        cloud_email = data.get("cloud_user_id", "")

        self._cloud_token_field = ft.TextField(
            label="Link Token", hint_text="8-character code from web dashboard",
            bgcolor=C["surf"], border_color=C["brd"], color=C["text"],
            focused_border_color=C["acc"], expand=True,
            border_radius=16,
        )
        self._cloud_status = ft.Text("", color=C["dim"], size=13)

        if is_linked:
            status_badge = ft.Container(
                bgcolor="#14532d", border_radius=16,
                padding=ft.padding.symmetric(horizontal=12, vertical=6),
                content=ft.Row([
                    ft.Icon("check_circle", color="#4ade80", size=16),
                    ft.Text(f"Linked as {cloud_email or cloud_url}",
                            color="#4ade80", size=13),
                ], spacing=8),
            )
        else:
            status_badge = ft.Container(
                bgcolor="#3b1717", border_radius=16,
                padding=ft.padding.symmetric(horizontal=12, vertical=6),
                content=ft.Row([
                    ft.Icon("link_off", color="#f87171", size=16),
                    ft.Text("Not linked to a cloud account", color="#f87171", size=13),
                ], spacing=8),
            )

        # ── Delete connection button (only when linked) ──────────────────
        def _do_unlink(_):
            import urllib.request as _u, json as _j
            def _task():
                try:
                    req = _u.Request(
                        f"http://127.0.0.1:{settings.PORT}/api/unlink_account",
                        data=b"{}",
                        headers={"Content-Type": "application/json"},
                        method="POST",
                    )
                    with _u.urlopen(req, timeout=5):
                        pass
                except Exception:
                    pass
                self._show_cloud_tab()
            import threading as _th
            _th.Thread(target=_task, daemon=True).start()

        unlink_row = ft.Row([
            _btn("Delete Connection", _do_unlink, icon="link_off",
                 bgcolor="#3b1717", color="#f87171", height=40),
        ]) if is_linked else ft.Container(height=0)

        self.content.content = ft.Column([
            ft.Text("Account", size=24, weight=ft.FontWeight.BOLD, color=C["text"]),
            ft.Text(
                "Link this agent to your Rimeo account so the web app knows it's online.",
                color=C["dim"], size=13,
            ),
            ft.Container(height=4),
            _section_label("CONNECTION STATUS"),
            status_badge,
            unlink_row,
            ft.Container(height=8),
            _section_label("LINK TO ACCOUNT"),
            ft.Container(
                bgcolor=C["surf"], border=ft.border.all(1, C["brd"]),
                border_radius=16, padding=20,
                content=ft.Column([
                    ft.Container(
                        bgcolor=C["bg"], border_radius=16,
                        padding=ft.padding.symmetric(horizontal=14, vertical=10),
                        content=ft.Column([
                            _step_row("1", "Open rimeo.app → Account → click «Generate Link Token»."),
                            _step_row("2", "Enter the 8-character code below and click Link."),
                        ], spacing=8),
                    ),
                    self._cloud_token_field,
                    ft.Row([
                        _btn("Link Agent", self._do_link_account,
                             icon="link", bgcolor=C["acc"]),
                        self._cloud_status,
                    ], spacing=16),
                ], spacing=14),
            ),
        ], spacing=12, scroll=ft.ScrollMode.AUTO, expand=True)
        self.page.update()

    # ── Tab: Logs ─────────────────────────────────────────────────────────────
    def _show_logs_tab(self):
        log_content = ""
        try:
            log_path = settings.LOG_FILE
            if log_path.exists():
                lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
                log_content = "\n".join(lines[-200:])
        except Exception as e:
            log_content = f"Could not read log file: {e}"

        log_text = ft.Text(
            log_content or "(no log entries yet)",
            font_family="monospace", size=11, color="#8b949e",
            selectable=True, no_wrap=False,
        )
        log_container = ft.Container(
            content=ft.Column([log_text], scroll=ft.ScrollMode.AUTO),
            bgcolor="#0d1117", border_radius=16,
            padding=16, expand=True,
            border=ft.border.all(1, C["brd"]),
        )

        self._bug_desc = ft.TextField(
            label="Describe the issue",
            hint_text="What happened? What were you doing?",
            multiline=True, min_lines=3, max_lines=6,
            bgcolor=C["surf"], border_color=C["brd"], color=C["text"],
            focused_border_color=C["acc"], expand=True,
            border_radius=16,
        )
        self._bug_status = ft.Text("", color=C["dim"], size=13)

        def _copy_logs(_):
            self.page.set_clipboard(log_content)
            self._bug_status.value = "✓ Copied to clipboard"
            self._bug_status.color = "#4ade80"
            self.page.update()

        def _submit_bug(_):
            desc = self._bug_desc.value.strip()
            if not desc:
                self._bug_status.value = "Please describe the issue."
                self._bug_status.color = "#f87171"
                self.page.update()
                return
            self._bug_status.value = "Sending…"
            self._bug_status.color = C["dim"]
            self.page.update()

            def _task():
                import urllib.request as _u, urllib.error, json as _j
                payload = _j.dumps({"description": desc}).encode()
                req = _u.Request(
                    f"http://127.0.0.1:{settings.PORT}/api/report_bug",
                    data=payload,
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                try:
                    with _u.urlopen(req, timeout=15):
                        pass
                    self._bug_status.value = "✓ Bug report sent!"
                    self._bug_status.color = "#4ade80"
                    self._bug_desc.value = ""
                except urllib.error.HTTPError as e:
                    msg = e.read().decode("utf-8", errors="replace")
                    self._bug_status.value = f"Error {e.code}: {msg[:80]}"
                    self._bug_status.color = "#f87171"
                except Exception as e:
                    self._bug_status.value = f"Error: {e}"
                    self._bug_status.color = "#f87171"
                self.page.update()

            threading.Thread(target=_task, daemon=True).start()

        self.content.content = ft.Column([
            ft.Text("Logs", size=24, weight=ft.FontWeight.BOLD, color=C["text"]),
            ft.Container(height=4),
            _section_label("REPORT A BUG"),
            ft.Container(
                bgcolor=C["surf"], border=ft.border.all(1, C["brd"]),
                border_radius=16, padding=20,
                content=ft.Column([
                    ft.Text(
                        "The last 200 log lines will be attached automatically.",
                        color=C["dim"], size=12,
                    ),
                    self._bug_desc,
                    ft.Row([
                        _btn("Send Report", _submit_bug,
                             icon="bug_report", bgcolor=C["acc"]),
                        self._bug_status,
                    ], spacing=16),
                ], spacing=12),
            ),
            ft.Row([
                _section_label("LOG OUTPUT"),
                ft.Container(expand=True),
                _btn("Copy", _copy_logs, icon="content_copy",
                     bgcolor=C["surf"], color=C["text"], height=34),
                _btn("Refresh", lambda _: self._show_logs_tab(), icon="refresh",
                     bgcolor=C["surf"], color=C["text"], height=34),
            ], vertical_alignment=ft.CrossAxisAlignment.CENTER, spacing=8),
            log_container,
        ], spacing=12, scroll=ft.ScrollMode.AUTO, expand=True)
        self.page.update()

    def _do_link_account(self, _):
        import urllib.request, urllib.error
        token     = self._cloud_token_field.value.strip()
        cloud_url = settings.RIMEO_APP_URL.rstrip("/")

        if not token:
            self._cloud_status.value = "Please enter the link token."
            self._cloud_status.color = "#f87171"
            self.page.update()
            return

        self._cloud_status.value = "Linking…"
        self._cloud_status.color = C["dim"]
        self.page.update()

        def task():
            import json as _json
            payload = _json.dumps({
                "token": token,
                "cloud_url": cloud_url,
            }).encode("utf-8")
            req = urllib.request.Request(
                f"http://127.0.0.1:{settings.PORT}/api/link_account",
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    _json.loads(resp.read())
                self._cloud_status.value = "✓ Linked successfully!"
                self._cloud_status.color = "#4ade80"
                self.page.update()
                # Refresh the whole tab to show new status
                self._show_cloud_tab()
            except urllib.error.HTTPError as e:
                msg = e.read().decode("utf-8", errors="replace")
                self._cloud_status.value = f"Error {e.code}: {msg[:80]}"
                self._cloud_status.color = "#f87171"
                self.page.update()
            except Exception as e:
                self._cloud_status.value = f"Error: {e}"
                self._cloud_status.color = "#f87171"
                self.page.update()

        threading.Thread(target=task, daemon=True).start()


# ── Result row ────────────────────────────────────────────────────────────────
def _result_row(track, seg_start, seg_end, energy=0, timbre=0, groove=0, happiness=0.0,
                pending=False, has_clap=False):
    dim = C["dim"]
    if pending:
        seg = ft.Text("pending", color=dim, size=11, italic=True)
        badge = ft.Text("—", color=dim, size=11)
    else:
        seg = ft.Text(f"{seg_start:.0f}s – {seg_end:.0f}s", color=dim, size=11)
        badge = ft.Container(
            bgcolor="#1e3a5f" if has_clap else "#2a1a1a",
            border_radius=16,
            padding=ft.padding.symmetric(horizontal=8, vertical=3),
            content=ft.Text(
                "CLAP ✓" if has_clap else "↻ re-analyze",
                size=11,
                color=C["acc"] if has_clap else "#ef4444",
            ),
        )

    return ft.Container(
        bgcolor=C["surf"],
        border=ft.border.only(bottom=ft.BorderSide(1, C["brd"])),
        padding=ft.padding.symmetric(horizontal=16, vertical=10),
        content=ft.Row([
            ft.Column([
                ft.Text(track["title"], size=13, weight=ft.FontWeight.W_500,
                        color=C["text"], no_wrap=True, overflow=ft.TextOverflow.ELLIPSIS),
                ft.Text(track["artist"], size=11, color=dim,
                        no_wrap=True, overflow=ft.TextOverflow.ELLIPSIS),
            ], expand=3, spacing=2),
            seg,
            badge,
        ], vertical_alignment=ft.CrossAxisAlignment.CENTER, spacing=16),
    )


def start_gui():
    if sys.platform == "darwin":
        _start_gui_macos()
    else:
        ft.app(target=RimeoUI)


def _start_gui_macos():
    """
    macOS: flet-desktop (the Flutter subprocess) terminates when its window
    is closed — this is standard macOS app lifecycle and cannot be overridden
    in a pre-built binary.  We handle this by:

      1. Running ft.app() in a loop so the window can be re-opened.
      2. Between Flet runs, pumping NSRunLoop on the main thread so the
         status bar menu remains responsive.
      3. The status bar item itself lives at class level and survives restarts.
    """
    import AppKit
    global _flet_running

    while True:
        logger.info("Launching Flet window")
        ft.app(target=RimeoUI)

        # ft.app() returned — flet-desktop exited (window was closed)
        _flet_running = False
        logger.info("Flet window closed — status bar active, waiting for reopen")

        # Pump NSRunLoop synchronously so status bar stays responsive
        _reopen_event.clear()
        while not _reopen_event.is_set():
            AppKit.NSRunLoop.currentRunLoop().runMode_beforeDate_(
                AppKit.NSDefaultRunLoopMode,
                AppKit.NSDate.distantPast(),
            )
            time.sleep(0.05)

        _reopen_event.clear()
        logger.info("Reopen requested — restarting Flet window")
