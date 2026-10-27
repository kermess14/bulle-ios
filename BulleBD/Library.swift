import SwiftUI
import CryptoKit

/// Un dossier ou un album de la bibliothèque (le dossier Documents de l'appli et ses sous-dossiers).
struct LibraryItem: Identifiable, Hashable {
    enum Kind { case folder, book }
    let url: URL
    let kind: Kind
    var id: String { url.path }
    var name: String { kind == .book ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }
}

/// Où on en est dans un album (gardé sur l'appareil).
struct ReadingProgress: Codable, Equatable {
    var page: Int
    var count: Int
    var done: Bool
    var updated: Date
}

@MainActor
final class Library: ObservableObject {
    let root: URL
    /// Change à chaque ajout, suppression ou lecture : les vues se redessinent.
    @Published private(set) var version = 0
    @Published private(set) var progressByBook: [String: ReadingProgress] = [:]

    private let fm = FileManager.default
    private let progressKey = "bulle.progress"
    private let coverMemory = NSCache<NSString, UIImage>()
    private let coverDir: URL
    nonisolated private static let coverQueue = DispatchQueue(label: "bulle.covers", qos: .utility, attributes: .concurrent)
    nonisolated private static let coverSlots = DispatchSemaphore(value: 2)   // deux couvertures fabriquées à la fois

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        coverDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
        if let d = UserDefaults.standard.data(forKey: progressKey),
           let p = try? JSONDecoder().decode([String: ReadingProgress].self, from: d) {
            progressByBook = p
        }
        coverMemory.countLimit = 300
    }

    // MARK: contenu des dossiers

    func items(in folder: URL) -> [LibraryItem] {
        _ = version
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [LibraryItem] = []
        for u in urls {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if u.lastPathComponent == "Inbox" && folder == root { continue }   // dossier technique d'iOS
                out.append(LibraryItem(url: u, kind: .folder))
            } else if PageSources.comicExtensions.contains(u.pathExtension.lowercased()) {
                out.append(LibraryItem(url: u, kind: .book))
            }
        }
        // les dossiers d'abord, puis les albums, dans l'ordre naturel (« Tome 2 » avant « Tome 10 »)
        return out.sorted {
            if $0.kind != $1.kind { return $0.kind == .folder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Le premier album d'un dossier (ou de ses sous-dossiers) : sa couverture sert de pochette au dossier.
    func firstBook(in folder: URL) -> URL? {
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var books: [URL] = []
        for case let u as URL in e where PageSources.comicExtensions.contains(u.pathExtension.lowercased()) {
            books.append(u)
            if books.count > 200 { break }
        }
        return books.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.first
    }

    func bookCount(in folder: URL) -> Int {
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        var n = 0
        for case let u as URL in e where PageSources.comicExtensions.contains(u.pathExtension.lowercased()) { n += 1 }
        return n
    }

    // MARK: couvertures

    private func coverKey(_ url: URL) -> String {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let stamp = "\(url.path)|\((attrs?[.size] as? NSNumber)?.int64Value ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func cover(for book: URL) async -> UIImage? {
        let key = coverKey(book)
        if let m = coverMemory.object(forKey: key as NSString) { return m }
        let file = coverDir.appendingPathComponent(key + ".jpg")
        let img: UIImage? = await withCheckedContinuation { cont in
            Self.coverQueue.async {
                if let d = try? Data(contentsOf: file), let i = UIImage(data: d) { cont.resume(returning: i); return }
                Self.coverSlots.wait(); defer { Self.coverSlots.signal() }
                guard let src = PageSources.open(book), src.pageCount > 0, let i = src.image(at: 0, maxPixel: 600) else {
                    cont.resume(returning: nil); return
                }
                if let jpg = i.jpegData(compressionQuality: 0.82) { try? jpg.write(to: file, options: .atomic) }
                cont.resume(returning: i)
            }
        }
        if let img { coverMemory.setObject(img, forKey: key as NSString) }
        return img
    }

    // MARK: lecture

    private func relKey(_ url: URL) -> String {
        let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
        return p.hasPrefix(r) ? String(p.dropFirst(r.count)) : p
    }

    func progress(for book: URL) -> ReadingProgress? { progressByBook[relKey(book)] }

    func saveProgress(_ book: URL, page: Int, count: Int) {
        // arrivé à la dernière page : lu ; un album lu le reste quand on le relit (jusqu'à « Marquer non lu »)
        let done = (count > 0 && page >= count - 1) || (progressByBook[relKey(book)]?.done ?? false)
        progressByBook[relKey(book)] = ReadingProgress(page: page, count: count, done: done, updated: Date())
        persist()
    }

    func setRead(_ book: URL, _ read: Bool) {
        if read {
            let n = progress(for: book)?.count ?? PageSources.open(book)?.pageCount ?? 1
            progressByBook[relKey(book)] = ReadingProgress(page: max(0, n - 1), count: n, done: true, updated: Date())
        } else {
            progressByBook[relKey(book)] = nil
        }
        persist()
    }

    /// Tous les albums d'un dossier (sous-dossiers compris) marqués lus ou non lus.
    func setFolderRead(_ folder: URL, _ read: Bool) {
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for case let u as URL in e where PageSources.comicExtensions.contains(u.pathExtension.lowercased()) {
            if read {
                let n = progress(for: u)?.count ?? 1
                progressByBook[relKey(u)] = ReadingProgress(page: max(0, n - 1), count: n, done: true, updated: Date())
            } else {
                progressByBook[relKey(u)] = nil
            }
        }
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(progressByBook) { UserDefaults.standard.set(d, forKey: progressKey) }
        version += 1
    }

    // MARK: ajout, suppression

    /// Copie des fichiers (ou dossiers) choisis ailleurs (iCloud, clé USB, NAS…) dans la bibliothèque de l'appli.
    func importFiles(_ urls: [URL], into folder: URL) {
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            var dest = folder.appendingPathComponent(u.lastPathComponent)
            if u.standardizedFileURL.path == dest.standardizedFileURL.path { continue }
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
                dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
                n += 1
            }
            // un fichier reçu dans « Inbox » (Ouvrir dans…) est déplacé, les autres copiés
            if u.path.contains("/Inbox/") { try? fm.moveItem(at: u, to: dest) } else { try? fm.copyItem(at: u, to: dest) }
        }
        version += 1
    }

    func delete(_ item: LibraryItem) {
        try? fm.removeItem(at: item.url)
        version += 1
    }

    func refresh() { version += 1 }
}
