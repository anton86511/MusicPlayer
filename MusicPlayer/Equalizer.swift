import SwiftUI

struct EQPreset: Identifiable {
    let name: String
    let gains: [Float]
    var id: String { name }

    static let all: [EQPreset] = [
        EQPreset(name: "平坦", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "流行", gains: [-1, 1, 3, 4, 3, 0, -1, -1, 0, 1]),
        EQPreset(name: "搖滾", gains: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]),
        EQPreset(name: "重低音", gains: [7, 6, 5, 3, 1, 0, 0, 0, 0, 0]),
        EQPreset(name: "人聲", gains: [-2, -3, -2, 1, 4, 4, 3, 1, 0, -2]),
        EQPreset(name: "爵士", gains: [4, 3, 1, 2, -1, -1, 0, 1, 3, 4]),
        EQPreset(name: "古典", gains: [5, 4, 3, 2, -1, -1, 0, 2, 3, 4]),
        EQPreset(name: "電子", gains: [5, 4, 1, 0, -2, 2, 1, 1, 4, 5]),
        EQPreset(name: "高音增強", gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 7]),
        EQPreset(name: "深夜", gains: [-3, -2, -1, 0, 1, 2, 1, 0, -2, -3]),
    ]
}

struct EqualizerView: View {
    @EnvironmentObject var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Toggle("啟用等化器", isOn: $player.eqEnabled)
                    .font(.headline)
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(EQPreset.all) { p in
                            Button(p.name) { player.applyPreset(p) }
                                .buttonStyle(.bordered)
                                .tint(player.eqPresetName == p.name ? Color.pink : Color.gray)
                        }
                    }
                    .padding(.horizontal)
                }

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<10, id: \.self) { i in
                        VStack(spacing: 8) {
                            Text(String(format: "%+.0f", player.eqGains[i]))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            VerticalSlider(
                                value: Binding(get: { player.eqGains[i] },
                                               set: { player.setGain($0, band: i) }),
                                range: -12...12)
                                .frame(height: 230)
                            Text(Self.label(PlayerManager.eqFrequencies[i]))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 6)
                .disabled(!player.eqEnabled)
                .opacity(player.eqEnabled ? 1 : 0.4)

                Text("目前音效：\(player.eqPresetName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("重設為平坦") { player.applyPreset(EQPreset.all[0]) }
                    .disabled(!player.eqEnabled)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("等化器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    static func label(_ f: Float) -> String {
        f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }
}

/// 直立式滑桿（拖曳上下調整）
struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            let frac = CGFloat((value - range.lowerBound) / span)
            let zero = CGFloat((0 - range.lowerBound) / span)
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 6)
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 14, height: 1)
                    .offset(y: -h * zero)
                Capsule()
                    .fill(Color.pink)
                    .frame(width: 6, height: max(6, h * frac))
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: 22, height: 22)
                    .offset(y: -(h - 22) * frac)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let f = 1 - min(max(g.location.y / h, 0), 1)
                    let v = range.lowerBound + Float(f) * span
                    value = (v * 2).rounded() / 2
                }
            )
        }
    }
}
