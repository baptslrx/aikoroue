"""Quelles actions proposer selon le type des fichiers glissés (même logique que la version Mac)."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import converters as c

FORMATS, TOOLS = 0, 1

IMAGE_EXTS = {"jpg", "png", "webp", "heic", "gif", "tiff", "bmp", "ico", "avif"}
PDF_EXTS = {"pdf"}
VIDEO_EXTS = {"mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp"}
AUDIO_EXTS = {"mp3", "m4a", "wav", "flac", "ogg", "opus", "aac", "aiff", "wma"}
DOC_EXTS = {"txt", "md", "html", "docx"}


@dataclass(frozen=True)
class Action:
    title: str
    ring: int
    verb: str
    run: Callable[[list[Path]], list[Path]]
    target: str | None = None
    gui_thread: bool = False  # les documents passent par Qt → fil principal


def kind_of(path: Path) -> str:
    if path.is_dir():
        return "other"
    ext = c.norm_ext(path.suffix)
    if ext in IMAGE_EXTS:
        return "image"
    if ext in PDF_EXTS:
        return "pdf"
    if ext in VIDEO_EXTS:
        return "video"
    if ext in AUDIO_EXTS:
        return "audio"
    if ext in DOC_EXTS:
        return "document"
    return "other"


def kind_of_all(paths: list[Path]) -> str:
    kinds = {kind_of(p) for p in paths}
    return kinds.pop() if len(kinds) == 1 else "other"


def badge(paths: list[Path]) -> str:
    exts = {c.norm_ext(p.suffix) for p in paths}
    if len(exts) == 1:
        e = exts.pop()
        if e:
            return e.upper()
    return {"image": "IMAGES", "pdf": "PDF", "video": "VIDÉOS", "audio": "AUDIO",
            "document": "DOCS"}.get(kind_of_all(paths), "FICHIERS")


def fmt(title: str, ext: str, run, verb: str | None = None, gui: bool = False) -> Action:
    return Action(title, FORMATS, verb or f"Conversion en {title}", run, ext, gui)


def tool(title: str, verb: str, run) -> Action:
    return Action(title, TOOLS, verb, run)


ZIP = tool("ZIP", "Compression ZIP", c.make_zip)


def _image() -> list[Action]:
    acts = [
        fmt("JPG", "jpg", lambda p: c.image_convert(p, "jpg")),
        fmt("PNG", "png", lambda p: c.image_convert(p, "png")),
        fmt("WEBP", "webp", lambda p: c.image_convert(p, "webp")),
    ]
    if c.HAS_HEIF:
        acts.append(fmt("HEIC", "heic", lambda p: c.image_convert(p, "heic")))
    acts += [
        fmt("GIF", "gif", lambda p: c.image_convert(p, "gif")),
        fmt("ICO", "ico", lambda p: c.image_convert(p, "ico")),
        fmt("PDF", "pdf", c.image_to_pdf),
        tool("Compresser", "Compression", c.image_compress),
        tool("Réduire", "Réduction de moitié", c.image_resize),
        tool("Pivoter", "Rotation", c.image_rotate),
        tool("Métadonnées", "Suppression des métadonnées", c.image_strip),
        ZIP,
    ]
    return acts


def _pdf(count: int) -> list[Action]:
    acts = [
        fmt("JPG", "jpg", lambda p: c.pdf_to_images(p, "jpg")),
        fmt("PNG", "png", lambda p: c.pdf_to_images(p, "png")),
        fmt("DOCX", "docx", c.pdf_to_docx),
        fmt("TXT", "txt", c.pdf_to_txt),
        tool("Compresser", "Compression", c.pdf_compress),
    ]
    if count > 1:
        acts.append(tool("Fusionner", "Fusion", c.pdf_merge))
    acts += [
        tool("Séparer", "Séparation des pages", c.pdf_split),
        tool("Pivoter", "Rotation", c.pdf_rotate),
        tool("Métadonnées", "Suppression des métadonnées", c.pdf_strip),
        ZIP,
    ]
    return acts


def _video() -> list[Action]:
    return [
        fmt("MP4", "mp4", lambda p: c.media_convert(p, "mp4")),
        fmt("MOV", "mov", lambda p: c.media_convert(p, "mov")),
        fmt("WEBM", "webm", lambda p: c.media_convert(p, "webm")),
        fmt("GIF", "gif", c.video_gif),
        fmt("MP3", "mp3", lambda p: c.media_convert(p, "mp3"), verb="Extraction de l'audio"),
        tool("Compresser", "Compression vidéo", c.video_compress),
        tool("Sans son", "Suppression du son", c.video_mute),
        tool("Image", "Capture d'image", c.video_frame),
        ZIP,
    ]


def _audio() -> list[Action]:
    return [
        fmt("MP3", "mp3", lambda p: c.media_convert(p, "mp3")),
        fmt("M4A", "m4a", lambda p: c.media_convert(p, "m4a")),
        fmt("WAV", "wav", lambda p: c.media_convert(p, "wav")),
        fmt("FLAC", "flac", lambda p: c.media_convert(p, "flac")),
        fmt("OGG", "ogg", lambda p: c.media_convert(p, "ogg")),
        tool("Compresser", "Compression audio", c.audio_compress),
        ZIP,
    ]


def _document() -> list[Action]:
    return [
        fmt(t, t.lower(), (lambda e: lambda p: c.document_convert(p, e))(t.lower()), gui=True)
        for t in ("PDF", "DOCX", "TXT", "MD", "HTML")
    ] + [ZIP]


def actions_for(paths: list[Path]) -> list[Action]:
    if not paths:
        return []
    kind = kind_of_all(paths)
    acts = {
        "image": _image,
        "pdf": lambda: _pdf(len(paths)),
        "video": _video,
        "audio": _audio,
        "document": _document,
    }.get(kind, lambda: [ZIP])()
    # on masque la conversion vers le format d'origine
    return [a for a in acts if not (a.target and all(c.norm_ext(p.suffix) == a.target for p in paths))]
