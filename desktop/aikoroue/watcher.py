"""Détecte « glisser un fichier + raccourci (Maj par défaut) » n'importe où (Windows et Linux X11).

Aucune capture du clavier : seule la souris est écoutée (pynput), et l'état de la
touche choisie est lu directement auprès du système au moment du glisser.
"""
from __future__ import annotations

import os
import sys

from PySide6.QtCore import QObject, Signal

IS_WIN = sys.platform == "win32"
IS_WAYLAND = sys.platform.startswith("linux") and (
    os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland" or bool(os.environ.get("WAYLAND_DISPLAY"))
)

# Fenêtres d'où l'on glisse des fichiers sous Windows (Explorateur + Bureau)
EXPLORER_CLASSES = {"CabinetWClass", "ExploreWClass", "Progman", "WorkerW"}


# ------------------------------------------------------------ état des touches

if IS_WIN:
    import ctypes
    from ctypes import wintypes

    _user32 = ctypes.windll.user32
    _user32.WindowFromPoint.argtypes = [wintypes.POINT]
    _user32.WindowFromPoint.restype = wintypes.HWND
    _user32.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
    _user32.GetAncestor.restype = wintypes.HWND

    _VK = {"shift": (0x10,), "ctrl": (0x11,), "alt": (0x12,), "meta": (0x5B, 0x5C)}

    def _down(vk: int) -> bool:
        return bool(_user32.GetAsyncKeyState(vk) & 0x8000)

    def trigger_down(trigger) -> bool:
        if not trigger.mods and trigger.key is None:
            return False
        if not all(any(_down(vk) for vk in _VK[m]) for m in trigger.mods):
            return False
        return trigger.key is None or _down(int(trigger.key))

    def from_file_manager() -> bool:
        pt = wintypes.POINT()
        _user32.GetCursorPos(ctypes.byref(pt))
        hwnd = _user32.WindowFromPoint(pt)
        if not hwnd:
            return False
        root = _user32.GetAncestor(hwnd, 2) or hwnd  # GA_ROOT
        buf = ctypes.create_unicode_buffer(256)
        _user32.GetClassNameW(root, buf, 256)
        return buf.value in EXPLORER_CLASSES

else:
    _xdisplay = None
    _mod_codes: dict[str, list[int]] = {}
    _KEYSYMS = {"shift": ("Shift_L", "Shift_R"), "ctrl": ("Control_L", "Control_R"),
                "alt": ("Alt_L", "Alt_R", "ISO_Level3_Shift"), "meta": ("Super_L", "Super_R")}

    def _init_x():
        global _xdisplay
        if _xdisplay is None:
            from Xlib import XK, display

            _xdisplay = display.Display()
            for mod, names in _KEYSYMS.items():
                codes = [_xdisplay.keysym_to_keycode(XK.string_to_keysym(n)) for n in names]
                _mod_codes[mod] = [c for c in codes if c]

    def trigger_down(trigger) -> bool:
        if not trigger.mods and trigger.key is None:
            return False
        try:
            _init_x()
            keys = _xdisplay.query_keymap()

            def down(code: int) -> bool:
                return bool(code) and bool(keys[code // 8] & (1 << (code % 8)))

            if not all(any(down(c) for c in _mod_codes.get(m, [])) for m in trigger.mods):
                return False
            if trigger.key is None:
                return True
            return down(_xdisplay.keysym_to_keycode(int(trigger.key)))
        except Exception:
            return False

    def from_file_manager() -> bool:
        return True


class DragWatcher(QObject):
    """Émet `shift_drag` quand on glisse avec le raccourci, `released` au relâchement."""

    shift_drag = Signal()
    released = Signal()

    def __init__(self):
        super().__init__()
        from .shortcut import Trigger

        self.trigger = Trigger()
        self.enabled = True
        self.everywhere = False  # Windows : accepter aussi les glisser hors de l'Explorateur
        self._down = False
        self._fired = False
        self._eligible = False
        self._start = (0, 0)
        self._listener = None

    @property
    def available(self) -> bool:
        return not IS_WAYLAND

    def start(self) -> bool:
        if not self.available:
            return False
        try:
            from pynput import mouse
        except Exception:
            return False
        self._listener = mouse.Listener(on_click=self._on_click, on_move=self._on_move)
        self._listener.daemon = True
        self._listener.start()
        return True

    def stop(self):
        if self._listener:
            self._listener.stop()

    # Appelés depuis le fil de pynput : on ne touche jamais à l'interface ici,
    # on se contente d'émettre des signaux (Qt les relaie au fil principal).
    def _on_click(self, x, y, button, pressed):
        if getattr(button, "name", "") != "left":
            return
        if pressed:
            self._down, self._fired = True, False
            self._start = (x, y)
            try:
                self._eligible = self.everywhere or from_file_manager()
            except Exception:
                self._eligible = True
        else:
            was_fired = self._fired
            self._down = self._fired = False
            if was_fired:
                self.released.emit()

    def _on_move(self, x, y):
        if not (self.enabled and self._down and self._eligible) or self._fired:
            return
        if abs(x - self._start[0]) + abs(y - self._start[1]) < 12:
            return
        if trigger_down(self.trigger):
            self._fired = True
            self.shift_drag.emit()
