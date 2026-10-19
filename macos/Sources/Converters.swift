import AppKit
import AVFoundation
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

struct Oops: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Fichiers de sortie

enum Out {
    /// « photo.png » → « photo.jpg » dans le même dossier, sans jamais écraser (« photo 2.jpg »…).
    static func file(for src: URL, suffix: String = "", ext: String) -> URL {
        unique(dir: src.deletingLastPathComponent(),
               base: src.deletingPathExtension().lastPathComponent + suffix, ext: ext)
    }

    static func unique(dir: URL, base: String, ext: String) -> URL {
        func make(_ b: String) -> URL {
            ext.isEmpty ? dir.appendingPathComponent(b, isDirectory: true)
                        : dir.appendingPathComponent(b).appendingPathExtension(ext)
        }
        var url = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = make("\(base) \(n)")
            n += 1
        }
        return url
    }

    static func folder(for src: URL, suffix: String) throws -> URL {
        let dir = unique(dir: src.deletingLastPathComponent(),
                         base: src.deletingPathExtension().lastPathComponent + suffix, ext: "")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func size(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Ligne de commande (outils intégrés à macOS)

enum Shell {
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Oops(msg.isEmpty ? "\(URL(fileURLWithPath: executable).lastPathComponent) a échoué" : msg)
        }
    }
}

// MARK: - Images (ImageIO + Vision)

enum ImageOps {
    static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    static func canWrite(_ type: UTType) -> Bool {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return ids.contains(type.identifier)
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: return true
        default: return false
        }
    }

    /// Type d'écriture identique à la source quand c'est possible, PNG sinon (ex. WebP).
    static func sameType(_ url: URL) -> (UTType, String) {
        let ext = Catalog.norm(url.pathExtension)
        if ["jpg", "png", "heic", "tiff", "gif", "bmp"].contains(ext),
           let type = UTType(filenameExtension: ext), canWrite(type) {
            return (type, ext)
        }
        return (.png, "png")
    }

    /// Charge l'image déjà redressée (orientation EXIF appliquée).
    static func load(_ url: URL, scale: Double = 1, maxSide: Int? = nil) throws -> (image: CGImage, props: [String: Any]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw Oops("Impossible de lire \(url.lastPathComponent)")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        var side = Int(Double(max(w, h)) * scale)
        if let m = maxSide { side = min(side, m) }

        let image: CGImage?
        if side > 0 {
            let opts: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceShouldCacheImmediately as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: side,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let image else { throw Oops("Impossible de décoder \(url.lastPathComponent)") }
        return (image, props)
    }

    /// Garde EXIF/GPS/IPTC mais remet l'orientation à 1 (l'image est déjà redressée).
    static func keptMetadata(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
            if let value = props[key as String] { out[key as String] = value }
        }
        if var tiff = out[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        out[kCGImagePropertyOrientation as String] = 1
        return out
    }

    static func write(_ image: CGImage, to out: URL, type: UTType, quality: Double = 0.9,
                      metadata: [String: Any] = [:]) throws {
        let img = (type == .jpeg || type == .bmp) ? flattened(image) : image
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw Oops("Format \(type.preferredFilenameExtension?.uppercased() ?? "") non pris en charge")
        }
        var props = metadata
        props[kCGImageDestinationLossyCompressionQuality as String] = quality
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            Out.discard(out)
            throw Oops("Échec de l'écriture de \(out.lastPathComponent)")
        }
    }

    /// Pose l'image sur fond blanc (pour le JPG qui ne gère pas la transparence).
    static func flattened(_ img: CGImage) -> CGImage {
        guard hasAlpha(img) else { return img }
        var cs = img.colorSpace ?? sRGB
        if cs.model != .rgb { cs = sRGB }
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return img }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        return ctx.makeImage() ?? img
    }

    static func rotated(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        var cs = img.colorSpace ?? sRGB
        if cs.model != .rgb { cs = sRGB }
        guard let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Rotation de 90° dans le sens horaire
        ctx.translateBy(x: 0, y: CGFloat(w))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // Actions

    static func convert(_ urls: [URL], to type: UTType, ext: String) throws -> [URL] {
        try urls.map { url in
            let (img, props) = try load(url)
            let out = Out.file(for: url, ext: ext)
            try write(img, to: out, type: type, quality: 0.92, metadata: keptMetadata(props))
            return out
        }
    }

    static func toPDF(_ urls: [URL]) throws -> [URL] {
        let doc = PDFDocument()
        for url in urls {
            let (img, _) = try load(url)
            let w = CGFloat(img.width), h = CGFloat(img.height)
            let k = 842 / max(w, h)
            let ns = NSImage(cgImage: img, size: NSSize(width: w * k, height: h * k))
            guard let page = PDFPage(image: ns) else { throw Oops("Impossible d'ajouter \(url.lastPathComponent)") }
            doc.insert(page, at: doc.pageCount)
        }
        let suffix = urls.count > 1 ? " (+\(urls.count - 1))" : ""
        let out = Out.file(for: urls[0], suffix: suffix, ext: "pdf")
        guard doc.write(to: out) else { throw Oops("Impossible d'écrire le PDF") }
        return [out]
    }

    static func compress(_ urls: [URL]) throws -> [URL] {
        var outs: [URL] = []
        for url in urls {
            var loaded = try load(url, maxSide: 2560)
            let alpha = hasAlpha(loaded.image) && ["png", "gif", "tiff", "heic"].contains(Catalog.norm(url.pathExtension))
            if alpha { loaded = try load(url, maxSide: 1920) }
            let (type, ext): (UTType, String) = alpha ? (.png, "png") : (.jpeg, "jpg")
            let out = Out.file(for: url, suffix: " (compressé)", ext: ext)
            try write(loaded.image, to: out, type: type, quality: 0.65, metadata: keptMetadata(loaded.props))
            if Out.size(out) >= Out.size(url) {
                Out.discard(out)
                continue
            }
            outs.append(out)
        }
        if outs.isEmpty { throw Oops("Déjà optimisé : impossible de réduire davantage") }
        return outs
    }

    static func resize(_ urls: [URL], scale: Double) throws -> [URL] {
        try urls.map { url in
            let (img, props) = try load(url, scale: scale)
            let (type, ext) = sameType(url)
            let out = Out.file(for: url, suffix: " (réduit)", ext: ext)
            try write(img, to: out, type: type, quality: 0.9, metadata: keptMetadata(props))
            return out
        }
    }

    static func rotate(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let (img, props) = try load(url)
            guard let turned = rotated(img) else { throw Oops("Rotation impossible") }
            let (type, ext) = sameType(url)
            let out = Out.file(for: url, suffix: " (pivoté)", ext: ext)
            try write(turned, to: out, type: type, quality: 0.92, metadata: keptMetadata(props))
            return out
        }
    }

    static func stripMetadata(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let (img, _) = try load(url)
            let (type, ext) = sameType(url)
            let out = Out.file(for: url, suffix: " (sans métadonnées)", ext: ext)
            try write(img, to: out, type: type, quality: 0.92)
            return out
        }
    }

    @available(macOS 14.0, *)
    static func removeBackground(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let (img, _) = try load(url)
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: img, options: [:])
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                throw Oops("Aucun sujet détecté dans \(url.lastPathComponent)")
            }
            let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances,
                                                             from: handler, croppedToInstancesExtent: false)
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let cut = CIContext().createCGImage(ci, from: ci.extent) else {
                throw Oops("Échec du détourage")
            }
            let out = Out.file(for: url, suffix: " (détouré)", ext: "png")
            try write(cut, to: out, type: .png)
            return out
        }
    }
}

// MARK: - PDF (PDFKit)

enum PDFOps {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw Oops("Impossible d'ouvrir \(url.lastPathComponent)") }
        if doc.isLocked { throw Oops("\(url.lastPathComponent) est protégé par un mot de passe") }
        return doc
    }

    static func save(_ doc: PDFDocument, to out: URL) throws {
        guard doc.write(to: out) else { throw Oops("Impossible d'écrire \(out.lastPathComponent)") }
    }

    static func render(_ page: PDFPage, scale: CGFloat) throws -> CGImage {
        guard let ref = page.pageRef else { throw Oops("Page illisible") }
        let box = ref.getBoxRect(.mediaBox)
        let quarterTurn = (ref.rotationAngle / 90) % 2 != 0
        let wPt = quarterTurn ? box.height : box.width
        let hPt = quarterTurn ? box.width : box.height
        let w = Int(wPt * scale), h = Int(hPt * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageOps.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Oops("Rendu impossible") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(ref.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: wPt, height: hPt),
                                                rotate: 0, preserveAspectRatio: true))
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(ref)
        guard let img = ctx.makeImage() else { throw Oops("Rendu impossible") }
        return img
    }

    static func toImages(_ urls: [URL], type: UTType, ext: String) throws -> [URL] {
        var outs: [URL] = []
        for url in urls {
            let doc = try open(url)
            let multi = doc.pageCount > 1
            let folder = try multi ? Out.folder(for: url, suffix: " (\(ext.uppercased()))") : url.deletingLastPathComponent()
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let img = try render(page, scale: 2)
                let out = multi ? Out.unique(dir: folder, base: "Page \(i + 1)", ext: ext)
                                : Out.file(for: url, ext: ext)
                try ImageOps.write(img, to: out, type: type, quality: 0.9)
                if !multi { outs.append(out) }
            }
            if multi { outs.append(folder) }
        }
        return outs
    }

    static func toText(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let doc = try open(url)
            let text = doc.string ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Oops("Aucun texte dans \(url.lastPathComponent) (PDF scanné ?)")
            }
            let out = Out.file(for: url, ext: "txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            return out
        }
    }

    static func toRich(_ urls: [URL], type: NSAttributedString.DocumentType, ext: String) throws -> [URL] {
        try urls.map { url in
            let doc = try open(url)
            let all = NSMutableAttributedString()
            for i in 0..<doc.pageCount {
                guard let part = doc.page(at: i)?.attributedString else { continue }
                all.append(part)
                all.append(NSAttributedString(string: "\n\n"))
            }
            guard !all.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Oops("Aucun texte dans \(url.lastPathComponent) (PDF scanné ?)")
            }
            let data = try all.data(from: NSRange(location: 0, length: all.length),
                                    documentAttributes: [.documentType: type])
            let out = Out.file(for: url, ext: ext)
            try data.write(to: out)
            return out
        }
    }

    static func compress(_ urls: [URL]) throws -> [URL] {
        var outs: [URL] = []
        for url in urls {
            let doc = try open(url)
            let out = Out.file(for: url, suffix: " (compressé)", ext: "pdf")
            var options: [PDFDocumentWriteOption: Any] = [:]
            if #available(macOS 13.4, *) {
                options = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
            }
            let ok = doc.write(to: out, withOptions: options)
            guard ok else { throw Oops("Impossible d'écrire \(out.lastPathComponent)") }
            if Out.size(out) >= Out.size(url) {
                Out.discard(out)
                continue
            }
            outs.append(out)
        }
        if outs.isEmpty { throw Oops("Ce PDF est déjà optimisé") }
        return outs
    }

    static func merge(_ urls: [URL]) throws -> [URL] {
        let merged = PDFDocument()
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in sorted {
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        let out = Out.unique(dir: sorted[0].deletingLastPathComponent(), base: "Fusion", ext: "pdf")
        try save(merged, to: out)
        return [out]
    }

    static func split(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let doc = try open(url)
            guard doc.pageCount > 1 else { throw Oops("\(url.lastPathComponent) n'a qu'une seule page") }
            let folder = try Out.folder(for: url, suffix: " (pages)")
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                try save(single, to: folder.appendingPathComponent("Page \(i + 1).pdf"))
            }
            return folder
        }
    }

    static func rotate(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) { page.rotation = (page.rotation + 90) % 360 }
            }
            let out = Out.file(for: url, suffix: " (pivoté)", ext: "pdf")
            try save(doc, to: out)
            return out
        }
    }

    static func stripMetadata(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let doc = try open(url)
            doc.documentAttributes = [:]
            let out = Out.file(for: url, suffix: " (sans métadonnées)", ext: "pdf")
            try save(doc, to: out)
            return out
        }
    }
}

// MARK: - Vidéo (AVFoundation)

enum VideoOps {
    static func export(_ asset: AVAsset, preset: String, to out: URL, type: AVFileType) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw Oops("Export impossible pour ce fichier")
        }
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        if session.status != .completed {
            Out.discard(out)
            throw Oops(session.error?.localizedDescription ?? "Échec de l'export")
        }
    }

    static func convert(_ urls: [URL], ext: String, type: AVFileType,
                        preset: String = AVAssetExportPresetHighestQuality) async throws -> [URL] {
        var outs: [URL] = []
        for url in urls {
            let out = Out.file(for: url, ext: ext)
            try await export(AVURLAsset(url: url), preset: preset, to: out, type: type)
            outs.append(out)
        }
        return outs
    }

    static func compress(_ urls: [URL]) async throws -> [URL] {
        var outs: [URL] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let out = Out.file(for: url, suffix: " (compressé)", ext: "mp4")
            do {
                try await export(asset, preset: AVAssetExportPresetHEVC1920x1080, to: out, type: .mp4)
            } catch {
                try await export(asset, preset: AVAssetExportPreset1280x720, to: out, type: .mp4)
            }
            if Out.size(out) >= Out.size(url) {
                Out.discard(out)
                continue
            }
            outs.append(out)
        }
        if outs.isEmpty { throw Oops("Vidéo déjà optimisée") }
        return outs
    }

    static func mute(_ urls: [URL]) async throws -> [URL] {
        var outs: [URL] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            let composition = AVMutableComposition()
            guard let source = tracks.first,
                  let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw Oops("Aucune piste vidéo") }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            track.preferredTransform = try await source.load(.preferredTransform)
            let out = Out.file(for: url, suffix: " (sans son)", ext: "mov")
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: out, type: .mov)
            outs.append(out)
        }
        return outs
    }

    static func frame(_ urls: [URL]) async throws -> [URL] {
        var outs: [URL] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let seconds = try await asset.load(.duration).seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let time = CMTime(seconds: min(1, max(0, seconds / 2)), preferredTimescale: 600)
            let img = try generator.copyCGImage(at: time, actualTime: nil)
            let out = Out.file(for: url, suffix: " (image)", ext: "jpg")
            try ImageOps.write(img, to: out, type: .jpeg, quality: 0.92)
            outs.append(out)
        }
        return outs
    }

    static func toGIF(_ urls: [URL]) async throws -> [URL] {
        var outs: [URL] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let seconds = try await asset.load(.duration).seconds
            let fps = 12.0
            let length = min(seconds, 20)          // 20 s maximum
            let count = max(1, Int(length * fps))

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 540, height: 540)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 24)

            let out = Out.file(for: url, ext: "gif")
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
                throw Oops("Impossible de créer le GIF")
            }
            let fileProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
            CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
            let frameProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 1.0 / fps]]

            for i in 0..<count {
                let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
                guard let img = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
                CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
            }
            guard CGImageDestinationFinalize(dest) else {
                Out.discard(out)
                throw Oops("Échec de la création du GIF")
            }
            outs.append(out)
        }
        return outs
    }
}

// MARK: - Audio (afconvert, fourni avec macOS)

enum AudioOps {
    static func convert(_ urls: [URL], ext: String, fileType: String, dataFormat: String,
                        bitrate: Int? = nil, suffix: String = "") throws -> [URL] {
        try urls.map { url in
            let out = Out.file(for: url, suffix: suffix, ext: ext)
            var args = ["-f", fileType, "-d", dataFormat]
            if let bitrate { args += ["-b", String(bitrate)] }
            args += [url.path, out.path]
            do {
                try Shell.run("/usr/bin/afconvert", args)
            } catch {
                Out.discard(out)
                throw error
            }
            return out
        }
    }
}

// MARK: - Archives

enum Archive {
    static func zip(_ urls: [URL]) throws -> [URL] {
        if urls.count == 1 {
            let url = urls[0]
            let out = Out.file(for: url, ext: "zip")
            try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, out.path])
            return [out]
        }
        let dir = urls[0].deletingLastPathComponent()
        let out = Out.unique(dir: dir, base: "Archive", ext: "zip")
        let sameFolder = urls.allSatisfy { $0.deletingLastPathComponent().path == dir.path }
        if sameFolder {
            try Shell.run("/usr/bin/zip", ["-r", "-q", "-X", out.path] + urls.map { $0.lastPathComponent }, cwd: dir)
        } else {
            try Shell.run("/usr/bin/zip", ["-r", "-q", "-X", "-j", out.path] + urls.map { $0.path })
        }
        return [out]
    }
}

// MARK: - Documents texte (NSAttributedString — doit tourner sur le fil principal)

@MainActor
enum DocOps {
    static func load(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "txt", "text"].contains(ext) {
            let text = try (try? String(contentsOf: url, encoding: .utf8))
                ?? String(contentsOf: url, encoding: .isoLatin1)
            let font = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    static func convert(_ urls: [URL], ext: String) throws -> [URL] {
        let types: [String: NSAttributedString.DocumentType] = [
            "docx": .officeOpenXML, "rtf": .rtf, "html": .html, "odt": .openDocument, "doc": .docFormat,
        ]
        var outs: [URL] = []
        for url in urls {
            let attr = try load(url)
            let out = Out.file(for: url, ext: ext)
            switch ext {
            case "pdf":
                try printPDF(attr, to: out)
            case "txt":
                try attr.string.write(to: out, atomically: true, encoding: .utf8)
            default:
                guard let type = types[ext] else { throw Oops("Format \(ext.uppercased()) non pris en charge") }
                let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                         documentAttributes: [.documentType: type])
                try data.write(to: out)
            }
            outs.append(out)
        }
        return outs
    }

    static func printPDF(_ attr: NSAttributedString, to out: URL) throws {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: out])
        info.jobDisposition = .save
        info.paperSize = NSSize(width: 595.28, height: 841.89)   // A4
        info.leftMargin = 56
        info.rightMargin = 56
        info.topMargin = 56
        info.bottomMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.appearance = NSAppearance(named: .aqua)
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textContainerInset = .zero
        textView.textStorage?.setAttributedString(attr)
        if let layout = textView.layoutManager, let container = textView.textContainer {
            layout.ensureLayout(for: container)
            let height = layout.usedRect(for: container).height
            textView.setFrameSize(NSSize(width: width, height: max(height, 10)))
        }

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: out.path) else {
            throw Oops("Échec de la création du PDF")
        }
    }
}
