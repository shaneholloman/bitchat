//
// BitchatFilePacket.swift
// bitchat
//
// TLV encoder/decoder for file transfer payloads (audio/images)
// Types: 0x01 FILE_NAME (utf8), 0x02 FILE_SIZE (8 bytes, BE), 0x03 MIME_TYPE (utf8), 0x04 CONTENT (raw)
//

import Foundation
import CryptoKit

struct BitchatFilePacket {
    enum TLVType: UInt8 {
        case fileName  = 0x01
        case fileSize  = 0x02
        case mimeType  = 0x03
        case content   = 0x04
    }

    let fileName: String
    let fileSize: UInt64
    let mimeType: String
    let content: Data

    func encode() -> Data? {
        var out = Data()
        func appendTLV(_ type: TLVType, _ value: Data) {
            out.append(type.rawValue)
            let len = UInt16(min(value.count, 0xFFFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(value.prefix(Int(len)))
        }
        // FILE_NAME
        if let nameData = fileName.data(using: .utf8) { appendTLV(.fileName, nameData) }
        // FILE_SIZE (8 bytes, BE)
        var sizeBE = Data()
        for i in (0..<8).reversed() { sizeBE.append(UInt8((fileSize >> (i * 8)) & 0xFF)) }
        appendTLV(.fileSize, sizeBE)
        // MIME_TYPE
        if let mimeData = mimeType.data(using: .utf8) { appendTLV(.mimeType, mimeData) }
        // CONTENT
        appendTLV(.content, content)
        return out
    }

    static func decode(from data: Data) -> BitchatFilePacket? {
        var idx = 0
        func read(_ n: Int) -> Data? {
            guard idx + n <= data.count else { return nil }
            defer { idx += n }
            return data.subdata(in: idx..<(idx+n))
        }
        func read8() -> UInt8? { read(1)?.first }
        func read16() -> UInt16? {
            guard let d = read(2) else { return nil }
            return (UInt16(d[0]) << 8) | UInt16(d[1])
        }

        var name: String?
        var size: UInt64?
        var mime: String?
        var content = Data()

        while idx < data.count {
            guard let t = read8(), let tlvType = TLVType(rawValue: t), let len = read16() else { return nil }
            let l = Int(len)
            guard let val = read(l) else { return nil }
            switch tlvType {
            case .fileName:
                name = String(data: val, encoding: .utf8)
            case .fileSize:
                guard l == 8 else { return nil }
                var s: UInt64 = 0
                for b in val { s = (s << 8) | UInt64(b) }
                size = s
            case .mimeType:
                mime = String(data: val, encoding: .utf8)
            case .content:
                content = val
            }
        }

        // Validate
        guard !content.isEmpty else { return nil }
        let finalSize = size ?? UInt64(content.count)
        let finalName = name ?? "file"
        let finalMime = mime ?? "application/octet-stream"
        return BitchatFilePacket(fileName: finalName, fileSize: finalSize, mimeType: finalMime, content: content)
    }
}

extension Data { func sha256Hex() -> String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() } }
