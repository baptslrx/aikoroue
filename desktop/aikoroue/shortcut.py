"""Raccourci configurable : la touche (ou combinaison) à maintenir pendant le glisser."""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field

from PySide6.QtCore import Qt
from PySide6.QtGui import QFont, QKeySequence
from PySide6.QtWidgets import QDialog, QHBoxLayout, QLabel, QPushButton, QVBoxLayout

IS_WIN = sys.platform == "win32"
MOD_ORDER = ("ctrl", "alt", "shift", "meta")
MOD_LABELS = {"ctrl": "Ctrl", "alt": "Alt", "shift": "Maj", "meta": "Win" if IS_WIN else "Super"}

QT_KEY_TO_MOD = {
    Qt.Key.Key_Shift: "shift",
    Qt.Key.Key_Control: "ctrl",
    Qt.Key.Key_Alt: "alt",
    Qt.Key.Key_AltGr: "alt",
    Qt.Key.Key_Meta: "meta",
    Qt.Key.Key_Super_L: "meta",
    Qt.Key.Key_Super_R: "meta",
}

KEY_NAMES = {"Space": "Espace", "Return": "Entrée", "Enter": "Entrée", "Backspace": "Retour arrière",
             "Del": "Suppr", "Delete": "Suppr", "Ins": "Inser", "Left": "←", "Right": "→", "Up": "↑",
             "Down": "↓", "PgUp": "Page préc.", "PgDown": "Page suiv.", "CapsLock": "Verr. Maj"}


@dataclass
class Trigger:
    mods: list[str] = field(default_factory=lambda: ["shift"])
    key: int | None = None          # code natif : touche virtuelle (Windows) ou keysym (Linux)
    key_label: str | None = None

    def label(self) -> str:
        parts = [MOD_LABELS[m] for m in MOD_ORDER if m in self.mods]
        if self.key_label:
            parts.append(self.key_label)
        return " + ".join(parts) if parts else "—"

    def dumps(self) -> str:
        return json.dumps({"mods": self.mods, "key": self.key, "key_label": self.key_label})

    @classmethod
    def loads(cls, raw: str | None) -> "Trigger":
        try:
            d = json.loads(raw or "")
            t = cls([m for m in d.get("mods", []) if m in MOD_ORDER], d.get("key"), d.get("key_label"))
            return t if (t.mods or t.key) else cls()
        except Exception:
            return cls()


def _mods_from(modifiers) -> set[str]:
    out = set()
    if modifiers & Qt.KeyboardModifier.ShiftModifier:
        out.add("shift")
    if modifiers & Qt.KeyboardModifier.ControlModifier:
        out.add("ctrl")
    if modifiers & Qt.KeyboardModifier.AltModifier:
        out.add("alt")
    if modifiers & Qt.KeyboardModifier.MetaModifier:
        out.add("meta")
    return out


class ShortcutDialog(QDialog):
    """« Appuie sur la touche voulue » — capture la touche dans cette fenêtre uniquement."""

    def __init__(self, current: Trigger, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Raccourci AikoRoue")
        self.setWindowFlag(Qt.WindowType.WindowStaysOnTopHint)
        self.setMinimumWidth(420)
        self.pending = Trigger(list(current.mods), current.key, current.key_label)
        self.held: set[str] = set()

        intro = QLabel("Appuie sur la touche ou la combinaison qui ouvrira la roue "
                       "pendant que tu glisses un fichier.")
        intro.setWordWrap(True)

        self.display = QLabel(self.pending.label())
        f = QFont()
        f.setPixelSize(24)
        f.setWeight(QFont.Weight.DemiBold)
        self.display.setFont(f)
        self.display.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.display.setMinimumHeight(56)
        self.display.setStyleSheet("border: 1.5px solid #7DC8FF; border-radius: 10px; padding: 8px;")

        if IS_WIN:
            tip = ("Dans l'Explorateur, Ctrl copie et Alt crée un raccourci si tu lâches le fichier ailleurs "
                   "que sur la roue. Maj ou une lettre n'ont pas cet effet.")
        else:
            tip = ("Dans ton gestionnaire de fichiers, Ctrl copie et Maj déplace si tu lâches le fichier "
                   "ailleurs que sur la roue. Une lettre n'a pas cet effet.")
        hint = QLabel(tip)
        hint.setWordWrap(True)
        hint.setStyleSheet("color: palette(placeholder-text); font-size: 11px;")

        reset = QPushButton("Rétablir Maj")
        cancel = QPushButton("Annuler")
        save = QPushButton("Enregistrer")
        save.setStyleSheet("QPushButton { background: #7DC8FF; color: #05121C; border: none; "
                           "border-radius: 6px; padding: 6px 14px; font-weight: 600; }")
        for b in (reset, cancel, save):
            b.setFocusPolicy(Qt.FocusPolicy.NoFocus)
            b.setAutoDefault(False)
            b.setDefault(False)
        reset.clicked.connect(self._reset)
        cancel.clicked.connect(self.reject)
        save.clicked.connect(self.accept)

        row = QHBoxLayout()
        row.addWidget(reset)
        row.addStretch(1)
        row.addWidget(cancel)
        row.addWidget(save)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 20, 20, 18)
        lay.setSpacing(14)
        lay.addWidget(intro)
        lay.addWidget(self.display)
        lay.addWidget(hint)
        lay.addLayout(row)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

    def showEvent(self, e):
        super().showEvent(e)
        self.activateWindow()
        self.setFocus()

    def focusNextPrevChild(self, _next: bool) -> bool:  # garder Tab pour nous
        return False

    def _reset(self):
        self.pending = Trigger()
        self.display.setText(self.pending.label())

    def keyPressEvent(self, e):
        if e.isAutoRepeat():
            return
        key = e.key()
        if key == Qt.Key.Key_Escape:
            self.reject()
            return
        mods = _mods_from(e.modifiers())
        if key in QT_KEY_TO_MOD:
            self.held |= mods | {QT_KEY_TO_MOD[key]}
            self.pending = Trigger(sorted(self.held, key=MOD_ORDER.index), None, None)
        else:
            name = QKeySequence(key).toString(QKeySequence.SequenceFormat.PortableText) or e.text().upper()
            name = KEY_NAMES.get(name, name) or f"Touche {e.nativeVirtualKey()}"
            self.pending = Trigger(sorted(mods, key=MOD_ORDER.index), int(e.nativeVirtualKey()), name)
        self.display.setText(self.pending.label())

    def keyReleaseEvent(self, e):
        if not _mods_from(e.modifiers()):
            self.held = set()
