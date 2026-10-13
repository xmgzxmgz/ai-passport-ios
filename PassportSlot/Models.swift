//
//  Models.swift
//  PassportSlot — AI Passport 玩法槽安装器（iOS 版）
//
//  数据模型层。与安卓版 BridgeService / FirmwareRepository 的语义保持一致。
//

import Foundation

// MARK: - 连接状态

enum LinkState: Equatable {
    case bluetoothOff
    case idle
    case scanning
    case connecting
    case pairing
    case discovering
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .bluetoothOff: return "蓝牙未开启"
        case .idle:         return "未连接"
        case .scanning:     return "正在搜索 PassportNotify…"
        case .connecting:   return "正在连接…"
        case .pairing:      return "正在安全配对"
        case .discovering:  return "正在读取设备能力"
        case .ready:        return "已连接"
        case .failed(let m): return "出错：\(m)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .pairing, .discovering: return true
        default: return false
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - 设备槽位
//
// 设备端 app_firmware.h 定义：
//   APP_FIRMWARE_MAX_SLOTS = 3        最多 3 个玩法槽
//   APP_FIRMWARE_NAME_MAX  = 47       槽位名称最长 47 字节
// 状态包里每个槽位：index(u8) flags(u8) capacity(u32) imageSize(u32) nameLen(u8) name(bytes)
//   flags bit0 = available（槽位存在/可用）
//   flags bit1 = present（已写入固件）
//

struct DeviceSlot: Identifiable, Equatable {
    let index: Int
    let available: Bool
    let present: Bool
    let capacity: Int
    let imageSize: Int
    let name: String

    var id: Int { index }

    /// 还能塞进多大的镜像
    var free: Int { max(0, capacity - (present ? imageSize : 0)) }

    var displayName: String {
        if present && !name.isEmpty { return name }
        return available ? "空槽" : "不可用"
    }

    /// 老固件（协议 v1）单槽容量
    static let legacyCapacity = 0x40_0000        // 4 MiB
    /// 新固件（协议 v2）每槽容量
    static let deviceSlotCapacity = 0x3e_0000    // 3.875 MiB
    /// 合并镜像里 app 段的起始偏移
    static let mergedAppOffset = 0x1_0000
}

// MARK: - 设备状态快照
//
// 来自固件状态特征（4a17d400-…c012）的读取结果。

struct DeviceSnapshot: Equatable {
    var protocolVersion: Int          // 2 = 多槽协议；1 = 老单槽协议
    var state: Int                    // 0 idle / 1 receiving / 2 ready / 3 error
    var progress: Int                 // 0…100
    var selectedSlot: Int             // -1 表示未选择
    var slots: [DeviceSlot]
    var totalFree: Int
    var largestFreeSlot: Int

    var stateText: String {
        switch state {
        case 0: return "空闲"
        case 1: return "接收中"
        case 2: return "就绪"
        case 3: return "错误"
        default: return "未知"
        }
    }

    var selectedSlotName: String {
        guard let s = slots.first(where: { $0.index == selectedSlot }), s.present else { return "未选择" }
        return s.name.isEmpty ? "自定义玩法槽" : s.name
    }
}

// MARK: - 本地固件库条目
//
// 安卓版存在 SharedPreferences；iOS 版存 Documents/FirmwareLibrary/index.json。
// size / sha256 针对的是“已切好的 app 镜像”，不是官网 merged 原始文件。

struct FirmwareImage: Identifiable, Codable, Equatable {
    var id: String             // app 镜像 sha256 前 16 位
    var name: String           // 显示名
    var originalName: String   // 原始文件名
    var project: String        // esp_app_desc_t.project_name
    var version: String        // esp_app_desc_t.version
    var size: Int              // app 镜像字节数
    var sha256: String         // app 镜像 sha256
    var importedAt: Date
    var fileName: String       // 存放在固件库目录内的文件名
    var officialSlug: String   // 来自官网则为 slug，本地导入为空
    var sourceSha256: String   // 官网 merged 原始文件 sha256，本地导入为空

    var fileURL: URL {
        FirmwareLibrary.directory.appendingPathComponent(fileName)
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - 官网目录条目
//
// 接口：GET https://ai-passport.folotoy.cn/api/plays?limit=50&page=N
//       → { "plays": [...], "allTotal": N }
// title / description 是多语言对象：{ "zh": "...", "en": "..." }

/// 目录分页响应外壳：GET /api/plays?limit=50&page=N
struct CatalogEnvelope: Decodable {
    var plays: [CatalogItem]
    var allTotal: Int?
}

struct CatalogItem: Identifiable, Codable, Equatable {
    var id: Int
    var title: String
    var slug: String
    var source: String          // community / official
    var author: String
    var category: String
    var size: Int               // merged 原始文件大小
    var sha256: String          // merged 原始文件 sha256
    var downloadPath: String    // 如 /api/download/community/community-995d8140
    var format: String          // 期望 esp-merged-0x0
    var downloads: Int
    var hearts: Int
    var detail: String
    var githubURL: String?
    var imagePath: String?

    /// app 镜像可用大小 = merged 大小 - 0x10000
    var appSize: Int { max(0, size - DeviceSlot.mergedAppOffset) }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private enum CodingKeys: String, CodingKey {
        case id, slug, source, author, category, downloads, hearts, format
        case title, description, firmware, githubUrl, thumbnail, image
    }

    private struct Localized: Codable {
        var zh: String?
        var en: String?
        var value: String { (zh?.isEmpty == false ? zh : en) ?? "" }
    }

    private struct FirmwareBlock: Codable {
        var size: Int?
        var sha256: String?
        var url: String?
        var format: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        slug = (try? c.decode(String.self, forKey: .slug)) ?? ""
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        downloads = (try? c.decode(Int.self, forKey: .downloads)) ?? 0
        hearts = (try? c.decode(Int.self, forKey: .hearts)) ?? 0
        githubURL = try? c.decodeIfPresent(String.self, forKey: .githubUrl)
        imagePath = try? c.decodeIfPresent(String.self, forKey: .thumbnail)

        title = Self.flexible(c, .title) ?? slug
        detail = Self.flexible(c, .description) ?? ""

        let fw = (try? c.decode(FirmwareBlock.self, forKey: .firmware)) ?? FirmwareBlock()
        size = fw.size ?? 0
        sha256 = fw.sha256 ?? ""
        downloadPath = fw.url ?? ""
        format = fw.format ?? ""
    }

    /// 服务端 title / description 有时是多语言对象 {zh,en}，有时直接是字符串
    private static func flexible(_ c: KeyedDecodingContainer<CodingKeys>,
                                 _ key: CodingKeys) -> String? {
        if let obj = try? c.decode(Localized.self, forKey: key), !obj.value.isEmpty {
            return obj.value
        }
        if let plain = try? c.decode(String.self, forKey: key) {
            return plain.isEmpty ? nil : plain
        }
        return nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(slug, forKey: .slug)
        try c.encode(source, forKey: .source)
        try c.encode(author, forKey: .author)
        try c.encode(category, forKey: .category)
        try c.encode(downloads, forKey: .downloads)
        try c.encode(hearts, forKey: .hearts)
        try c.encode(format, forKey: .format)
        try c.encode(title, forKey: .title)
        try c.encode(detail, forKey: .description)
        var fw = FirmwareBlock()
        fw.size = size; fw.sha256 = sha256; fw.url = downloadPath; fw.format = format
        try c.encode(fw, forKey: .firmware)
    }

    static let categoryNames: [String: String] = [
        "games": "游戏互动",
        "productivity": "效率工具",
        "information": "信息展示",
        "social": "活动社交",
        "learning": "学习创作",
        "developer": "开发者实验"
    ]

    var categoryName: String { Self.categoryNames[category] ?? category }
}

// MARK: - 日志

struct LogLine: Identifiable, Equatable {
    enum Level { case info, good, warn, bad }
    let id = UUID()
    let time = Date()
    let level: Level
    let text: String

    var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: time)
    }
}

// MARK: - 进度

struct TransferProgress: Equatable {
    var slot: Int = -1
    var name: String = ""
    var sent: Int = 0
    var total: Int = 0
    var phase: String = ""

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(sent) / Double(total))
    }

    var percent: Int { Int(fraction * 100) }

    var isActive: Bool { total > 0 }
}
