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

@MainActor
final class WebViewModel: ObservableObject {
    let webView: WKWebView
    let helper = WebHelper()
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var toast: String?
    private var bag = Set<AnyCancellable>()

    // 使用者按下播放時，通知 App 暫停本機音樂
    private static let playListenerJS = """
    document.addEventListener('play', function () {
      try { window.webkit.messageHandlers.media.postMessage('play'); } catch (e) {}
    }, true);
    """

    init() {
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
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: Self.playListenerJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        webView.publisher(for: \.canGoBack).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canGoBack = $0 }.store(in: &bag)
        webView.publisher(for: \.canGoForward).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canGoForward = $0 }.store(in: &bag)
        webView.publisher(for: \.isLoading).receive(on: RunLoop.main)
            .sink { [weak self] in self?.isLoading = $0 }.store(in: &bag)

        // 本機音樂開始播放時，暫停網頁裡的影片
        NotificationCenter.default.publisher(for: .localPlaybackStarted)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pauseWebMedia() }
            .store(in: &bag)
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
    private let homeURL = "https://music.youtube.com"

    @EnvironmentObject var player: PlayerManager
    @StateObject private var vm = WebViewModel()
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            WebView(webView: vm.webView)
                .overlay(alignment: .bottom) {
                    if let t = vm.toast {
                        Text(t)
                            .font(.footnote)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThickMaterial, in: Capsule())
                            .padding(.bottom, 12)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: vm.toast)
                .navigationTitle("YouTube Music")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
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
                        Button { vm.load(homeURL) } label: { Image(systemName: "house") }
                    }
                }
                .onAppear {
                    let p = player
                    vm.helper.onMediaPlay = { [weak p] in
                        Task { @MainActor in p?.pause() }
                    }
                    if !didLoad {
                        didLoad = true
                        vm.load(homeURL)
                    }
                }
        }
    }
}
