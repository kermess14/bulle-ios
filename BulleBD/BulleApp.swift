import SwiftUI

/// Bulle pour iPad et iPhone : lit les BD (CBZ, PDF) rangées dans l'appli, sans serveur ni compte.
/// Les fichiers vivent dans le dossier Documents de l'appli, visible dans l'app Fichiers (« Sur mon iPad › Bulle ») :
/// on y dépose ses albums, ou on les ajoute avec le bouton « + » (copie depuis iCloud, une clé USB, un NAS…).
@main
struct BulleApp: App {
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                FolderView(folder: library.root)
                    .navigationDestination(for: LibraryItem.self) { FolderView(folder: $0.url) }
            }
            .environmentObject(library)
            .preferredColorScheme(.dark)
            .tint(Color(red: 1.0, green: 0.78, blue: 0.2))
            .onOpenURL { url in
                // « Ouvrir dans Bulle » depuis une autre appli : copié dans le dossier « Ajoutés »
                library.importFiles([url], into: library.root.appendingPathComponent("Ajoutés", isDirectory: true))
            }
        }
    }
}
