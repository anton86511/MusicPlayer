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
    private var bag = Set<AnyCancellable>()

    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()   // 保留登入狀態

        let js = """
        document.addEventListener('play', function () {
          try { window.webkit.messageHandlers.media.postMessage('play'); } catch (e) {}
        }, true);
        """
        config.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(helper, name: "media")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.uiDelegate = helper
        // 使用 Safari 的識別字串，避免 Google 登入被擋
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

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

    var body: some View {
        NavigationStack {
            WebView(webView: vm.webView)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("網站", selection: $site) {
                            ForEach(Site.allCases, id: \.self) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 250)
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
        }
    }
}
