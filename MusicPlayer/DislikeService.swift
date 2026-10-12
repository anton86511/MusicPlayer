import Foundation

/// 倒讚數資料來自 Return YouTube Dislike 公開 API（https://returnyoutubedislike.com）
struct DislikeInfo: Equatable {
    let videoID: String
    let likes: Int?
    let dislikes: Int?

    /// 好評率 0...1
    var ratio: Double? {
        guard let l = likes, let d = dislikes, l + d > 0 else { return nil }
        return Double(l) / Double(l + d)
    }
}

actor DislikeService {
    static let shared = DislikeService()

    private struct Raw: Decodable {
        let likes: Int?
        let dislikes: Int?
    }

    private var cache: [String: DislikeInfo] = [:]
    private var backoffUntil: Date?

    func fetch(videoID: String) async -> DislikeInfo? {
        if let c = cache[videoID] { return c }
        // 遇到 429（請求太頻繁）時先暫停一陣子
        if let until = backoffUntil, until > Date() { return nil }
        guard let url = URL(string: "https://returnyoutubedislikeapi.com/votes?videoId=\(videoID)") else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("MusicPlayer iOS (https://github.com/anton86511/MusicPlayer)", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 429 {
            backoffUntil = Date().addingTimeInterval(60)
            return nil
        }
        guard http.statusCode == 200,
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }

        let info = DislikeInfo(videoID: videoID, likes: raw.likes, dislikes: raw.dislikes)
        cache[videoID] = info
        return info
    }

    /// 從網址取出影片 ID（支援 watch、shorts、live、embed）
    nonisolated static func videoID(from url: URL?) -> String? {
        guard let url, let host = url.host?.lowercased(), host.hasSuffix("youtube.com") else { return nil }
        var candidate: String?
        if url.path == "/watch" {
            candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "v" }?.value
        } else {
            for prefix in ["/shorts/", "/live/", "/embed/"] where url.path.hasPrefix(prefix) {
                candidate = String(url.path.dropFirst(prefix.count)).components(separatedBy: "/").first
            }
        }
        guard let id = candidate,
              id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return nil }
        return id
    }
}
