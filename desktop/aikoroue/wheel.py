"""La roue AikoRoue (Qt) — même design que la version Mac."""
from __future__ import annotations

import math
from pathlib import Path

from PySide6.QtCore import QPointF, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import (QColor, QCursor, QFont, QGuiApplication, QIcon, QPainter, QPainterPath, QRegion,
                           QPalette, QPen, QPixmap)
from PySide6.QtWidgets import QWidget

from . import catalog

ACCENT = QColor("#7DC8FF")
ON_ACCENT = QColor("#05121C")

DARK = dict(disc=QColor(10, 10, 12, 248), line=QColor(255, 255, 255, 23), text=QColor("#F5F7FA"),
            subtext=QColor("#8C949E"), center=QColor("#17171A"))
LIGHT = dict(disc=QColor(255, 255, 255, 250), line=QColor(0, 0, 0, 20), text=QColor("#0A0D10"),
             subtext=QColor("#6B7380"), center=QColor("#F2F7FC"))


def is_dark() -> bool:
    hints = QGuiApplication.styleHints()
    try:
        scheme = hints.colorScheme()
        if scheme == Qt.ColorScheme.Dark:
            return True
        if scheme == Qt.ColorScheme.Light:
            return False
    except AttributeError:
        pass
    return QGuiApplication.palette().color(QPalette.ColorRole.Window).lightness() < 128


def theme() -> dict:
    return DARK if is_dark() else LIGHT


def ui_font(px: float, weight: QFont.Weight = QFont.Weight.Normal) -> QFont:
    f = QFont()
    f.setPixelSize(max(1, round(px)))
    f.setWeight(weight)
    return f


def tray_icon() -> QIcon:
    """Icône de la zone de notification : petite roue bleu clair."""
    icon = QIcon()
    for s in (16, 20, 24, 32, 48, 64):
        pm = QPixmap(s, s)
        pm.fill(Qt.GlobalColor.transparent)
        p = QPainter(pm)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        k = s / 18
        pen = QPen(ACCENT, 1.7 * k)
        p.setPen(pen)
        p.drawEllipse(QRectF(1.5 * k, 1.5 * k, 15 * k, 15 * k))
        p.drawEllipse(QPointF(9 * k, 9 * k), 2.6 * k, 2.6 * k)
        pen.setWidthF(1.3 * k)
        p.setPen(pen)
        for i in range(6):
            a = i * math.pi / 3 + math.pi / 2
            p.drawLine(QPointF(9 * k + math.cos(a) * 3.7 * k, 9 * k - math.sin(a) * 3.7 * k),
                       QPointF(9 * k + math.cos(a) * 7.2 * k, 9 * k - math.sin(a) * 7.2 * k))
        p.end()
        icon.addPixmap(pm)
    return icon


def _paths_from(mime) -> list[Path]:
    if not mime.hasUrls():
        return []
    return [Path(u.toLocalFile()) for u in mime.urls() if u.isLocalFile() and u.toLocalFile()]


class WheelWindow(QWidget):
    """Fenêtre ronde flottante qui accepte les fichiers déposés."""

    picked = Signal(object, list)  # (Action, [Path])

    SIDE = 420
    CENTER_R = 46
    RINGS = [(46.0, 118.0), (118.0, 186.0)]

    def __init__(self):
        super().__init__(None)
        self._flags_drag = (Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint
                            | Qt.WindowType.Tool | Qt.WindowType.WindowDoesNotAcceptFocus)
        self._flags_pinned = (Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint
                              | Qt.WindowType.Tool)
        self.setWindowFlags(self._flags_drag)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAcceptDrops(True)
        self.setFixedSize(self.SIDE, self.SIDE)
        self.setWindowTitle("AikoRoue")

        self.rings: list[list[catalog.Action]] = []
        self.badge = ""
        self.count_text = ""
        self.hovered: tuple[int, int] | None = None
        self.in_center = False
        self.pinned = False
        self.got_drag = False

        self._idle = QTimer(self)  # se referme si aucun fichier n'arrive (ex. simple sélection)
        self._idle.setSingleShot(True)
        self._idle.timeout.connect(self._idle_timeout)
        self._hide_timer = QTimer(self)
        self._hide_timer.setSingleShot(True)
        self._hide_timer.timeout.connect(self.hide)

    # ------------------------------------------------------------ affichage

    def present_at_cursor(self):
        self.pinned = False
        self._reset()
        self._place(QCursor.pos())
        self._idle.start(900)

    def present_pinned(self):
        """Ouverte depuis l'icône : reste au centre de l'écran en attendant un fichier."""
        self.pinned = True
        self._reset()
        screen = QGuiApplication.screenAt(QCursor.pos()) or QGuiApplication.primaryScreen()
        self._place(screen.availableGeometry().center(), flags=self._flags_pinned)
        self.activateWindow()
        self.raise_()

    def dismiss(self, delay_ms: int = 0):
        if self.pinned and delay_ms:
            return
        if delay_ms:
            self._hide_timer.start(delay_ms)
        else:
            self.hide()

    def _reset(self):
        self._hide_timer.stop()
        self.rings, self.badge, self.count_text = [], "", ""
        self.hovered, self.in_center, self.got_drag = None, False, False

    def _place(self, center, flags=None):
        want = flags or self._flags_drag
        if self.windowFlags() != want:
            self.setWindowFlags(want)
        screen = QGuiApplication.screenAt(center) or QGuiApplication.primaryScreen()
        geo = screen.availableGeometry()
        x = min(max(center.x() - self.SIDE // 2, geo.left()), geo.right() - self.SIDE)
        y = min(max(center.y() - self.SIDE // 2, geo.top()), geo.bottom() - self.SIDE)
        self.move(x, y)
        self._apply_mask()
        self.show()
        self.raise_()
        self.update()

    def _apply_mask(self):
        r = int((self.outer_radius() if self.rings else self.RINGS[1][1]) + 18)
        c = self.SIDE // 2
        self.setMask(QRegion(c - r, c - r, 2 * r, 2 * r, QRegion.RegionType.Ellipse))

    def _idle_timeout(self):
        if not self.got_drag and not self.pinned:
            self.hide()

    def _configure(self, paths: list[Path]):
        acts = catalog.actions_for(paths)
        formats = [a for a in acts if a.ring == catalog.FORMATS]
        tools = [a for a in acts if a.ring == catalog.TOOLS]
        self.rings = [r for r in (formats, tools) if r]
        self.badge = catalog.badge(paths)
        self.count_text = "1 fichier" if len(paths) == 1 else f"{len(paths)} fichiers"

    # ------------------------------------------------------------ géométrie

    @property
    def mid(self) -> QPointF:
        return QPointF(self.width() / 2, self.height() / 2)

    def outer_radius(self) -> float:
        n = max(1, min(len(self.rings), len(self.RINGS)))
        return self.RINGS[n - 1][1]

    @staticmethod
    def _mid_angle(i: int, n: int) -> float:
        return 90 - i * 360 / n

    def _pt(self, angle_deg: float, r: float) -> QPointF:
        a = math.radians(angle_deg)
        return QPointF(self.mid.x() + math.cos(a) * r, self.mid.y() - math.sin(a) * r)

    def _circle(self, r: float) -> QRectF:
        return QRectF(self.mid.x() - r, self.mid.y() - r, 2 * r, 2 * r)

    def _wedge(self, k: int, i: int, n: int, inset: float) -> QPainterPath:
        ra, rb = self.RINGS[k]
        ra, rb = ra + inset, rb - inset
        path = QPainterPath()
        if n == 1:
            path.addEllipse(self._circle(rb))
            path.addEllipse(self._circle(ra))
            path.setFillRule(Qt.FillRule.OddEvenFill)
            return path
        step = 360 / n
        m = self._mid_angle(i, n)
        go = math.degrees(inset / rb)
        gi = math.degrees(inset / ra)
        start = m + step / 2 - go
        path.moveTo(self._pt(start, rb))
        path.arcTo(self._circle(rb), start, -(step - 2 * go))
        path.lineTo(self._pt(m - step / 2 + gi, ra))
        path.arcTo(self._circle(ra), m - step / 2 + gi, step - 2 * gi)
        path.closeSubpath()
        return path

    def _hit(self, pos: QPointF):
        dx, dy = pos.x() - self.mid.x(), self.mid.y() - pos.y()
        d = math.hypot(dx, dy)
        for k, ring in enumerate(self.rings[: len(self.RINGS)]):
            ra, rb = self.RINGS[k]
            last = k == len(self.rings) - 1
            if not (ra <= d <= (rb + 30 if last else rb)):
                continue
            n = len(ring)
            if n == 1:
                return (k, 0)
            angle = math.degrees(math.atan2(dy, dx))
            rel = (90 - angle) % 360
            step = 360 / n
            return (k, int((rel + step / 2) // step) % n)
        return None

    def _is_center(self, pos: QPointF) -> bool:
        return math.hypot(pos.x() - self.mid.x(), pos.y() - self.mid.y()) < self.CENTER_R

    # ------------------------------------------------------------ dessin

    def paintEvent(self, _):
        t = theme()
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.TextAntialiasing)
        outer = self.outer_radius() if self.rings else self.RINGS[1][1]

        # ombre douce faite maison (pas d'ombre système sur une fenêtre transparente)
        p.setPen(Qt.PenStyle.NoPen)
        for i in range(14, 0, -1):
            p.setBrush(QColor(0, 0, 0, 5))
            p.drawEllipse(self._circle(outer + i).translated(0, 3))

        # disque
        p.setBrush(t["disc"])
        p.setPen(QPen(t["line"], 1))
        p.drawEllipse(self._circle(outer))

        if not self.rings:
            self._draw_center(p, t, "glisse", "un fichier ici" if self.pinned else "…")
            p.end()
            return

        # séparations
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.setPen(QPen(t["line"], 1))
        for k, ring in enumerate(self.rings[: len(self.RINGS)]):
            ra, rb = self.RINGS[k]
            if k > 0:
                p.drawEllipse(self._circle(ra))
            if len(ring) > 1:
                step = 360 / len(ring)
                for i in range(len(ring)):
                    a = self._mid_angle(i, len(ring)) + step / 2
                    p.drawLine(self._pt(a, ra + 10), self._pt(a, rb - 10))

        # quartier survolé
        if self.hovered:
            k, i = self.hovered
            if k < len(self.rings) and i < len(self.rings[k]):
                path = self._wedge(k, i, len(self.rings[k]), 5)
                pen = QPen(ACCENT, 6)
                pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
                p.setPen(pen)
                p.setBrush(ACCENT)
                p.drawPath(path)

        # libellés
        for k, ring in enumerate(self.rings[: len(self.RINGS)]):
            ra, rb = self.RINGS[k]
            for i, act in enumerate(ring):
                hot = self.hovered == (k, i)
                r = (ra + rb) / 2 + (6 if k == 0 else 0)
                pt = self._pt(self._mid_angle(i, len(ring)), r)
                color = ON_ACCENT if hot else t["text"]
                if act.ring == catalog.FORMATS:
                    self._text(p, act.title, pt, ui_font(13, QFont.Weight.DemiBold), color, spacing=0.4)
                else:
                    self._text(p, act.title, pt, ui_font(11, QFont.Weight.Medium), color)

        title, sub = self.badge, self.count_text
        if self.in_center:
            title, sub = "✕", "annuler"
        elif self.hovered:
            k, i = self.hovered
            if k < len(self.rings) and i < len(self.rings[k]):
                title, sub = self.rings[k][i].title, "lâcher"
        self._draw_center(p, t, title, sub)
        p.end()

    def _draw_center(self, p: QPainter, t: dict, title: str, sub: str):
        p.setBrush(t["line"] if self.in_center else t["center"])
        p.setPen(QPen(ACCENT, 1.5))
        p.drawEllipse(self._circle(self.CENTER_R - 6))
        size = 11 if len(title) > 7 else (14 if len(title) <= 5 else 12)
        self._text(p, title, QPointF(self.mid.x(), self.mid.y() - 6), ui_font(size, QFont.Weight.Bold), t["text"])
        self._text(p, sub, QPointF(self.mid.x(), self.mid.y() + 10), ui_font(9), t["subtext"])

    @staticmethod
    def _text(p: QPainter, s: str, center: QPointF, font: QFont, color: QColor, spacing: float = 0):
        if spacing:
            font.setLetterSpacing(QFont.SpacingType.AbsoluteSpacing, spacing)
        p.setFont(font)
        p.setPen(color)
        rect = QRectF(center.x() - 70, center.y() - 12, 140, 24)
        p.drawText(rect, Qt.AlignmentFlag.AlignCenter, s)

    # ------------------------------------------------------------ glisser-déposer

    def dragEnterEvent(self, e):
        paths = _paths_from(e.mimeData())
        if not paths:
            e.ignore()
            if not self.pinned:
                self.hide()
            return
        self.got_drag = True
        self._idle.stop()
        self._hide_timer.stop()
        self._configure(paths)
        self._apply_mask()
        self._track(e)

    def dragMoveEvent(self, e):
        self._track(e)

    def dragLeaveEvent(self, _):
        self.hovered, self.in_center = None, False
        self.update()

    def _track(self, e):
        pos = e.position()
        self.in_center = self._is_center(pos)
        self.hovered = None if self.in_center else self._hit(pos)
        self.update()
        # On accepte partout sur la roue (sinon Windows affiche le curseur « interdit »).
        # Toujours « copier », jamais « déplacer » : l'original reste intact.
        e.setDropAction(Qt.DropAction.CopyAction)
        e.accept()

    def dropEvent(self, e):
        pos = e.position()
        slot = None if self._is_center(pos) else self._hit(pos)
        paths = _paths_from(e.mimeData())
        if not slot or not paths:  # lâché au centre (ou hors quartier) : on annule sans rien faire
            e.setDropAction(Qt.DropAction.IgnoreAction)
            e.ignore()
            self.hovered, self.in_center = None, False
            if not self.pinned:
                self.hide()
            return
        k, i = slot
        action = self.rings[k][i]
        e.setDropAction(Qt.DropAction.CopyAction)
        e.accept()
        self.hide()
        self.picked.emit(action, paths)

    # ------------------------------------------------------------ mode « épinglé »

    def mousePressEvent(self, e):
        pos = e.position()
        far = math.hypot(pos.x() - self.mid.x(), pos.y() - self.mid.y()) > self.outer_radius()
        if self._is_center(pos) or far:
            self.hide()

    def keyPressEvent(self, e):
        if e.key() == Qt.Key.Key_Escape:
            self.hide()


class Toast(QWidget):
    """Petite bulle « Conversion en PNG… » puis « ✓ photo.png »."""

    def __init__(self):
        super().__init__(None)
        self.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint
                            | Qt.WindowType.Tool | Qt.WindowType.WindowDoesNotAcceptFocus
                            | Qt.WindowType.WindowTransparentForInput)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.text = ""
        self.spinning = False
        self.angle = 0
        self._spin = QTimer(self)
        self._spin.timeout.connect(self._tick)
        self._hide = QTimer(self)
        self._hide.setSingleShot(True)
        self._hide.timeout.connect(self.hide)

    def _tick(self):
        self.angle = (self.angle + 30) % 360
        self.update()

    def show_message(self, text: str, spinning: bool, near, hide_after_ms: int | None = None):
        self.text, self.spinning = text, spinning
        font = ui_font(13, QFont.Weight.Medium)
        from PySide6.QtGui import QFontMetrics

        fm = QFontMetrics(font)
        w = min(420, fm.horizontalAdvance(text) + (60 if spinning else 40))
        h = 40
        self.setFixedSize(w + 24, h + 24)  # marge pour l'ombre
        screen = QGuiApplication.screenAt(near) or QGuiApplication.primaryScreen()
        geo = screen.availableGeometry()
        x = min(max(near.x() - self.width() // 2, geo.left()), geo.right() - self.width())
        y = min(max(near.y() - 90, geo.top()), geo.bottom() - self.height())
        self.move(x, y)
        if spinning:
            self._spin.start(80)
        else:
            self._spin.stop()
        self._hide.stop()
        if hide_after_ms:
            self._hide.start(hide_after_ms)
        self.show()
        self.raise_()
        self.update()

    def paintEvent(self, _):
        t = theme()
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        box = QRectF(12, 10, self.width() - 24, self.height() - 24)
        p.setPen(Qt.PenStyle.NoPen)
        for i in range(10, 0, -1):
            p.setBrush(QColor(0, 0, 0, 6))
            p.drawRoundedRect(box.adjusted(-i, -i + 3, i, i + 3), 10 + i, 10 + i)
        p.setBrush(t["disc"])
        p.setPen(QPen(t["line"], 1))
        p.drawRoundedRect(box, 10, 10)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(ACCENT)
        p.drawRoundedRect(QRectF(box.left() + 9, box.center().y() - 8, 3, 16), 1.5, 1.5)
        x = box.left() + 22
        if self.spinning:
            pen = QPen(ACCENT, 2)
            pen.setCapStyle(Qt.PenCapStyle.RoundCap)
            p.setPen(pen)
            p.drawArc(QRectF(x, box.center().y() - 7, 14, 14), -self.angle * 16, 270 * 16)
            x += 22
        p.setPen(t["text"])
        p.setFont(ui_font(13, QFont.Weight.Medium))
        p.drawText(QRectF(x, box.top(), box.right() - x - 10, box.height()),
                   Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft, self.text)
        p.end()
