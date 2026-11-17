//
//  CallView.swift
//  通话页：本地 + 远端画面宫格，底部控制条
//

import SwiftUI
import WebRTC
import UIKit

struct CallView: View {
    @ObservedObject var call: MeshCall
    let onHangUp: () -> Void

    private struct Tile: Identifiable {
        let id: String
        let track: RTCVideoTrack?
        let title: String
        let isLocal: Bool
    }

    private var tiles: [Tile] {
        var list: [Tile] = [Tile(id: "local", track: call.localTrack, title: "我", isLocal: true)]
        // 字典顺序不稳定，排一下避免画面来回换位置
        for (id, track) in call.remoteTracks.sorted(by: { $0.key < $1.key }) {
            list.append(Tile(id: id, track: track, title: String(id.prefix(4)), isLocal: false))
        }
        return list
    }

    private var columns: [GridItem] {
        tiles.count > 1
            ? [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            : [GridItem(.flexible())]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text(call.status)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer()
                    Text("\(call.memberCount) 人")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(tiles) { tile in
                            ZStack(alignment: .bottomLeading) {
                                VideoView(track: tile.track)
                                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                    .background(Color(white: 0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))

                                if tile.track == nil {
                                    VStack(spacing: 6) {
                                        ProgressView().tint(.white)
                                        Text("等待画面…")
                                            .font(.caption2)
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }

                                Text(tile.title)
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.5), in: Capsule())
                                    .padding(8)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }

                HStack(spacing: 18) {
                    controlButton(icon: call.micOn ? "mic.fill" : "mic.slash.fill",
                                  label: call.micOn ? "静音" : "取消静音",
                                  tint: call.micOn ? Color.white.opacity(0.15) : Color.orange) {
                        call.toggleMic()
                    }

                    controlButton(icon: call.cameraOn ? "video.fill" : "video.slash.fill",
                                  label: call.cameraOn ? "关摄像头" : "开摄像头",
                                  tint: call.cameraOn ? Color.white.opacity(0.15) : Color.orange) {
                        call.toggleCamera()
                    }

                    controlButton(icon: "arrow.triangle.2.circlepath.camera",
                                  label: "翻转",
                                  tint: Color.white.opacity(0.15)) {
                        call.switchCamera()
                    }

                    controlButton(icon: "phone.down.fill",
                                  label: "挂断",
                                  tint: .red) {
                        onHangUp()
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
        }
        .interactiveDismissDisabled(true)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func controlButton(icon: String,
                               label: String,
                               tint: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(tint, in: Circle())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }
}
