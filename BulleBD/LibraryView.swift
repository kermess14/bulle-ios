import SwiftUI
import UniformTypeIdentifiers

/// Un dossier de la bibliothèque : ses sous-dossiers (séries) puis ses albums, en pochettes.
struct FolderView: View {
    @EnvironmentObject private var library: Library
    let folder: URL
    @State private var importing = false
    @State private var reading: LibraryItem?
    @State private var toDelete: LibraryItem?

    private var isRoot: Bool { folder.standardizedFileURL == library.root.standardizedFileURL }
    private static let types: [UTType] = [.zip, .pdf, .folder] + [UTType(filenameExtension: "cbz")].compactMap { $0 }

    var body: some View {
        let items = library.items(in: folder)
        ScrollView {
            if items.isEmpty {
                EmptyLibraryView(isRoot: isRoot) { importing = true }
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 18)], alignment: .leading, spacing: 24) {
                    ForEach(items) { item in
                        cell(item)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(isRoot ? "Bulle" : folder.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Label("Ajouter des albums", systemImage: "plus") }
            }
        }
        .refreshable { library.refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls, into: folder) }
        }
        .fullScreenCover(item: $reading) { item in
            ReaderScreen(book: item.url).environmentObject(library)
        }
        .confirmationDialog("Supprimer de l'appli ?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible, presenting: toDelete) { item in
            Button("Supprimer « \(item.name) »", role: .destructive) { library.delete(item) }
        } message: { item in
            Text(item.kind == .folder ? "Le dossier et tous ses albums sont effacés de l'iPad (pas l'original, s'il vient d'ailleurs)."
                                      : "Le fichier est effacé de l'iPad (pas l'original, s'il vient d'ailleurs).")
        }
    }

    @ViewBuilder private func cell(_ item: LibraryItem) -> some View {
        switch item.kind {
        case .folder:
            NavigationLink(value: item) { ItemCell(item: item) }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { library.setFolderRead(item.url, true) } label: { Label("Marquer la série comme lue", systemImage: "checkmark.circle") }
                    Button { library.setFolderRead(item.url, false) } label: { Label("Marquer la série comme non lue", systemImage: "circle") }
                    Button(role: .destructive) { toDelete = item } label: { Label("Supprimer", systemImage: "trash") }
                }
        case .book:
            Button { reading = item } label: { ItemCell(item: item) }
                .buttonStyle(.plain)
                .contextMenu {
                    let done = library.progress(for: item.url)?.done ?? false
                    if !done { Button { library.setRead(item.url, true) } label: { Label("Marquer comme lu", systemImage: "checkmark.circle") } }
                    if library.progress(for: item.url) != nil { Button { library.setRead(item.url, false) } label: { Label("Marquer comme non lu", systemImage: "circle") } }
                    Button(role: .destructive) { toDelete = item } label: { Label("Supprimer", systemImage: "trash") }
                }
        }
    }
}

/// Une pochette : la couverture (celle du premier album pour un dossier), le titre, où on en est.
struct ItemCell: View {
    @EnvironmentObject private var library: Library
    let item: LibraryItem
    @State private var image: UIImage?
    @State private var count = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color(white: 0.15)
                .aspectRatio(0.7, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: item.kind == .folder ? "folder" : "book.closed")
                            .font(.system(size: 34)).foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topTrailing) { badge.padding(6) }
                .overlay(alignment: .bottom) { progressBar }
                .shadow(color: .black.opacity(0.5), radius: 6, x: 2, y: 4)
            Text(item.name)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
        .task(id: item.id) {
            if item.kind == .folder { count = library.bookCount(in: item.url) }
            let book = item.kind == .book ? item.url : library.firstBook(in: item.url)
            if let book { image = await library.cover(for: book) }
        }
    }

    @ViewBuilder private var badge: some View {
        if item.kind == .folder {
            Label("\(count)", systemImage: "folder.fill")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
        } else if library.progress(for: item.url)?.done == true {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3).foregroundStyle(.white, .green)
        }
    }

    @ViewBuilder private var progressBar: some View {
        if item.kind == .book, let p = library.progress(for: item.url), !p.done, p.count > 1 {
            GeometryReader { g in
                Rectangle().fill(Color.accentColor)
                    .frame(width: g.size.width * CGFloat(p.page + 1) / CGFloat(p.count), height: 4)
            }
            .frame(height: 4)
        }
    }
}

struct EmptyLibraryView: View {
    let isRoot: Bool
    let add: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical").font(.system(size: 54)).foregroundStyle(.secondary)
            Text(isRoot ? "Aucun album pour l'instant" : "Dossier vide").font(.title3.weight(.semibold))
            Text("Ajoutez des albums (CBZ, PDF) avec le bouton +, depuis iCloud, une clé USB ou votre NAS. "
                 + "Vous pouvez aussi les déposer dans l'app Fichiers, dans « Sur mon iPad › Bulle » : les dossiers deviennent des séries.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Button(action: add) { Label("Ajouter des albums", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}
