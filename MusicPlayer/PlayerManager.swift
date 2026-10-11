import Foundation
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class PlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var isShuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "mp4"]

    /// 音樂存在 App 的「文件」資料夾，可在「檔案」App 中看到
    private var musicFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var currentIndex: Int? {
        guard let c = currentTrack else { return nil }
        return tracks.firstIndex(of: c)
    }

    override init() {
        super.init()
        configureAudioSession()
        configureRemoteCommands()
        Task { await reloadLibrary() }
    }

    // MARK: - 音樂庫

    func reloadLibrary() async {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: musicFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let audioURLs = urls.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }

        var loaded: [Track] = []
        for url in audioURLs {
            loaded.append(await Track.load(from: url))
        }
        loaded.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        tracks = loaded
    }

    func importFiles(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var dest = musicFolder.appendingPathComponent(url.lastPathComponent)
            var n = 1
            while fm.fileExists(atPath: dest.path) {
                dest = musicFolder.appendingPathComponent("\(base) (\(n)).\(ext)")
                n += 1
            }
            do {
                try fm.copyItem(at: url, to: dest)
            } catch {
                errorMessage = "匯入失敗：\(url.lastPathComponent)"
            }
        }
        Task { await reloadLibrary() }
    }

    func delete(_ track: Track) {
        if track == currentTrack {
            player?.stop()
            player = nil
            currentTrack = nil
            isPlaying = false
            stopTimer()
            updateNowPlaying()
        }
        try? FileManager.default.removeItem(at: track.url)
        tracks.removeAll { $0 == track }
    }

    // MARK: - 播放控制

    func play(track: Track) {
        do {
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: track.url)
            p.delegate = self
            p.prepareToPlay()
            player?.stop()
            player = p
            currentTrack = track
            duration = p.duration
            currentTime = 0
            p.play()
            isPlaying = true
            startTimer()
            updateNowPlaying()
        } catch {
            errorMessage = "無法播放：\(track.title)"
        }
    }

    func togglePlayPause() {
        guard let p = player else {
            if let first = tracks.first { play(track: first) }
            return
        }
        if p.isPlaying { pause() } else { resume() }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard let p = player else { togglePlayPause(); return }
        try? AVAudioSession.sharedInstance().setActive(true)
        p.play()
        isPlaying = p.isPlaying
        startTimer()
        updateNowPlaying()
    }

    func seek(to time: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = max(0, min(time, p.duration))
        currentTime = p.currentTime
        updateNowPlaying()
    }

    func next() {
        guard !tracks.isEmpty else { return }
        guard let cur = currentIndex else { play(track: tracks[0]); return }
        if isShuffle && tracks.count > 1 {
            var i = cur
            while i == cur { i = Int.random(in: 0..<tracks.count) }
            play(track: tracks[i])
        } else {
            play(track: tracks[(cur + 1) % tracks.count])
        }
    }

    func previous() {
        guard !tracks.isEmpty else { return }
        if currentTime > 3 { seek(to: 0); return }
        guard let cur = currentIndex else { play(track: tracks[0]); return }
        play(track: tracks[(cur - 1 + tracks.count) % tracks.count])
    }

    func cycleRepeat() { repeatMode = repeatMode.next }

    private func handleFinished() {
        switch repeatMode {
        case .one:
            seek(to: 0)
            player?.play()
        case .all:
            next()
        case .off:
            if isShuffle {
                next()
            } else if let i = currentIndex, i + 1 < tracks.count {
                play(track: tracks[i + 1])
            } else {
                isPlaying = false
                seek(to: 0)
                stopTimer()
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.handleFinished() }
    }

    // MARK: - 計時器

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 背景播放、鎖定畫面

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            Task { @MainActor in
                guard let self else { return }
                if type == .began {
                    self.isPlaying = false
                    self.updateNowPlaying()
                } else if shouldResume {
                    self.resume()
                }
            }
        }
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }; return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }; return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }; return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }; return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let img = t.artwork {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(img)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
