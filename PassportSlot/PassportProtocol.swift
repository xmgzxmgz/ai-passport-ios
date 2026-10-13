//
//  PassportProtocol.swift
//  PassportSlot — AI Passport 玩法槽安装器（iOS 版）
//
//  BLE 协议层。逐字节对齐设备端 main/app_firmware.c 与安卓端 BridgeService.java。
//

import Foundation
import CoreBluetooth
import CryptoKit

// MARK: - 常量

enum PassportProtocol {

    // ---- GATT 标识 ----
    // 服务 UUID 在设备广播里可见；连接后需要安全配对（设备屏幕显示 6 位码）才能写入。

    static let service = CBUUID(string: "4A17D400-34AD-4D7B-93F8-84237AACC001")
    /// 通知写入（0xA5 消息帧）
    static let notify  = CBUUID(string: "4A17D400-34AD-4D7B-93F8-84237AACC002")
    /// 固件控制（0xF0 命令帧）
    static let control = CBUUID(string: "4A17D400-34AD-4D7B-93F8-84237AACC010")
    /// 固件数据（裸 app 镜像分片）
    static let data    = CBUUID(string: "4A17D400-34AD-4D7B-93F8-84237AACC011")
    /// 固件状态（只读，返回槽位表）
    static let status  = CBUUID(string: "4A17D400-34AD-4D7B-93F8-84237AACC012")

    /// 设备广播名 / BLE 名称
    static let deviceName = "PassportNotify"
    /// 所选槽位为“未选择”时设备返回的哨兵值
    static let autoSlot: UInt8 = 0xFF

    // ---- 控制命令（写 control 特征）----
    static let cmdStart  : UInt8 = 0x01   // 0xF0 0x01 slot size[4 LE] nameLen name
    static let cmdFinish : UInt8 = 0x02   // 0xF0 0x02
    static let cmdCancel : UInt8 = 0x03   // 0xF0 0x03
    static let cmdClear  : UInt8 = 0x05   // 0xF0 0x05 slot
    static let cmdSelect : UInt8 = 0x06   // 0xF0 0x06 slot

    // ---- 通知帧（写 notify 特征）----
    static let notifyMagic: UInt8 = 0xA5

    // ---- 镜像校验常量（对齐 FirmwareRepository.java）----
    static let imageMagic        : UInt8 = 0xE9
    static let appDescOffset     = 0x20   // esp_app_desc_t 在 app 镜像内的偏移
    static let chipIdOffset      = 0x0C   // 镜像头里的芯片 ID 偏移（LE16）
    static let esp32c3ChipId     = 0x0005
    static let minAppImageSize   = 176
    static let maxAppImageSize   = 0x3e_0000   // 3.875 MiB，单个玩法槽上限
    static let maxSourceSize     = 0x3F_0000   // merged 原始文件上限

    // MARK: - 组帧

    /// 通知帧： 0xA5 type len[2 BE? no, LE] body
    /// 对齐 Java：packet[2]=len 低字节, packet[3]=len 高字节 → 小端
    static func notificationFrame(text: String, type: UInt8 = 3) -> Data? {
        var body = Data()
        for ch in text {
            let piece = Data(String(ch).utf8)
            if body.count + piece.count > 160 { break }
            body.append(piece)
        }
        guard !body.isEmpty, (1...3).contains(Int(type)) else { return nil }
        var frame = Data([notifyMagic, type, UInt8(body.count & 0xFF), UInt8((body.count >> 8) & 0xFF)])
        frame.append(body)
        return frame
    }

    /// 安装开始： 0xF0 0x01 slot size[4 LE] nameLen name
    static func startFrame(slot: Int, size: Int, name: String) -> Data {
        let nameBytes = utf8Prefix(name, limit: 47)
        var frame = Data([
            0xF0, cmdStart, UInt8(slot & 0xFF),
            UInt8(size & 0xFF),
            UInt8((size >> 8) & 0xFF),
            UInt8((size >> 16) & 0xFF),
            UInt8((size >> 24) & 0xFF),
            UInt8(nameBytes.count & 0xFF)
        ])
        frame.append(nameBytes)
        return frame
    }

    static func finishFrame() -> Data { Data([0xF0, cmdFinish]) }
    static func cancelFrame() -> Data { Data([0xF0, cmdCancel]) }
    static func clearFrame(slot: Int)  -> Data { Data([0xF0, cmdClear, UInt8(slot & 0xFF)]) }
    static func selectFrame(slot: Int) -> Data { Data([0xF0, cmdSelect, UInt8(slot & 0xFF)]) }

    /// 按 UTF-8 边界安全截断，避免把汉字切一半
    static func utf8Prefix(_ text: String, limit: Int) -> Data {
        var out = Data()
        for ch in text {
            let piece = Data(String(ch).utf8)
            if out.count + piece.count > limit { break }
            out.append(piece)
        }
        return out
    }

    // MARK: - 状态包解析
    //
    // v2（value[0] == 2）：
    //   [1] state  [2] progress  [3] selectedSlot(0xFF=无)  [4] 保留  [5] 槽位数
    //   [10..13] totalFree(u32 LE)  [14..17] largestFreeSlot(u32 LE)
    //   [18...] 每槽 11 字节定长 + 变长名称
    //
    // v1（value[0] == 1）：老固件单槽
    //   [1] state [2] progress [3] present!=0 [4..7] imageSize(u32 LE) [12] nameLen [13...] name

    static func parseStatus(_ raw: Data) -> DeviceSnapshot? {
        let v = [UInt8](raw)
        guard v.count >= 13 else { return nil }

        let state = Int(v[1])
        let progress = Int(v[2])

        if v[0] == 2 {
            guard v.count >= 18 else { return nil }
            var selected = Int(v[3])
            if selected == Int(autoSlot) { selected = -1 }
            let count = Int(v[5])
            let totalFree = Int(le32(v, 10))
            let largest = Int(le32(v, 14))

            var slots: [DeviceSlot] = []
            var o = 18
            for _ in 0..<count {
                guard o + 11 <= v.count else { return nil }
                let index = Int(v[o]); o += 1
                let flags = Int(v[o]); o += 1
                let capacity = Int(le32(v, o)); o += 4
                let imageSize = Int(le32(v, o)); o += 4
                let nameLen = Int(v[o]); o += 1
                guard o + nameLen <= v.count else { return nil }
                let name = nameLen == 0 ? "" : String(decoding: v[o..<(o + nameLen)], as: UTF8.self)
                o += nameLen
                slots.append(DeviceSlot(index: index,
                                        available: (flags & 0x01) != 0,
                                        present:   (flags & 0x02) != 0,
                                        capacity: capacity,
                                        imageSize: imageSize,
                                        name: name))
            }
            slots.sort { $0.index < $1.index }
            return DeviceSnapshot(protocolVersion: 2, state: state, progress: progress,
                                  selectedSlot: selected, slots: slots,
                                  totalFree: totalFree, largestFreeSlot: largest)

        } else if v[0] == 1 {
            let present = v[3] != 0
            let imageSize = present ? Int(le32(v, 4)) : 0
            let nameLen = min(Int(v[12]), max(0, v.count - 13))
            let name = nameLen == 0 ? "" : String(decoding: v[13..<(13 + nameLen)], as: UTF8.self)
            let slot = DeviceSlot(index: 0, available: true, present: present,
                                  capacity: DeviceSlot.legacyCapacity,
                                  imageSize: imageSize,
                                  name: name.isEmpty ? "自定义玩法槽" : name)
            return DeviceSnapshot(protocolVersion: 1, state: state, progress: progress,
                                  selectedSlot: present ? 0 : -1, slots: [slot],
                                  totalFree: present ? 0 : DeviceSlot.legacyCapacity,
                                  largestFreeSlot: present ? 0 : DeviceSlot.legacyCapacity)
        }

        return nil
    }

    static func le32(_ v: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= v.count else { return 0 }
        return UInt32(v[o]) | (UInt32(v[o + 1]) << 8) | (UInt32(v[o + 2]) << 16) | (UInt32(v[o + 3]) << 24)
    }

    // MARK: - 镜像切分与校验
    //
    // 官网下发的是 "esp-merged-0x0" 全片镜像：
    //   0x0000 bootloader + 分区表 + 其他，0x10000 起才是可加载的 app
    // 槽位安装只吃 app 段，因此必须切掉前 0x10000 字节。

    struct ImageMeta: Equatable {
        var project: String
        var version: String
    }

    enum ImageError: LocalizedError {
        case tooSmall
        case tooLarge
        case badMagic
        case badDescriptor
        case wrongChip(UInt16)
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .tooSmall:        return "文件过小，不是有效的 ESP32-C3 应用固件"
            case .tooLarge:        return "应用镜像超过单个玩法槽上限（3.875 MiB）"
            case .badMagic:        return "缺少 ESP 镜像头（魔数 0xE9）"
            case .badDescriptor:   return "未找到 esp_app_desc 描述块，可能不是应用固件"
            case .wrongChip(let c):return String(format: "固件目标芯片不是 ESP32-C3（读到 0x%04X）", c)
            case .unsupportedFormat(let f): return "暂不支持该固件格式：\(f)"
            }
        }
    }

    /// 校验某偏移处是否为合法的 ESP32-C3 app 镜像，并取出 project / version
    static func validateImage(_ bytes: [UInt8], offset: Int) throws -> ImageMeta {
        guard offset >= 0, bytes.count - offset >= minAppImageSize else { throw ImageError.tooSmall }
        let o = offset
        guard bytes[o] == imageMagic else { throw ImageError.badMagic }

        let chip = UInt16(bytes[o + chipIdOffset]) | (UInt16(bytes[o + chipIdOffset + 1]) << 8)
        guard chip == UInt16(esp32c3ChipId) else { throw ImageError.wrongChip(chip) }

        let d = o + appDescOffset
        guard bytes[d] == 0x32, bytes[d + 1] == 0x54, bytes[d + 2] == 0xCD, bytes[d + 3] == 0xAB else {
            throw ImageError.badDescriptor
        }
        return ImageMeta(project: cString(bytes, o + 80, 32), version: cString(bytes, o + 48, 32))
    }

    /// 取 C 风格定长字符串（到 NUL 或长度上限为止）
    static func cString(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String {
        guard offset < bytes.count else { return "" }
        let end = min(offset + length, bytes.count)
        var slice: [UInt8] = []
        for i in offset..<end {
            if bytes[i] == 0 { break }
            slice.append(bytes[i])
        }
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把官网 merged 镜像切成 app 镜像
    static func extractAppImage(merged: Data, format: String) throws -> (image: Data, meta: ImageMeta) {
        guard format.isEmpty || format == "esp-merged-0x0" else {
            throw ImageError.unsupportedFormat(format)
        }
        let bytes = [UInt8](merged)
        let offset = DeviceSlot.mergedAppOffset
        let meta = try validateImage(bytes, offset: offset)
        let appSize = bytes.count - offset
        guard appSize >= minAppImageSize else { throw ImageError.tooSmall }
        guard appSize <= maxAppImageSize else { throw ImageError.tooLarge }
        return (merged.subdata(in: offset..<merged.count), meta)
    }

    /// 校验“用户可能直接拖进来的”镜像：先当裸 app 试，失败再当 merged 试
    static func importAnyImage(source: Data) throws -> (image: Data, meta: ImageMeta) {
        let bytes = [UInt8](source)
        if let meta = try? validateImage(bytes, offset: 0) {
            guard bytes.count <= maxAppImageSize else { throw ImageError.tooLarge }
            return (source, meta)
        }
        return try extractAppImage(merged: source, format: "")
    }
}

// MARK: - SHA-256

extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
