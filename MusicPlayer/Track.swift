import Foundation
import AVFoundation
import UIKit

struct Track: Identifiable, Equatable {
    let id: URL
    var url: URL { id }
    let title: String
    let artist: String
    let duration: TimeInterval
    let artwork: UIImage?

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }

    /// 讀取音樂檔的標題、歌手、封面與長度
    static func load(from url: URL) async -> Track {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "未知歌手"
        var artwork: UIImage?
        var duration: TimeInterval = 0

        if let result = try? await asset.load(.commonMetadata, .duration) {
            let (metadata, time) = result
            duration = time.seconds.isFinite ? time.seconds : 0
            for item in metadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
                case .commonKeyArtist:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { artist = v }
                case .commonKeyArtwork:
                    if let d = try? await item.load(.dataValue), let img = UIImage(data: d) { artwork = img }
                default:
                    break
                }
            }
        }
        return Track(id: url, title: title, artist: artist, duration: duration, artwork: artwork)
    }
}

enum RepeatMode: CaseIterable {
    case off, all, one

    var icon: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

func formatTime(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
}
