//
//  FirmwareStore.swift
//  PassportSlot — AI Passport 玩法槽安装器（iOS 版）
//
//  固件库：拉官网目录 → 下载 merged 镜像 → 校验 sha256 → 切出 app 镜像 → 落盘索引
//  同时支持从「文件」App 导入本地 .bin。
//
//  与安卓版 FirmwareRepository.java 的差异：
//    · 安卓用 SharedPreferences + 私有目录；iOS 用 Documents/FirmwareLibrary + index.json
//    · 二者的“固件文件”都是切好的 app 镜像（不是官网 merged 原件）
//

import Foundation
import Combine

// MARK: - 存放位置

enum FirmwareLibrary {

    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FirmwareLibrary", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var indexURL: URL { directory.appendingPathComponent("index.json") }

    static let officialOrigin = "https://ai-passport.folotoy.cn"
    static let catalogPath = "/api/plays"

    /// 直连官网下载（不带 CDN，速度取决于网络）
    static func downloadURL(for item: CatalogItem) -> URL? {
        guard !item.downloadPath.isEmpty else { return nil }
        return URL(string: officialOrigin + item.downloadPath)
    }
}

// MARK: - 下载进度回调

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Int64, Int64) -> Void

    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    // 使用 download(from:delegate:) 时由系统落盘，这里无需处理
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

// MARK: - 固件库

@MainActor
final class FirmwareStore: ObservableObject {

    @Published private(set) var images: [FirmwareImage] = []
    @Published private(set) var catalog: [CatalogItem] = []
    @Published private(set) var catalogTotal = 0
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var busyItemID: Int?
    @Published private(set) var downloadPercent = 0
    @Published var catalogError: String?

    /// 目录里能装进槽位的才有意义（merged 大小 ≤ 3.875MiB + 0x10000）
    var installableCatalog: [CatalogItem] {
        catalog.filter { $0.appSize > 0 && $0.appSize <= PassportProtocol.maxAppImageSize }
    }
    var oversizedCatalog: [CatalogItem] {
        catalog.filter { $0.appSize > PassportProtocol.maxAppImageSize }
    }

    init() {
        loadIndex()
    }

    // MARK: - 本地索引

    private func loadIndex() {
        guard let data = try? Data(contentsOf: FirmwareLibrary.indexURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let list = try? dec.decode([FirmwareImage].self, from: data) {
            images = list.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
            if images.count != list.count { saveIndex() }   // 清掉已被删除文件的残留记录
        }
    }

    private func saveIndex() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(images) {
            try? data.write(to: FirmwareLibrary.indexURL, options: .atomic)
        }
    }

    // MARK: - 官网目录

    func fetchCatalog() async {
        guard !isLoadingCatalog else { return }
        isLoadingCatalog = true
        catalogError = nil
        var collected: [CatalogItem] = []
        var total = 0

        do {
            var page = 1
            while page <= 30 {
                guard var comps = URLComponents(string: FirmwareLibrary.officialOrigin + FirmwareLibrary.catalogPath) else { break }
                comps.queryItems = [
                    URLQueryItem(name: "limit", value: "50"),
                    URLQueryItem(name: "page", value: String(page))
                ]
                guard let url = comps.url else { break }
                var req = URLRequest(url: url)
                req.timeoutInterval = 30
                req.setValue("PassportSlot-iOS/1.0", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw NSError(domain: "catalog", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "官网返回 \(http.statusCode)"])
                }

                let env = try JSONDecoder().decode(CatalogEnvelope.self, from: data)
                total = env.allTotal ?? total
                collected.append(contentsOf: env.plays)
                if env.plays.count < 50 { break }
                page += 1
            }

            // 去重 + 按下载量排序
            var seen: [Int: CatalogItem] = [:]
            for item in collected { seen[item.id] = item }
            catalog = seen.values.sorted {
                if $0.downloads != $1.downloads { return $0.downloads > $1.downloads }
                return $0.hearts > $1.hearts
            }
            catalogTotal = total
        } catch {
            catalogError = error.localizedDescription
        }
        isLoadingCatalog = false
    }

    // MARK: - 下载并入库

    func download(_ item: CatalogItem) async {
        guard busyItemID == nil else { return }
        guard let url = FirmwareLibrary.downloadURL(for: item) else {
            catalogError = "目录条目缺少下载地址"
            return
        }
        guard item.appSize > 0, item.appSize <= PassportProtocol.maxAppImageSize else {
            catalogError = "该固件的 app 段超过单槽上限，无法用安装器安装"
            return
        }

        busyItemID = item.id
        downloadPercent = 0
        catalogError = nil
        defer { busyItemID = nil }

        let delegate = DownloadProgressDelegate { written, expected in
            guard expected > 0 else { return }
            let pct = Int(Double(written) / Double(expected) * 100)
            Task { @MainActor in
                if pct != self.downloadPercent { self.downloadPercent = min(pct, 100) }
            }
        }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 300
            req.setValue("PassportSlot-iOS/1.0", forHTTPHeaderField: "User-Agent")

            let (tmp, response) = try await URLSession.shared.download(for: req, delegate: delegate)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "download", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "下载失败 HTTP \(http.statusCode)"])
            }
            let merged = try Data(contentsOf: tmp)

            // ---- 与官网记录逐项核对 ----
            if item.size > 0, merged.count != item.size {
                throw NSError(domain: "download", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "下载不完整：得到 \(merged.count) 字节，官网记录 \(item.size) 字节"])
            }
            let sourceSha = merged.sha256Hex
            if !item.sha256.isEmpty, sourceSha.lowercased() != item.sha256.lowercased() {
                throw NSError(domain: "download", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "SHA-256 校验失败，已拒绝保存（文件可能损坏）"])
            }

            // ---- 切出 app 镜像 ----
            let (appImage, meta) = try PassportProtocol.extractAppImage(merged: merged, format: item.format)
            try store(appImage: appImage,
                      meta: meta,
                      displayName: item.title,
                      originalName: item.slug + "-user-slot.bin",
                      officialSlug: item.slug,
                      sourceSha256: sourceSha)
            downloadPercent = 100

        } catch {
            catalogError = error.localizedDescription
        }
    }

    // MARK: - 本地导入

    func importFile(_ url: URL) async {
        guard busyItemID == nil else { return }
        busyItemID = -1
        catalogError = nil
        defer { busyItemID = nil }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            var data = try Data(contentsOf: url)
            if data.count > PassportProtocol.maxSourceSize {
                throw NSError(domain: "import", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "文件超过设备上限（3.9375 MiB），无法导入"])
            }
            let name = url.lastPathComponent
            var meta: PassportProtocol.ImageMeta

            // 先按裸 app 镜像试，失败再按 merged 试（与安卓 importLocal 一致）
            if let m = try? PassportProtocol.validateImage([UInt8](data), offset: 0) {
                if data.count > PassportProtocol.maxAppImageSize {
                    throw PassportProtocol.ImageError.tooLarge
                }
                meta = m
            } else {
                let r = try PassportProtocol.extractAppImage(merged: data, format: "")
                data = r.image
                meta = r.meta
            }

            try store(appImage: data,
                      meta: meta,
                      displayName: meta.project.isEmpty ? name : meta.project,
                      originalName: name,
                      officialSlug: "",
                      sourceSha256: "")
        } catch {
            catalogError = error.localizedDescription
        }
    }

    // MARK: - 落盘

    private func store(appImage: Data,
                       meta: PassportProtocol.ImageMeta,
                       displayName: String,
                       originalName: String,
                       officialSlug: String,
                       sourceSha256: String) throws {

        guard appImage.count >= PassportProtocol.minAppImageSize else {
            throw PassportProtocol.ImageError.tooSmall
        }
        guard appImage.count <= PassportProtocol.maxAppImageSize else {
            throw PassportProtocol.ImageError.tooLarge
        }

        let appSha = appImage.sha256Hex
        let id = String(appSha.prefix(16))
        let fileName = id + ".bin"
        let dest = FirmwareLibrary.directory.appendingPathComponent(fileName)

        try appImage.write(to: dest, options: .atomic)

        // 同一固件（id 或官网 slug）只留一份
        for old in images where old.id == id || (!officialSlug.isEmpty && old.officialSlug == officialSlug) {
            if old.fileName != fileName {
                try? FileManager.default.removeItem(at: old.fileURL)
            }
        }
        images.removeAll { $0.id == id || (!officialSlug.isEmpty && $0.officialSlug == officialSlug) }

        let display = displayName.isEmpty ? originalName : displayName
        let image = FirmwareImage(id: id,
                                  name: display,
                                  originalName: originalName,
                                  project: meta.project,
                                  version: meta.version,
                                  size: appImage.count,
                                  sha256: appSha,
                                  importedAt: Date(),
                                  fileName: fileName,
                                  officialSlug: officialSlug,
                                  sourceSha256: sourceSha256)
        images.insert(image, at: 0)
        saveIndex()
    }

    func delete(_ image: FirmwareImage) {
        try? FileManager.default.removeItem(at: image.fileURL)
        images.removeAll { $0.id == image.id }
        saveIndex()
    }

    func rename(_ image: FirmwareImage, to newName: String) {
        guard let i = images.firstIndex(where: { $0.id == image.id }) else { return }
        images[i].name = newName
        saveIndex()
    }
}
