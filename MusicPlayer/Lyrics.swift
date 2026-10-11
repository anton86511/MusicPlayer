import Foundation
import SwiftUI

// MARK: - 資料模型

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String
}

/// LRCLIB（免費開放歌詞資料庫）的回傳格式
struct LrcResult: Codable, Identifiable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    var hasSynced: Bool { !(syncedLyrics ?? "").isEmpty }
}

// MARK: - 線上搜尋

enum LyricsService {
    private static let base = "https://lrclib.net/api"

    static func search(query: String? = nil, track: String? = nil, artist: String? = nil) async throws -> [LrcResult] {
        guard var c = URLComponents(string: base + "/search") else { return [] }
        var items: [URLQueryItem] = []
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let track, !track.isEmpty { items.append(URLQueryItem(name: "track_name", value: track)) }
        if let artist, !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        guard !items.isEmpty else { return [] }
        c.queryItems = items
        guard let url = c.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("MusicPlayer iOS (https://github.com/anton86511/MusicPlayer)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([LrcResult].self, from: data)
    }

    /// 依歌名、歌手、長度自動挑選最符合的歌詞
    static func bestMatch(for track: Track) async -> LrcResult? {
        let title = track.title
        let artist: String? = track.artist == "未知歌手" ? nil : track.artist

        var results = (try? await search(track: title, artist: artist)) ?? []
        if results.isEmpty {
            let q = [artist, title].compactMap { $0 }.joined(separator: " ")
            results = (try? await search(query: q)) ?? []
        }
        if results.isEmpty, artist != nil {
            results = (try? await search(query: title)) ?? []
        }

        func score(_ r: LrcResult) -> Double {
            var s = 0.0
            if r.hasSynced { s += 100 } else if !(r.plainLyrics ?? "").isEmpty { s += 50 }
            if let d = r.duration, track.duration > 0 {
                s -= min(abs(d - track.duration), 60)
            }
            return s
        }
        return results.max { score($0) < score($1) }
    }

    /// 解析 LRC 格式：[mm:ss.xx] 歌詞
    static func parseLRC(_ text: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#) else { return [] }
        var pairs: [(TimeInterval, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let lyric = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let secText = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")
                let seconds = Double(secText) ?? 0
                pairs.append((minutes * 60 + seconds, lyric))
            }
        }
        return pairs
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}

// MARK: - 歌詞狀態（含快取）

@MainActor
final class LyricsStore: ObservableObject {
    enum State { case idle, loading, loaded, notFound }

    @Published private(set) var state: State = .idle
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plain: String?
    @Published private(set) var source: String?

    private var loadedFor: URL?

    private var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheURL(for track: Track) -> URL {
        cacheDir.appendingPathComponent(track.fileName + ".json")
    }

    func load(for track: Track) async {
        if loadedFor == track.url, state == .loaded || state == .loading { return }
        loadedFor = track.url
        state = .loading
        lines = []
        plain = nil
        source = nil

        if let data = try? Data(contentsOf: cacheURL(for: track)),
           let cached = try? JSONDecoder().decode(LrcResult.self, from: data) {
            apply(cached, for: track)
            return
        }

        let result = await LyricsService.bestMatch(for: track)
        guard loadedFor == track.url else { return }   // 使用者已經切歌
        if let result {
            save(result, for: track)
            apply(result, for: track)
        } else {
            state = .notFound
        }
    }

    /// 使用者手動選擇的歌詞
    func use(_ result: LrcResult, for track: Track) {
        save(result, for: track)
        loadedFor = track.url
        apply(result, for: track)
    }

    private func save(_ result: LrcResult, for track: Track) {
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: cacheURL(for: track))
        }
    }

    private func apply(_ r: LrcResult, for track: Track) {
        guard loadedFor == track.url else { return }
        lines = r.syncedLyrics.map(LyricsService.parseLRC) ?? []
        plain = r.plainLyrics
        source = [r.artistName, r.trackName].compactMap { $0 }.joined(separator: " - ")
        if r.instrumental == true && lines.isEmpty {
            plain = "♪ 純音樂，沒有歌詞 ♪"
        }
        state = (lines.isEmpty && (plain ?? "").isEmpty) ? .notFound : .loaded
    }
}

// MARK: - 歌詞畫面

struct LyricsView: View {
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var lyrics: LyricsStore
    @State private var showSearch = false

    private var currentIndex: Int? {
        lyrics.lines.lastIndex { $0.time <= player.currentTime + 0.3 }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch lyrics.state {
            case .idle, .loading:
                Spacer()
                ProgressView("正在搜尋歌詞…")
                Spacer()
            case .notFound:
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("找不到這首歌的歌詞").font(.headline)
                    Button("手動搜尋歌詞") { showSearch = true }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
            case .loaded:
                if lyrics.lines.isEmpty {
                    ScrollView {
                        Text(lyrics.plain ?? "")
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .padding(24)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    syncedView
                }
                HStack {
                    if let s = lyrics.source, !s.isEmpty {
                        Text("來源：\(s)").lineLimit(1)
                    }
                    Spacer()
                    Button("換一個版本") { showSearch = true }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSearch) {
            LyricsSearchView()
                .environmentObject(player)
                .environmentObject(lyrics)
        }
    }

    private var syncedView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 80)
                    ForEach(lyrics.lines) { line in
                        let active = line.id == currentIndex
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title3.bold())
                            .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.55))
                            .scaleEffect(active ? 1.0 : 0.95, anchor: .leading)
                            .animation(.easeOut(duration: 0.25), value: active)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: line.time) }
                            .id(line.id)
                    }
                    Color.clear.frame(height: 160)
                }
                .padding(.horizontal, 28)
            }
            .onChange(of: currentIndex) { idx in
                guard let idx else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
            .onAppear {
                if let idx = currentIndex { proxy.scrollTo(idx, anchor: .center) }
            }
        }
    }
}

struct LyricsSearchView: View {
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var lyrics: LyricsStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LrcResult] = []
    @State private var searching = false
    @State private var searched = false

    var body: some View {
        NavigationStack {
            List(results) { r in
                Button {
                    if let t = player.currentTrack { lyrics.use(r, for: t) }
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.trackName ?? "未知歌名").font(.headline)
                        Text([r.artistName, r.albumName].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(r.hasSynced ? "同步歌詞" : "純文字")
                                .foregroundStyle(r.hasSynced ? Color.pink : Color.secondary)
                            if let d = r.duration { Text(formatTime(d)).foregroundStyle(.secondary) }
                        }
                        .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay {
                if searching {
                    ProgressView()
                } else if results.isEmpty {
                    Text(searched ? "沒有找到結果，換個關鍵字試試" : "輸入歌名或歌手搜尋")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "歌名、歌手")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationTitle("搜尋歌詞")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                guard query.isEmpty, let t = player.currentTrack else { return }
                query = t.artist == "未知歌手" ? t.title : "\(t.artist) \(t.title)"
                Task { await search() }
            }
        }
    }

    private func search() async {
        searching = true
        results = (try? await LyricsService.search(query: query)) ?? []
        searching = false
        searched = true
    }
}
