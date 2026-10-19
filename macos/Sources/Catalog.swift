import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum FileKind: Hashable {
    case image, pdf, video, audio, document, other
}

struct FileAction: Sendable {
    enum Ring: Sendable { case formats, tools }

    let title: String
    let symbol: String?
    let ring: Ring
    let verb: String
    let targetExt: String?
    let run: @Sendable ([URL]) async throws -> [URL]
}

/// Quelles actions proposer selon le type des fichiers glissés.
enum Catalog {
    static let documentExts: Set<String> = [
        "docx", "doc", "rtf", "rtfd", "odt", "txt", "text", "html", "htm", "md", "markdown", "webarchive",
    ]

    static func norm(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg", "jpe": return "jpg"
        case "tif": return "tiff"
        case "htm": return "html"
        case "aif": return "aiff"
        case "heif": return "heic"
        default: return ext.lowercased()
        }
    }

    static func kind(of url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, ext != "rtfd" {
            return .other
        }
        if documentExts.contains(ext) { return .document }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }

    static func kind(of urls: [URL]) -> FileKind {
        let kinds = Set(urls.map { kind(of: $0) })
        return kinds.count == 1 ? kinds.first! : .other
    }

    static func badge(for urls: [URL]) -> String {
        let exts = Set(urls.map { norm($0.pathExtension) })
        if exts.count == 1, let e = exts.first, !e.isEmpty { return e.uppercased() }
        switch kind(of: urls) {
        case .image: return "IMAGES"
        case .pdf: return "PDF"
        case .video: return "VIDÉOS"
        case .audio: return "AUDIO"
        case .document: return "DOCS"
        case .other: return "FICHIERS"
        }
    }

    static func actions(for urls: [URL]) -> [FileAction] {
        let list: [FileAction]
        switch kind(of: urls) {
        case .image: list = imageActions()
        case .pdf: list = pdfActions(count: urls.count)
        case .video: list = videoActions()
        case .audio: list = audioActions()
        case .document: list = documentActions()
        case .other: list = [zip]
        }
        // On masque la conversion vers le format d'origine (JPG → JPG).
        return list.filter { action in
            guard let target = action.targetExt else { return true }
            return !urls.allSatisfy { norm($0.pathExtension) == target }
        }
    }

    // MARK: - Fabriques

    private static func format(_ title: String, _ ext: String, verb: String? = nil,
                               _ run: @escaping @Sendable ([URL]) async throws -> [URL]) -> FileAction {
        FileAction(title: title, symbol: nil, ring: .formats, verb: verb ?? "Conversion en \(title)",
                   targetExt: ext, run: run)
    }

    private static func tool(_ title: String, _ symbol: String, _ verb: String,
                             _ run: @escaping @Sendable ([URL]) async throws -> [URL]) -> FileAction {
        FileAction(title: title, symbol: symbol, ring: .tools, verb: verb, targetExt: nil, run: run)
    }

    static let zip = tool("ZIP", "archivebox", "Compression ZIP") { try Archive.zip($0) }

    // MARK: - Par type

    private static func imageActions() -> [FileAction] {
        var list: [FileAction] = [
            format("JPG", "jpg") { try ImageOps.convert($0, to: .jpeg, ext: "jpg") },
            format("PNG", "png") { try ImageOps.convert($0, to: .png, ext: "png") },
        ]
        if ImageOps.canWrite(.heic) {
            list.append(format("HEIC", "heic") { try ImageOps.convert($0, to: .heic, ext: "heic") })
        }
        list += [
            format("TIFF", "tiff") { try ImageOps.convert($0, to: .tiff, ext: "tiff") },
            format("GIF", "gif") { try ImageOps.convert($0, to: .gif, ext: "gif") },
            format("PDF", "pdf") { try ImageOps.toPDF($0) },
            tool("Compresser", "arrow.down.right.and.arrow.up.left", "Compression") { try ImageOps.compress($0) },
            tool("Réduire", "minus.magnifyingglass", "Réduction de moitié") { try ImageOps.resize($0, scale: 0.5) },
        ]
        if #available(macOS 14.0, *) {
            list.append(tool("Détourer", "wand.and.stars", "Détourage") { try ImageOps.removeBackground($0) })
        }
        list += [
            tool("Pivoter", "rotate.right", "Rotation") { try ImageOps.rotate($0) },
            tool("Métadonnées", "tag.slash", "Suppression des métadonnées") { try ImageOps.stripMetadata($0) },
            zip,
        ]
        return list
    }

    private static func pdfActions(count: Int) -> [FileAction] {
        var list: [FileAction] = [
            format("JPG", "jpg") { try PDFOps.toImages($0, type: .jpeg, ext: "jpg") },
            format("PNG", "png") { try PDFOps.toImages($0, type: .png, ext: "png") },
            format("DOCX", "docx") { try PDFOps.toRich($0, type: .officeOpenXML, ext: "docx") },
            format("RTF", "rtf") { try PDFOps.toRich($0, type: .rtf, ext: "rtf") },
            format("TXT", "txt") { try PDFOps.toText($0) },
            tool("Compresser", "arrow.down.right.and.arrow.up.left", "Compression") { try PDFOps.compress($0) },
        ]
        if count > 1 {
            list.append(tool("Fusionner", "doc.on.doc", "Fusion") { try PDFOps.merge($0) })
        }
        list += [
            tool("Séparer", "scissors", "Séparation des pages") { try PDFOps.split($0) },
            tool("Pivoter", "rotate.right", "Rotation") { try PDFOps.rotate($0) },
            tool("Métadonnées", "tag.slash", "Suppression des métadonnées") { try PDFOps.stripMetadata($0) },
            zip,
        ]
        return list
    }

    private static func videoActions() -> [FileAction] {
        [
            format("MP4", "mp4") { try await VideoOps.convert($0, ext: "mp4", type: .mp4) },
            format("MOV", "mov") { try await VideoOps.convert($0, ext: "mov", type: .mov) },
            format("GIF", "gif") { try await VideoOps.toGIF($0) },
            format("M4A", "m4a", verb: "Extraction de l'audio") {
                try await VideoOps.convert($0, ext: "m4a", type: .m4a, preset: AVAssetExportPresetAppleM4A)
            },
            tool("Compresser", "arrow.down.right.and.arrow.up.left", "Compression vidéo") { try await VideoOps.compress($0) },
            tool("Sans son", "speaker.slash", "Suppression du son") { try await VideoOps.mute($0) },
            tool("Image", "photo", "Capture d'image") { try await VideoOps.frame($0) },
            zip,
        ]
    }

    private static func audioActions() -> [FileAction] {
        [
            format("M4A", "m4a") { try AudioOps.convert($0, ext: "m4a", fileType: "m4af", dataFormat: "aac", bitrate: 256_000) },
            format("WAV", "wav") { try AudioOps.convert($0, ext: "wav", fileType: "WAVE", dataFormat: "LEI16") },
            format("AIFF", "aiff") { try AudioOps.convert($0, ext: "aiff", fileType: "AIFF", dataFormat: "BEI16") },
            format("FLAC", "flac") { try AudioOps.convert($0, ext: "flac", fileType: "flac", dataFormat: "flac") },
            tool("Compresser", "arrow.down.right.and.arrow.up.left", "Compression audio") {
                try AudioOps.convert($0, ext: "m4a", fileType: "m4af", dataFormat: "aac", bitrate: 128_000, suffix: " (compressé)")
            },
            zip,
        ]
    }

    private static func documentActions() -> [FileAction] {
        [
            format("PDF", "pdf") { try await DocOps.convert($0, ext: "pdf") },
            format("DOCX", "docx") { try await DocOps.convert($0, ext: "docx") },
            format("RTF", "rtf") { try await DocOps.convert($0, ext: "rtf") },
            format("TXT", "txt") { try await DocOps.convert($0, ext: "txt") },
            format("HTML", "html") { try await DocOps.convert($0, ext: "html") },
            format("ODT", "odt") { try await DocOps.convert($0, ext: "odt") },
            zip,
        ]
    }
}
