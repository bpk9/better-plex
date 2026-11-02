import SwiftUI

let canvas = Color(red: 0.035, green: 0.043, blue: 0.055)
let panel = Color(red: 0.075, green: 0.086, blue: 0.105)
let accent = Color(red: 1, green: 0.73, blue: 0.22)

@main struct BetterPlexApp: App {
    @UIApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = LibraryStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(library)
                .preferredColorScheme(.dark).tint(accent)
                .task { library.resumeSignIn() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { library.resumeSignIn(); PlaybackHistory.shared.sync() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: LibraryStore
    @ObservedObject var downloads = Downloads.shared
    var body: some View {
        TabView {
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "rectangle.stack.fill") }
            NavigationStack { DownloadsView() }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                .badge(downloads.activeCount)
            NavigationStack { AccountView() }
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .task(id: library.server?.id) { await library.reloadSections(); PlaybackHistory.shared.sync() }
        .task {
            while !Task.isCancelled {
                PlaybackHistory.shared.sync()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .alert("Storage", isPresented: Binding(get: { downloads.storageError != nil }, set: { if !$0 { downloads.storageError = nil } })) {
            Button("OK") { downloads.storageError = nil }
        } message: { Text(downloads.storageError ?? "") }
    }
}
