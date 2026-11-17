//
//  WebSocketFrame.swift
//  RFC 6455 帧编解码（只实现做信令够用的部分）
//
//  和 socket.io 的区别：桌面端临时服务器用的是 socket.io（engine.io 协议），
//  而 iOS 这边没有 socket.io 服务端实现，所以手机开的临时服务器改用**裸 WebSocket**，
//  协议是我们自己定的（见 HostedPage.swift）。浏览器原生支持 WebSocket，不必再带库。
//
//  浏览器 → 服务器：所有帧都带掩码（mask=1），负载要用 4 字节掩码循环异或还原。
//  服务器 → 浏览器：不能带掩码，否则浏览器会以 1002 协议错误断开。
//

import Foundation

struct WebSocketFrame {

    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    let opcode: Opcode
    let payload: Data

    /// 从缓冲区头部解一帧；数据不够一整帧时返回 nil，等下次收到更多字节再试
    static func decode(from buffer: inout Data) -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        let bytes = [UInt8](buffer)

        let b0 = bytes[0]
        let b1 = bytes[1]
        guard let opcode = Opcode(rawValue: b0 & 0x0F) else { return nil }

        let masked = (b1 & 0x80) != 0
        var length = Int(b1 & 0x7F)
        var offset = 2

        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            var value = 0
            for i in 2..<10 { value = value << 8 | Int(bytes[i]) }
            length = value
            offset = 10
        }

        var mask: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            mask = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }

        guard bytes.count >= offset + length else { return nil }

        var payload = Array(bytes[offset..<(offset + length)])
        if masked {
            for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
        }

        buffer = Data(bytes[(offset + length)...])
        return WebSocketFrame(opcode: opcode, payload: Data(payload))
    }

    /// 服务器发出的帧：不加掩码
    static func encode(opcode: Opcode, payload: Data) -> Data {
        var out = Data([0x80 | opcode.rawValue])   // FIN=1
        let n = payload.count
        if n < 126 {
            out.append(UInt8(n))
        } else if n <= 0xFFFF {
            out.append(126)
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8(n & 0xFF))
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((n >> shift) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }
}
