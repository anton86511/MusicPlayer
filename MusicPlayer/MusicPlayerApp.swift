import SwiftUI

@main
struct MusicPlayerApp: App {
    @StateObject private var player = PlayerManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
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
