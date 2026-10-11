import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var player: PlayerManager
    @State private var showImporter = false
    @State private var showNowPlaying = false
    @State private var searchText = ""

    private var filtered: [Track] {
        guard !searchText.isEmpty else { return player.tracks }
        return player.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if player.tracks.isEmpty {
                    EmptyLibraryView { showImporter = true }
                } else {
                    List {
                        ForEach(filtered) { track in
                            TrackRow(track: track,
                                     isCurrent: player.currentTrack == track,
                                     isPlaying: player.isPlaying)
                                .contentShape(Rectangle())
                                .onTapGesture { player.play(track: track) }
                        }
                        .onDelete { offsets in
                            let items = offsets.map { filtered[$0] }
                            items.forEach { player.delete($0) }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "搜尋歌曲或歌手")
                    .refreshable { await player.reloadLibrary() }
                }
            }
            .navigationTitle("我的音樂")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.currentTrack != nil {
                    MiniPlayerView()
                        .contentShape(Rectangle())
                        .onTapGesture { showNowPlaying = true }
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { player.importFiles(urls) }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView().environmentObject(player)
        }
        .alert("發生錯誤", isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "")
        }
    }
}

struct EmptyLibraryView: View {
    let onImport: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 64))
                .foregroundStyle(.pink)
            Text("還沒有任何歌曲").font(.title3.bold())
            Text("點下方按鈕從「檔案」匯入音樂，\n支援 MP3、M4A、WAV、FLAC 等格式。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onImport) {
                Label("匯入音樂", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(image: track.artwork, size: 48, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.pink : Color.primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .foregroundStyle(.pink)
            } else {
                Text(formatTime(track.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ArtworkView: View {
    let image: UIImage?
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.pink, .purple],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerManager

    var body: some View {
        if let t = player.currentTrack {
            VStack(spacing: 0) {
                ProgressView(value: min(player.currentTime, max(player.duration, 1)),
                             total: max(player.duration, 1))
                    .tint(.pink)
                HStack(spacing: 12) {
                    ArtworkView(image: t.artwork, size: 44, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .frame(width: 36, height: 40)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
        }
    }
}
