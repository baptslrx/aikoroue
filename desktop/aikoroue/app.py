"""AikoRoue pour Windows et Linux : icône dans la zone de notification + roue."""
from __future__ import annotations

import os
import sys
import threading
from pathlib import Path

from PySide6.QtCore import QObject, QSettings, Qt, Signal
from PySide6.QtGui import QAction, QCursor, QIcon
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtWidgets import QApplication, QMenu, QMessageBox, QSystemTrayIcon

from . import __version__
from .converters import Oops
from .watcher import IS_WAYLAND, IS_WIN, DragWatcher
from .wheel import Toast, WheelWindow, tray_icon

APP_ID = "aikoroue-instance"


def resource(name: str) -> Path:
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
    for cand in (base / "assets" / name, base.parent / "assets" / name):
        if cand.exists():
            return cand
    return base / name


# ------------------------------------------------------------ démarrage automatique

def _exe_command() -> str:
    if getattr(sys, "frozen", False):
        return f'"{os.environ.get("APPIMAGE", sys.executable)}"'
    return f'"{sys.executable}" -m aikoroue'


def autostart_enabled() -> bool:
    if IS_WIN:
        import winreg

        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run") as k:
                winreg.QueryValueEx(k, "AikoRoue")
                return True
        except OSError:
            return False
    return _desktop_file().exists()


def set_autostart(on: bool) -> None:
    if IS_WIN:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run",
                            0, winreg.KEY_SET_VALUE) as k:
            if on:
                winreg.SetValueEx(k, "AikoRoue", 0, winreg.REG_SZ, _exe_command())
            else:
                try:
                    winreg.DeleteValue(k, "AikoRoue")
                except OSError:
                    pass
        return
    f = _desktop_file()
    if on:
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text("[Desktop Entry]\nType=Application\nName=AikoRoue\n"
                     f"Exec={_exe_command()}\nX-GNOME-Autostart-enabled=true\n", encoding="utf-8")
    elif f.exists():
        f.unlink()


def _desktop_file() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "autostart" / "aikoroue.desktop"


# ------------------------------------------------------------ travail en arrière-plan

class Job(QObject):
    finished = Signal(list)
    failed = Signal(str)


class AikoRoue(QObject):
    def __init__(self, app: QApplication):
        super().__init__()
        self.app = app
        self.settings = QSettings("Aikographic", "AikoRoue")
        self.jobs: list[Job] = []

        self.wheel = WheelWindow()
        self.wheel.picked.connect(self.perform)
        self.toast = Toast()

        self.watcher = DragWatcher()
        self.watcher.enabled = self.settings.value("enabled", True, type=bool)
        self.watcher.everywhere = self.settings.value("everywhere", False, type=bool)
        self.watcher.shift_drag.connect(self.wheel.present_at_cursor)
        self.watcher.released.connect(lambda: self.wheel.dismiss(450))
        self.hook_ok = self.watcher.start()

        self.tray = QSystemTrayIcon(tray_icon(), self)
        self.tray.setToolTip("AikoRoue — Maj + glisser un fichier")
        self.tray.activated.connect(self._tray_clicked)
        self._build_menu()
        if QSystemTrayIcon.isSystemTrayAvailable():
            self.tray.show()

        self.server = QLocalServer(self)
        QLocalServer.removeServer(APP_ID)
        self.server.listen(APP_ID)
        self.server.newConnection.connect(self._second_launch)

        if not self.settings.value("welcomed", False, type=bool):
            self.settings.setValue("welcomed", True)
            self._welcome()
        elif not QSystemTrayIcon.isSystemTrayAvailable():
            self.wheel.present_pinned()

    # ------------------------------------------------------------ menu

    def _build_menu(self):
        m = QMenu()
        head = m.addAction(f"AikoRoue {__version__}")
        head.setEnabled(False)
        hint = m.addAction("Maj + glisser un fichier" if self.hook_ok else "Clique ici, puis glisse un fichier")
        hint.setEnabled(False)
        m.addSeparator()
        m.addAction("Ouvrir la roue", self.wheel.present_pinned)
        m.addSeparator()

        self.act_enabled = QAction("Activé", m, checkable=True, checked=self.watcher.enabled)
        self.act_enabled.toggled.connect(self._set_enabled)
        self.act_enabled.setVisible(self.hook_ok)
        m.addAction(self.act_enabled)

        if IS_WIN:
            act = QAction("Partout (pas seulement l'Explorateur)", m, checkable=True,
                          checked=self.watcher.everywhere)
            act.toggled.connect(self._set_everywhere)
            m.addAction(act)

        act_login = QAction("Lancer au démarrage", m, checkable=True, checked=autostart_enabled())
        act_login.toggled.connect(self._set_login)
        m.addAction(act_login)
        m.addSeparator()
        m.addAction("Quitter AikoRoue", self.app.quit)
        self.menu = m
        self.tray.setContextMenu(m)

    def _set_enabled(self, on: bool):
        self.watcher.enabled = on
        self.settings.setValue("enabled", on)

    def _set_everywhere(self, on: bool):
        self.watcher.everywhere = on
        self.settings.setValue("everywhere", on)

    def _set_login(self, on: bool):
        try:
            set_autostart(on)
        except Exception as e:
            QMessageBox.warning(None, "AikoRoue", f"Impossible de modifier le démarrage automatique :\n{e}")

    def _tray_clicked(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.wheel.present_pinned()

    def _second_launch(self):
        sock = self.server.nextPendingConnection()
        if sock:
            sock.close()
        self.wheel.present_pinned()

    def _welcome(self):
        if self.hook_ok:
            how = ("Commence à glisser un fichier depuis l'Explorateur ou le Bureau, puis appuie sur Maj : "
                   "une roue apparaît sous ta souris." if IS_WIN else
                   "Commence à glisser un fichier depuis ton gestionnaire de fichiers, puis appuie sur Maj : "
                   "une roue apparaît sous ta souris.")
        else:
            how = ("Ton bureau Linux (Wayland) ne permet pas de détecter Maj + glisser. Clique sur l'icône "
                   "AikoRoue (ou relance l'appli) pour ouvrir la roue, puis glisse ton fichier dessus.")
        box = QMessageBox()
        box.setWindowTitle("AikoRoue")
        box.setIconPixmap(QIcon(str(resource("icon-256.png"))).pixmap(64, 64))
        box.setText("<b>AikoRoue est prêt</b>")
        box.setInformativeText(
            f"{how}\n\n• Anneau intérieur : convertir dans un autre format\n"
            "• Anneau extérieur : outils (compresser, pivoter, fusionner…)\n"
            "• Lâcher au centre : annuler\n\n"
            "Le résultat est créé à côté du fichier d'origine. AikoRoue reste dans la zone de notification.")
        box.exec()

    # ------------------------------------------------------------ actions

    def perform(self, action, paths: list[Path]):
        near = QCursor.pos()
        self.toast.show_message(f"{action.verb}…", True, near)

        job = Job()
        self.jobs.append(job)
        job.finished.connect(lambda outs: self._done(job, outs, near))
        job.failed.connect(lambda msg: self._fail(job, msg, near))

        def work():
            try:
                job.finished.emit(action.run(paths))
            except Oops as e:
                job.failed.emit(str(e))
            except Exception as e:  # pragma: no cover
                job.failed.emit(f"Erreur : {e}")

        if action.gui_thread:
            work()
        else:
            threading.Thread(target=work, daemon=True).start()

    def _done(self, job: Job, outs: list, near):
        self.jobs.remove(job)
        msg = f"✓ {outs[0].name}" if len(outs) == 1 else f"✓ {len(outs)} fichiers créés"
        self.toast.show_message(msg, False, near, 2200)

    def _fail(self, job: Job, msg: str, near):
        self.jobs.remove(job)
        self.toast.show_message(f"⚠ {msg}", False, near, 4500)


def main() -> int:
    QApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    app = QApplication(sys.argv)

    # Une seule instance : un second lancement ouvre simplement la roue.
    probe = QLocalSocket()
    probe.connectToServer(APP_ID)
    if probe.waitForConnected(300):
        probe.disconnectFromServer()
        return 0

    app.setApplicationName("AikoRoue")
    app.setOrganizationName("Aikographic")
    app.setQuitOnLastWindowClosed(False)
    icon_path = resource("icon-256.png")
    if icon_path.exists():
        app.setWindowIcon(QIcon(str(icon_path)))
    _ = AikoRoue(app)
    return app.exec()
