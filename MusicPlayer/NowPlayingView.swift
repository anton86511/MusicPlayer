import SwiftUI
import MediaPlayer
import AVKit

struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var lyrics: LyricsStore
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var sliderValue: Double = 0
    @State private var showLyrics = false
    @State private var showEQ = false

    private var artworkSize: CGFloat { min(UIScreen.main.bounds.width - 80, 310) }
    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        ZStack {
            background
            VStack(spacing: 18) {
                Capsule()
                    .fill(.secondary)
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
                    .onTapGesture { dismiss() }

                // 封面 / 歌詞
                Group {
                    if showLyrics {
                        LyricsView()
                    } else {
                        VStack {
                            Spacer(minLength: 0)
                            ArtworkView(image: player.currentTrack?.artwork, size: artworkSize, cornerRadius: 16)
                                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                                .scaleEffect(player.isPlaying ? 1.0 : 0.88)
                                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: player.isPlaying)
                                .onTapGesture { withAnimation { showLyrics = true } }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.currentTrack?.title ?? "未在播放")
                            .font(.title3.bold())
                            .lineLimit(1)
                        Text(player.currentTrack?.artist ?? "")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let t = player.currentTrack {
                        Button { player.toggleFavorite(t) } label: {
                            Image(systemName: player.isFavorite(t) ? "heart.fill" : "heart")
                                .font(.title2)
                                .foregroundStyle(.pink)
                        }
                    }
                }
                .padding(.horizontal, 32)

                progressBar
                controls
                utilityRow

                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    VolumeSlider().frame(height: 30)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 12)
            }
        }
        .task(id: player.currentTrack?.id) {
            if let t = player.currentTrack { await lyrics.load(for: t) }
        }
        .sheet(isPresented: $showEQ) {
            EqualizerView().environmentObject(player)
        }
    }

    // MARK: 進度條
    private var progressBar: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isEditing ? sliderValue : player.currentTime },
                    set: { sliderValue = $0 }),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        sliderValue = player.currentTime
                        isEditing = true
                    } else {
                        player.seek(to: sliderValue)
                        isEditing = false
                    }
                })
            HStack {
                Text(formatTime(isEditing ? sliderValue : player.currentTime))
                Spacer()
                Text("-" + formatTime(player.duration - (isEditing ? sliderValue : player.currentTime)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
    }

    // MARK: 播放控制
    private var controls: some View {
        HStack {
            Button { player.isShuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(player.isShuffle ? Color.pink : Color.secondary)
            }
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 28))
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 28))
            }
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.pink)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 32)
    }

    // MARK: 功能列：歌詞 / 等化器 / 速度 / 睡眠 / AirPlay
    private var utilityRow: some View {
        HStack(spacing: 0) {
            Button { withAnimation { showLyrics.toggle() } } label: {
                utilityLabel("quote.bubble", "歌詞", active: showLyrics)
            }

            Button { showEQ = true } label: {
                utilityLabel("slider.vertical.3", "等化器", active: player.eqEnabled)
            }

            Menu {
                ForEach(speeds, id: \.self) { r in
                    Button {
                        player.playbackRate = r
                    } label: {
                        if r == player.playbackRate {
                            Label(speedText(r), systemImage: "checkmark")
                        } else {
                            Text(speedText(r))
                        }
                    }
                }
            } label: {
                utilityLabel("gauge.with.dots.needle.33percent", speedText(player.playbackRate),
                             active: player.playbackRate != 1.0)
            }

            Menu {
                Button("關閉") { player.setSleepTimer(minutes: nil) }
                ForEach([5, 15, 30, 45, 60, 90], id: \.self) { m in
                    Button("\(m) 分鐘後停止") { player.setSleepTimer(minutes: m) }
                }
            } label: {
                utilityLabel("moon.zzz",
                             player.sleepRemainingMinutes.map { "剩 \($0) 分" } ?? "睡眠",
                             active: player.sleepTimerEnd != nil)
            }

            VStack(spacing: 4) {
                RoutePicker().frame(width: 28, height: 24)
                Text("AirPlay").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private func utilityLabel(_ icon: String, _ text: String, active: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).frame(height: 24)
            Text(text).font(.caption2).lineLimit(1)
        }
        .foregroundStyle(active ? Color.pink : Color.secondary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func speedText(_ r: Float) -> String {
        r == r.rounded() ? "\(Int(r))x" : "\(r)x"
    }

    @ViewBuilder
    private var background: some View {
        if let img = player.currentTrack?.artwork {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .blur(radius: 60)
                .overlay(Color(.systemBackground).opacity(0.6))
                .ignoresSafeArea()
        } else {
            LinearGradient(colors: [Color.pink.opacity(0.35), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }
}

/// 系統音量滑桿
struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.tintColor = .systemPink
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// AirPlay / 藍牙輸出選擇
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .secondaryLabel
        v.activeTintColor = .systemPink
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
