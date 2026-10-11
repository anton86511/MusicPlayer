import SwiftUI
import MediaPlayer

struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var sliderValue: Double = 0

    private var artworkSize: CGFloat { min(UIScreen.main.bounds.width - 64, 340) }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 24) {
                Capsule()
                    .fill(.secondary)
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
                    .onTapGesture { dismiss() }

                Spacer(minLength: 0)

                ArtworkView(image: player.currentTrack?.artwork, size: artworkSize, cornerRadius: 16)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                    .scaleEffect(player.isPlaying ? 1.0 : 0.88)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: player.isPlaying)

                VStack(spacing: 6) {
                    Text(player.currentTrack?.title ?? "未在播放")
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(player.currentTrack?.artist ?? "")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal)

                // 進度條
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

                // 控制按鈕
                HStack {
                    Button { player.isShuffle.toggle() } label: {
                        Image(systemName: "shuffle")
                            .font(.title3)
                            .foregroundStyle(player.isShuffle ? Color.pink : Color.secondary)
                    }
                    Spacer()
                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 30))
                    }
                    Spacer()
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 72))
                    }
                    Spacer()
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 30))
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

                // 音量
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    VolumeSlider().frame(height: 30)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)

                Spacer(minLength: 0)
            }
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var background: some View {
        if let img = player.currentTrack?.artwork {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .blur(radius: 60)
                .overlay(Color(.systemBackground).opacity(0.55))
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
