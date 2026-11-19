//
//  SessionPrompt.swift
//  大厅 / 通话页共用的确认卡片（来电、加入申请）
//
//  为什么不用 .alert：
//    系统 alert 是 UIKit 层面的模态，必须由一个 ViewController 来 present。
//    当通话页正盖在大厅之上（fullScreenCover / 全屏层）时，如果这条 alert 挂在
//    **下面那层大厅**上，UIKit 会把正在呈现的通话页先 dismiss 掉才能弹出来，
//    表现就是：正在房间里的用户突然被打回大厅，而且 alert 的 Binding.set(false)
//    会被系统调用一次 —— 等于"第一次弹出自动拒绝"。
//    所以这里改成纯 SwiftUI 的层内浮层：不依赖任何 modal，盖在谁上面都可以，
//    也不会因为层级关系去影响别的页面。
//

import SwiftUI

struct PromptCard: View {

    let title: String
    let message: String
    var systemImage: String = "phone.arrow.down.left"
    var primaryTitle: String = "接受"
    var secondaryTitle: String = "拒绝"
    var accent: Color = .accentColor
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        ZStack {
            // 只挡住内容，不做"点背景=拒绝"——这是会真的丢一通电话的误触
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 56, height: 56)
                    .background(accent.opacity(0.14), in: Circle())

                Text(title)
                    .font(.headline)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button(action: onSecondary) {
                        Text(secondaryTitle)
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(uiColor: .tertiarySystemFill),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)

                    Button(action: onPrimary) {
                        Text(primaryTitle)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
                .padding(.top, 2)
            }
            .padding(22)
            .frame(maxWidth: 330)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(28)
        }
    }
}

/// 大厅右上角的聊天入口。
///
/// 单独抽成一个 View 是因为未读数是 `ChatService` 的属性：
/// 如果直接写在父视图的 ToolbarItem 里，父视图观察的是 Session，
/// 未读数变化不会触发重绘，角标就会一直停在那里不动。
struct ChatToolbarButton: View {
    @ObservedObject var chat: ChatService
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bubble.left.and.bubble.right")
                .overlay(alignment: .topTrailing) {
                    if chat.unread > 0 {
                        Text("\(min(chat.unread, 99))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                            .offset(x: 8, y: -6)
                    }
                }
        }
        .accessibilityLabel("大厅聊天")
    }
}
