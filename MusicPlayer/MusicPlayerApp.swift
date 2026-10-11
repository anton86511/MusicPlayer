import SwiftUI

@main
struct MusicPlayerApp: App {
    @StateObject private var player = PlayerManager()
    @StateObject private var lyrics = LyricsStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(lyrics)
                .tint(.pink)
        }
        .onChange(of: scenePhase) { phase in
            // 從「檔案」App 放入新歌後，回到 App 時自動重新整理
            if phase == .active {
                Task { await player.reloadLibrary() }
            }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("音樂庫", systemImage: "music.note.list") }
            YouTubeView()
                .tabItem { Label("YouTube", systemImage: "play.rectangle.fill") }
        }
    }
}
