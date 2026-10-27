import UIKit
import PDFKit
import ImageIO
import ZIPFoundation

/// Les pages d'un album, quel que soit son format. Chaque image est réduite à la taille demandée dès le décodage
/// (ImageIO) : une page de 3 000 px n'occupe pas toute la mémoire de l'iPad.
protocol PageSource: AnyObject, Sendable {
    var pageCount: Int { get }
    func image(at index: Int, maxPixel: CGFloat) -> UIImage?
}

enum PageSources {
    static let comicExtensions: Set<String> = ["cbz", "zip", "pdf"]

    static func open(_ url: URL) -> PageSource? {
        switch url.pathExtension.lowercased() {
        case "pdf": return PDFSource(url: url)
        case "cbz", "zip": return try? ZipSource(url: url)
        default: return nil
        }
    }

    /// Image réduite (côté le plus long ≤ maxPixel) directement à partir des octets du fichier.
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxPixel)),
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

/// CBZ (zip) : les images dans l'ordre naturel des noms (« 2.jpg » avant « 10.jpg »), dossiers compris.
final class ZipSource: PageSource, @unchecked Sendable {   // (accès protégé par le verrou)
    private let archive: Archive
    private let entries: [Entry]
    private let lock = NSLock()   // une archive zip ne se lit pas depuis deux fils à la fois
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "bmp", "tif", "tiff", "avif"]

    init(url: URL) throws {
        archive = try Archive(url: url, accessMode: .read)
        entries = archive.filter { entry in
            guard entry.type == .file else { return false }
            let name = (entry.path as NSString).lastPathComponent
            if name.hasPrefix(".") || entry.path.contains("__MACOSX") { return false }
            return Self.imageExtensions.contains((name as NSString).pathExtension.lowercased())
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var pageCount: Int { entries.count }

    func data(at index: Int) -> Data? {
        guard entries.indices.contains(index) else { return nil }
        lock.lock(); defer { lock.unlock() }
        var out = Data()
        do {
            _ = try archive.extract(entries[index], skipCRC32: true) { chunk in out.append(chunk) }
        } catch { return nil }
        return out
    }

    func image(at index: Int, maxPixel: CGFloat) -> UIImage? {
        guard let d = data(at: index) else { return nil }
        return PageSources.downsample(d, maxPixel: maxPixel)
    }
}

/// PDF : chaque page dessinée à la taille demandée.
final class PDFSource: PageSource, @unchecked Sendable {
    private let doc: PDFDocument?
    private let lock = NSLock()

    init(url: URL) { doc = PDFDocument(url: url) }

    var pageCount: Int { doc?.pageCount ?? 0 }

    func image(at index: Int, maxPixel: CGFloat) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let page = doc?.page(at: index) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let k = maxPixel / max(box.width, box.height)
        let size = CGSize(width: box.width * k, height: box.height * k)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: k, y: -k)
            ctx.cgContext.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }
}
