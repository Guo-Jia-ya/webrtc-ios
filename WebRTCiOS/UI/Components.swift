//
//  Components.swift
//  视频渲染 / 通用小组件
//

import SwiftUI
import WebRTC
import WebKit

/// WebRTC 的远端视频不能直接用 SwiftUI 的 Image 渲染，
/// 必须挂一个实现了 RTCVideoRenderer 的 UIView（这里用 Metal 版的 RTCMTLVideoView）。
struct VideoView: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        // track 没变就不要反复 add/remove，否则画面会闪
        guard context.coordinator.track !== track else { return }
        context.coordinator.track?.remove(uiView)
        context.coordinator.track = track
        track?.add(uiView)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var track: RTCVideoTrack?
    }
}

/// 内嵌浏览器：主机自己也想看一下页面效果时用
struct WebPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// 自签证书：WKWebView 默认会白屏拒绝，必须在这里放行
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        /// iOS 15+ 里 WKWebView 调摄像头要应用这边点头
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }
}

/// 启动页那张卡片
struct EntryCard<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let destination: () -> Destination

    init(title: String,
         subtitle: String,
         systemImage: String,
         tint: Color,
         @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.destination = destination
    }

    var body: some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// 名单里的一行
struct UserRow: View {
    let user: LobbyUser
    var isMe: Bool
    let onCall: () -> Void
    /// 点气泡进私聊。传 nil 就不显示这个按钮（例如主机自己那一行）。
    var onMessage: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(String(user.name.prefix(1)))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(user.inCall ? Color.orange.gradient : Color.accentColor.gradient,
                            in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.name).font(.subheadline.weight(.medium))
                    if isMe {
                        Text("我")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(user.subtitle)
                    .font(.caption)
                    .foregroundStyle(user.online ? Color.secondary : Color.orange)
            }

            Spacer()

            if let onMessage {
                Button(action: onMessage) {
                    Image(systemName: "bubble.left.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!user.online)
                .opacity(user.online ? 1 : 0.4)
                .accessibilityLabel("和 \(user.name) 私聊")
            }

            Button(action: onCall) {
                Text(user.inCall ? "加入" : "呼叫")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!user.online)
            .opacity(user.online ? 1 : 0.4)
        }
        .padding(.vertical, 3)
    }
}
