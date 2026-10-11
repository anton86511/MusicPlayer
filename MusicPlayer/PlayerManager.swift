import Foundation
import AVFoundation
import MediaPlayer
import UIKit

extension Notification.Name {
    /// 本機音樂開始播放（用來暫停 YouTube 網頁）
    static let localPlaybackStarted = Notification.Name("localPlaybackStarted")
}

@MainActor
final class PlayerManager: ObservableObject {
    // MARK: 狀態
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var isShuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var errorMessage: String?
    @Published private(set) var sleepTimerEnd: Date?

    @Published var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? []) {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: "favorites") }
    }

    @Published var playbackRate: Float = 1.0 {
        didSet { timePitch.rate = playbackRate; updateNowPlaying() }
    }

    // MARK: 等化器設定
    static let eqFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    @Published var eqEnabled: Bool = UserDefaults.standard.bool(forKey: "eqEnabled") {
        didSet { applyEQ(); saveEQ() }
    }
    @Published var eqGains: [Float] = PlayerManager.loadGains() {
        didSet { applyEQ(); saveEQ() }
    }
    @Published var eqPresetName: String = UserDefaults.standard.string(forKey: "eqPreset") ?? "平坦" {
        didSet { saveEQ() }
    }

    // MARK: 音訊引擎
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let timePitch = AVAudioUnitTimePitch()
    private var chainFormat: AVAudioFormat?
    private var audioFile: AVAudioFile?
    private var seekFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var timer: Timer?

    private let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "mp4"]

    private var musicFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var currentIndex: Int? {
        guard let c = currentTrack else { return nil }
        return tracks.firstIndex(of: c)
    }

    init() {
        setupEngine()
        applyEQ()
        configureAudioSession()
        configureRemoteCommands()
        startTimer()
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
            generation += 1
            node.stop()
            audioFile = nil
            currentTrack = nil
            isPlaying = false
            currentTime = 0
            duration = 0
            updateNowPlaying()
        }
        try? FileManager.default.removeItem(at: track.url)
        tracks.removeAll { $0 == track }
        favorites.remove(track.fileName)
    }

    func isFavorite(_ track: Track) -> Bool { favorites.contains(track.fileName) }

    func toggleFavorite(_ track: Track) {
        if favorites.contains(track.fileName) {
            favorites.remove(track.fileName)
        } else {
            favorites.insert(track.fileName)
        }
    }

    // MARK: - 播放控制

    func play(track: Track) {
        do {
            let file = try AVAudioFile(forReading: track.url)
            generation += 1
            node.stop()
            prepareChain(for: file.processingFormat)
            audioFile = file
            currentTrack = track
            duration = Double(file.length) / file.processingFormat.sampleRate
            currentTime = 0
            scheduleFrom(0)
            if playNode() {
                isPlaying = true
                NotificationCenter.default.post(name: .localPlaybackStarted, object: nil)
            }
            updateNowPlaying()
        } catch {
            errorMessage = "無法播放：\(track.title)"
        }
    }

    /// 播放清單中的某一組歌（例如只播最愛）
    func playAll(_ list: [Track], shuffle: Bool) {
        guard !list.isEmpty else { return }
        isShuffle = shuffle
        play(track: shuffle ? list.randomElement()! : list[0])
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        guard isPlaying else { return }
        node.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard audioFile != nil else {
            if let first = tracks.first { play(track: first) }
            return
        }
        let engineWasStopped = !engine.isRunning
        if engineWasStopped {
            // 系統中斷或耳機切換後，引擎會被停止，需要重新排程
            scheduleFrom(frame(for: currentTime))
        }
        if playNode() {
            isPlaying = true
            NotificationCenter.default.post(name: .localPlaybackStarted, object: nil)
        }
        updateNowPlaying()
    }

    func seek(to time: TimeInterval) {
        guard audioFile != nil else { return }
        let t = max(0, min(time, duration))
        let wasPlaying = isPlaying
        scheduleFrom(frame(for: t))
        currentTime = t
        if wasPlaying { _ = playNode() }
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

    // MARK: - 睡眠定時

    func setSleepTimer(minutes: Int?) {
        sleepTimerEnd = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
    }

    var sleepRemainingMinutes: Int? {
        guard let end = sleepTimerEnd else { return nil }
        return max(1, Int(ceil(end.timeIntervalSinceNow / 60)))
    }

    // MARK: - 等化器

    func applyPreset(_ preset: EQPreset) {
        eqGains = preset.gains
        eqPresetName = preset.name
        if !eqEnabled { eqEnabled = true }
    }

    func setGain(_ gain: Float, band: Int) {
        guard eqGains.indices.contains(band) else { return }
        eqGains[band] = gain
        eqPresetName = "自訂"
    }

    private func applyEQ() {
        eq.bypass = !eqEnabled
        for (i, band) in eq.bands.enumerated() where i < eqGains.count {
            band.gain = eqGains[i]
        }
        // 增益太高時降低整體音量，避免破音
        let maxBoost = eqGains.max() ?? 0
        eq.globalGain = eqEnabled ? -max(0, maxBoost) * 0.5 : 0
    }

    private func saveEQ() {
        let d = UserDefaults.standard
        d.set(eqEnabled, forKey: "eqEnabled")
        d.set(eqGains.map { Double($0) }, forKey: "eqGains")
        d.set(eqPresetName, forKey: "eqPreset")
    }

    nonisolated private static func loadGains() -> [Float] {
        if let arr = UserDefaults.standard.array(forKey: "eqGains") as? [Double], arr.count == 10 {
            return arr.map { Float($0) }
        }
        return Array(repeating: 0, count: 10)
    }

    // MARK: - 引擎內部

    private func setupEngine() {
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.eqFrequencies[i]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        engine.attach(node)
        engine.attach(timePitch)
        engine.attach(eq)
        _ = engine.mainMixerNode
    }

    /// 依照歌曲格式（取樣率、聲道）連接 播放器 → 變速 → 等化器 → 輸出
    private func prepareChain(for format: AVAudioFormat) {
        if let f = chainFormat, f.sampleRate == format.sampleRate, f.channelCount == format.channelCount {
            return
        }
        if engine.isRunning { engine.stop() }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(timePitch)
        engine.disconnectNodeOutput(eq)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        chainFormat = format
    }

    @discardableResult
    private func playNode() -> Bool {
        if !engine.isRunning {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                engine.prepare()
                try engine.start()
            } catch {
                errorMessage = "無法啟動音訊"
                return false
            }
        }
        node.play()
        return true
    }

    private func frame(for time: TimeInterval) -> AVAudioFramePosition {
        guard let file = audioFile else { return 0 }
        return AVAudioFramePosition(time * file.processingFormat.sampleRate)
    }

    private func scheduleFrom(_ frame: AVAudioFramePosition) {
        guard let file = audioFile else { return }
        generation += 1
        let gen = generation
        node.stop()
        let start = max(0, min(frame, file.length))
        seekFrame = start
        let remaining = file.length - start
        guard remaining > 0 else { return }
        node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(remaining),
                             at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.handleFinished()
            }
        }
    }

    private func handleFinished() {
        switch repeatMode {
        case .one:
            scheduleFrom(0)
            currentTime = 0
            _ = playNode()
            updateNowPlaying()
        case .all:
            next()
        case .off:
            if isShuffle {
                next()
            } else if let i = currentIndex, i + 1 < tracks.count {
                play(track: tracks[i + 1])
            } else {
                isPlaying = false
                scheduleFrom(0)
                currentTime = 0
                updateNowPlaying()
            }
        }
    }

    // MARK: - 計時器（進度、睡眠定時）

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        if isPlaying, let file = audioFile,
           let nodeTime = node.lastRenderTime,
           let playerTime = node.playerTime(forNodeTime: nodeTime) {
            let t = Double(seekFrame + playerTime.sampleTime) / file.processingFormat.sampleRate
            currentTime = min(max(0, t), duration)
        }
        if let end = sleepTimerEnd, Date() >= end {
            sleepTimerEnd = nil
            pause()
        }
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
                    if self.isPlaying { self.node.pause() }
                    self.isPlaying = false
                    self.updateNowPlaying()
                } else if shouldResume {
                    self.resume()
                }
            }
        }

        // 拔掉耳機時自動暫停
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.pause() }
        }

        // 音訊硬體設定改變（例如藍牙切換）時重新啟動引擎
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.audioFile != nil else { return }
                let wasPlaying = self.isPlaying
                self.isPlaying = false
                if wasPlaying { self.resume() }
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0,
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
