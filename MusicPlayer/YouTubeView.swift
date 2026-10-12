import SwiftUI
import WebKit
import Combine

/// 處理網頁事件：YouTube 開始播放時通知、開新視窗的連結改在同一頁打開
final class WebHelper: NSObject, WKScriptMessageHandler, WKUIDelegate {
    var onMediaPlay: (() -> Void)?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "media" { onMediaPlay?() }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

enum YTSettings {
    static let showDislike = "ytShowDislike"
    static let preferHD = "ytPreferHD"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [showDislike: true, preferHD: false])
    }
}

@MainActor
final class WebViewModel: ObservableObject {
    let webView: WKWebView
    let helper = WebHelper()
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var dislike: DislikeInfo?
    @Published var toast: String?
    private var bag = Set<AnyCancellable>()
    private var dislikeTask: Task<Void, Never>?
    private var currentVideoID: String?

    // 使用者按下播放時，通知 App 暫停本機音樂
    private static let playListenerJS = """
    document.addEventListener('play', function () {
      try { window.webkit.messageHandlers.media.postMessage('play'); } catch (e) {}
    }, true);
    """

    // 「高畫質優先」（實驗性）：當裝置支援 VP9 / AV1 時，回報不支援 H.264，
    // 讓 YouTube 改送較高解析度的編碼格式。裝置不支援時不會有任何作用。
    private static let preferHDJS = """
    (function () {
      var targets = [window.MediaSource, window.ManagedMediaSource].filter(Boolean);
      targets.forEach(function (MS) {
        if (!MS.isTypeSupported) return;
        var orig = MS.isTypeSupported.bind(MS);
        var modern = orig('video/webm; codecs="vp9"') || orig('video/mp4; codecs="av01.0.08M.08"');
        if (!modern) return;
        MS.isTypeSupported = function (t) {
          if (typeof t === 'string' && /^video\\//.test(t) && /avc1/.test(t)) return false;
          return orig(t);
        };
      });
    })();
    """

    init() {
        YTSettings.registerDefaults()

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()   // 保留登入狀態
        config.userContentController.add(helper, name: "media")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.uiDelegate = helper
        // 使用 Safari 的識別字串，避免 Google 登入被擋
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        installScripts()

        webView.publisher(for: \.canGoBack).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canGoBack = $0 }.store(in: &bag)
        webView.publisher(for: \.canGoForward).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canGoForward = $0 }.store(in: &bag)
        webView.publisher(for: \.isLoading).receive(on: RunLoop.main)
            .sink { [weak self] in self?.isLoading = $0 }.store(in: &bag)

        // YouTube 換影片時網址會改變（包含不重新載入頁面的切換）
        webView.publisher(for: \.url).receive(on: RunLoop.main)
            .sink { [weak self] in self?.handleURLChange($0) }.store(in: &bag)

        // 本機音樂開始播放時，暫停網頁裡的影片
        NotificationCenter.default.publisher(for: .localPlaybackStarted)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pauseWebMedia() }
            .store(in: &bag)
    }

    // MARK: 腳本與設定

    private func installScripts() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: Self.playListenerJS,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if UserDefaults.standard.bool(forKey: YTSettings.preferHD) {
            ucc.addUserScript(WKUserScript(source: Self.preferHDJS,
                                           injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }

    /// 設定改變後呼叫：重新安裝腳本並重新載入頁面
    func settingsChanged() {
        installScripts()
        webView.reload()
        handleURLChange(webView.url, force: true)
    }

    // MARK: 倒讚數

    private func handleURLChange(_ url: URL?, force: Bool = false) {
        guard UserDefaults.standard.bool(forKey: YTSettings.showDislike) else {
            dislike = nil
            currentVideoID = nil
            return
        }
        let id = DislikeService.videoID(from: url)
        if id == currentVideoID && !force { return }
        currentVideoID = id
        dislikeTask?.cancel()
        dislike = nil
        guard let id else { return }
        dislikeTask = Task { [weak self] in
            let info = await DislikeService.shared.fetch(videoID: id)
            guard !Task.isCancelled, let self, self.currentVideoID == id else { return }
            self.dislike = info
        }
    }

    // MARK: 子母畫面

    func togglePiP() {
        let js = """
        (function () {
          var vids = [].slice.call(document.querySelectorAll('video'));
          var v = vids.filter(function (x) { return !x.paused && x.readyState > 2; })[0] || vids[0];
          if (!v) return 'no-video';
          try {
            if (v.webkitSetPresentationMode) {
              v.webkitSetPresentationMode(
                v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
              return 'ok';
            }
            if (document.pictureInPictureEnabled && v.requestPictureInPicture) {
              if (document.pictureInPictureElement) { document.exitPictureInPicture(); }
              else { v.requestPictureInPicture(); }
              return 'ok';
            }
          } catch (e) { return 'error'; }
          return 'unsupported';
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor in
                switch result as? String {
                case "ok": break
                case "no-video": self?.show("目前頁面沒有影片，請先開啟一部影片")
                default: self?.show("這部影片無法使用子母畫面")
                }
            }
        }
    }

    private func show(_ text: String) {
        toast = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }

    // MARK: 其他

    func load(_ string: String) {
        if let url = URL(string: string) { webView.load(URLRequest(url: url)) }
    }

    func pauseWebMedia() {
        webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){ m.pause(); });")
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct YouTubeView: View {
    enum Site: String, CaseIterable, Hashable {
        case youtube = "YouTube"
        case music = "YouTube Music"

        var url: String {
            switch self {
            case .youtube: return "https://m.youtube.com"
            case .music: return "https://music.youtube.com"
            }
        }
    }

    @EnvironmentObject var player: PlayerManager
    @StateObject private var vm = WebViewModel()
    @State private var site: Site = .youtube
    @State private var didLoad = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            WebView(webView: vm.webView)
                .overlay(alignment: .bottom) { overlays }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("網站", selection: $site) {
                            ForEach(Site.allCases, id: \.self) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { vm.webView.goBack() } label: { Image(systemName: "chevron.left") }
                            .disabled(!vm.canGoBack)
                        Spacer()
                        Button { vm.webView.goForward() } label: { Image(systemName: "chevron.right") }
                            .disabled(!vm.canGoForward)
                        Spacer()
                        if vm.isLoading {
                            Button { vm.webView.stopLoading() } label: { Image(systemName: "xmark") }
                        } else {
                            Button { vm.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                        }
                        Spacer()
                        Button { vm.togglePiP() } label: { Image(systemName: "pip.enter") }
                        Spacer()
                        Button { vm.load(site.url) } label: { Image(systemName: "house") }
                    }
                }
                .onChange(of: site) { s in vm.load(s.url) }
                .onAppear {
                    let p = player
                    vm.helper.onMediaPlay = { [weak p] in
                        Task { @MainActor in p?.pause() }
                    }
                    if !didLoad {
                        didLoad = true
                        vm.load(site.url)
                    }
                }
                .sheet(isPresented: $showSettings) {
                    YouTubeSettingsView { vm.settingsChanged() }
                }
        }
    }

    @ViewBuilder
    private var overlays: some View {
        VStack(spacing: 8) {
            if let info = vm.dislike, info.likes != nil || info.dislikes != nil {
                DislikePill(info: info)
            }
            if let t = vm.toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThickMaterial, in: Capsule())
            }
        }
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.2), value: vm.toast)
        .allowsHitTesting(false)
    }
}

struct DislikePill: View {
    let info: DislikeInfo

    var body: some View {
        HStack(spacing: 12) {
            Label(count(info.likes), systemImage: "hand.thumbsup.fill")
            Label(count(info.dislikes), systemImage: "hand.thumbsdown.fill")
            if let r = info.ratio {
                Text("\(Int((r * 100).rounded()))%").foregroundStyle(.secondary)
            }
        }
        .font(.footnote.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThickMaterial, in: Capsule())
    }

    private func count(_ n: Int?) -> String {
        guard let n else { return "–" }
        return n.formatted(.number.notation(.compactName))
    }
}

struct YouTubeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(YTSettings.showDislike) private var showDislike = true
    @AppStorage(YTSettings.preferHD) private var preferHD = false
    let onChange: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("顯示倒讚數", isOn: $showDislike)
                } footer: {
                    Text("在影片頁下方顯示讚與倒讚數量。資料來自 Return YouTube Dislike（returnyoutubedislike.com）的使用者回報與估算，僅供參考。")
                }

                Section {
                    Toggle("高畫質優先（實驗性）", isOn: $preferHD)
                } footer: {
                    Text("在裝置支援 VP9 / AV1 時，讓 YouTube 優先提供較高解析度的影片格式（可能出現 1440p、2160p）。依裝置與影片而定，不一定有效；若影片無法播放，請關閉。切換後會重新載入頁面。")
                }

                Section {
                    Text("工具列的子母畫面按鈕使用 iOS 內建功能，能不能使用取決於 YouTube 網頁是否開放。YouTube 在背景或鎖定畫面時無法繼續播放，只有子母畫面會繼續。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("說明")
                }
            }
            .navigationTitle("YouTube 設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: showDislike) { _ in onChange() }
            .onChange(of: preferHD) { _ in onChange() }
        }
    }
}
