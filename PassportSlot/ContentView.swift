//
//  ContentView.swift
//  PassportSlot — AI Passport 玩法槽安装器（iOS 版）
//

import SwiftUI

// MARK: - 主题

enum Theme {
    static let accent  = Color(red: 0.69, green: 0.26, blue: 0.34)   // #B04356 石榴红
    static let sage    = Color(red: 0.54, green: 0.60, blue: 0.42)   // #8A9A6B 鼠尾草绿
    static let cream   = Color(red: 0.98, green: 0.96, blue: 0.94)   // #FAF5EF 奶油
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var ble = PassportBleClient()
    @StateObject private var store = FirmwareStore()

    @State private var showImporter = false
    @State private var showLog = false
    @State private var searchText = ""
    @State private var categoryFilter = "全部"
    @State private var installTarget: FirmwareImage?
    /// 从槽位侧发起安装时，先选固件
    @State private var pickerSlot: DeviceSlot?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    deviceCard
                    if ble.isInstalling || ble.progress.isActive { progressCard }
                    if ble.firmwareSupported || ble.snapshot != nil { slotCard }
                    firmwareCard
                    catalogCard
                    notifyCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("AI Passport 槽位安装器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showLog = true
                    } label: {
                        Label("日志", systemImage: "text.alignleft")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入固件", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .tint(Theme.accent)
            .sheet(isPresented: $showLog) { logSheet }
            .sheet(item: $pickerSlot) { slot in firmwarePicker(for: slot) }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .confirmationDialog("选择目标槽位",
                                isPresented: Binding(get: { installTarget != nil },
                                                     set: { if !$0 { installTarget = nil } }),
                                titleVisibility: .visible) {
                ForEach(availableSlots) { slot in
                    Button("槽位 \(slot.index + 1) · \(slot.displayName)（可用 \(bytes(slot.free))）") {
                        if let fw = installTarget { ble.install(image: fw, into: slot) }
                        installTarget = nil
                    }
                }
                Button("取消", role: .cancel) { installTarget = nil }
            } message: {
                if let fw = installTarget {
                    Text("「\(fw.name)」\(fw.sizeText)")
                }
            }
            .task {
                if store.catalog.isEmpty { await store.fetchCatalog() }
            }
        }
    }

    private var availableSlots: [DeviceSlot] {
        (ble.snapshot?.slots ?? []).filter { $0.available }
    }

    // MARK: - 设备卡

    private var deviceCard: some View {
        Card("设备") {
            HStack(spacing: 12) {
                Circle()
                    .fill(ble.link.isReady ? Theme.sage : (ble.link.isBusy ? .orange : .gray))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.link.isReady ? ble.deviceName : ble.link.title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if ble.link.isReady {
                    Button("断开") { ble.disconnect() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                } else {
                    Button(ble.link.isBusy ? "连接中…" : "连接设备") { ble.startScan() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .disabled(ble.link.isBusy)
                }
            }

            Text("首次连接会要求安全配对：设备屏幕会显示 6 位数字，输入到 iPhone 系统弹窗即可。设备空闲时会自动休眠断连，按一下机身按键即可唤醒。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private var subtitle: String {
        guard let s = ble.snapshot else {
            return ble.firmwareSupported ? "多槽安装功能可用" : "尚未读取设备状态"
        }
        let mode = s.protocolVersion == 2 ? "多槽协议" : "老单槽协议"
        return "\(mode) · 当前玩法「\(s.selectedSlotName)」"
    }

    // MARK: - 进度卡

    private var progressCard: some View {
        Card("安装进度") {
            HStack {
                Text(ble.progress.name.isEmpty ? "准备中" : ble.progress.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(ble.progress.phase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: ble.progress.fraction)
                .tint(Theme.accent)
            HStack {
                Text("\(bytes(ble.progress.sent)) / \(bytes(ble.progress.total))")
                Spacer()
                Text("\(ble.progress.percent)%")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 槽位卡

    private var slotCard: some View {
        Card("玩法槽位") {
            if let s = ble.snapshot {
                ForEach(s.slots) { slot in
                    SlotRow(slot: slot,
                            isSelected: slot.index == s.selectedSlot,
                            firmwareReady: !store.images.isEmpty,
                            onInstall: { pickFirmware(for: slot) },
                            onSelect: { ble.selectSlot(slot.index) },
                            onClear: { ble.clearSlot(slot.index) })
                }
                HStack {
                    Text("剩余总量 \(bytes(s.totalFree)) · 最大空槽 \(bytes(s.largestFreeSlot))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        ble.refreshStatus()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            } else {
                Text("正在读取槽位…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 槽位行上的「安装」：库里只有一个固件就直接装，多个则先弹固件选择
    private func pickFirmware(for slot: DeviceSlot) {
        guard let first = store.images.first else {
            showLog = true
            ble.log("固件库是空的，先从官网玩法库下载，或从「文件」导入一个固件", .warn)
            return
        }
        if store.images.count == 1 {
            ble.install(image: first, into: slot)
        } else {
            pickerSlot = slot
        }
    }

    /// 选固件 → 装进指定槽位
    private func firmwarePicker(for slot: DeviceSlot) -> some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.images) { img in
                        Button {
                            pickerSlot = nil
                            ble.install(image: img, into: slot)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(img.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("\(img.sizeText)\(img.version.isEmpty ? "" : " · v\(img.version)")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if img.size > slot.free {
                                    Text("超出容量")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .disabled(img.size > slot.free)
                    }
                } header: {
                    Text("装进槽位 \(slot.index + 1)，剩余空间 \(bytes(slot.free))")
                }
            }
            .navigationTitle("选择要安装的固件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { pickerSlot = nil }
                }
            }
        }
    }

    // MARK: - 我的固件库

    private var firmwareCard: some View {
        Card("我的固件库（\(store.images.count)）") {
            if store.images.isEmpty {
                Text("还没有固件。从下面的官网玩法库里下载，或点右上角从「文件」导入 .bin。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.images) { img in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(img.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text("\(img.sizeText) · \(img.project.isEmpty ? img.originalName : img.project)\(img.version.isEmpty ? "" : " v\(img.version)")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(spacing: 6) {
                            Button {
                                installTarget = img
                            } label: {
                                Label("安装", systemImage: "arrow.down.circle")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!ble.link.isReady || ble.isInstalling)

                            Button(role: .destructive) {
                                store.delete(img)
                            } label: {
                                Text("删除").font(.caption2)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                    if img.id != store.images.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: - 官网玩法库

    private var catalogCard: some View {
        Card("官网玩法库") {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索玩法名称", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(8)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))

                if store.isLoadingCatalog {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await store.fetchCatalog() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let err = store.catalogError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if !store.catalog.isEmpty {
                Text("共 \(store.catalogTotal) 款；其中 \(store.installableCatalog.count) 款能装进单个玩法槽（≤ 3.875 MB），\(store.oversizedCatalog.count) 款超出槽位上限，只能用 USB 整片刷写。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(categories, id: \.self) { c in
                            Button(c) { categoryFilter = c }
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(categoryFilter == c ? Theme.accent : Color(.tertiarySystemFill),
                                            in: Capsule())
                                .foregroundStyle(categoryFilter == c ? .white : .primary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            let list = filteredCatalog
            if list.isEmpty && !store.catalog.isEmpty {
                Text("没有匹配的玩法。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(list.prefix(120)) { item in
                CatalogRow(item: item,
                           installed: store.images.contains { $0.officialSlug == item.slug },
                           busy: store.busyItemID == item.id,
                           percent: store.downloadPercent,
                           fits: item.appSize <= PassportProtocol.maxAppImageSize) {
                    Task { await store.download(item) }
                }
            }
            if list.count > 120 {
                Text("仅显示前 120 条，用搜索缩小范围。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var categories: [String] {
        var set = Set(["全部"])
        for item in store.catalog { set.insert(item.categoryName) }
        return set.sorted { a, b in
            if a == "全部" { return true }
            if b == "全部" { return false }
            return a < b
        }
    }

    private var filteredCatalog: [CatalogItem] {
        store.catalog.filter { item in
            if categoryFilter != "全部", item.categoryName != categoryFilter { return false }
            if searchText.isEmpty { return true }
            let q = searchText.lowercased()
            return item.title.lowercased().contains(q)
                || item.slug.lowercased().contains(q)
                || item.author.lowercased().contains(q)
        }
    }

    // MARK: - 推送消息（0xA5 帧）

    @State private var pushText = ""

    private var notifyCard: some View {
        Card("给设备推一条消息") {
            Text("这是门户功能：把一行文字推到设备屏幕（最多 160 字节）。需要设备当前跑的是带门户/安装器的固件。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("例如：会议 14:30 开始", text: $pushText)
                    .textFieldStyle(.roundedBorder)
                Button("推送") {
                    ble.sendNotification(pushText)
                    pushText = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.link.isReady || pushText.isEmpty)
            }
        }
    }

    // MARK: - 日志

    private var logSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(ble.logs) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.stamp)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Text(line.text)
                                    .font(.caption2)
                                    .foregroundStyle(color(for: line.level))
                                    .textSelection(.enabled)
                            }
                            .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .onChange(of: ble.logs.count) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清空") { ble.clearLogs() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showLog = false }
                }
            }
        }
    }

    private func color(for level: LogLine.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .good: return Theme.sage
        case .warn: return .orange
        case .bad:  return .red
        }
    }

    // MARK: - 工具

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await store.importFile(url) }
        case .failure(let error):
            store.catalogError = error.localizedDescription
        }
    }

    private func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

// MARK: - 卡片容器

private struct Card<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 槽位行

private struct SlotRow: View {
    let slot: DeviceSlot
    let isSelected: Bool
    let firmwareReady: Bool
    let onInstall: () -> Void
    let onSelect: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("槽 \(slot.index + 1)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(isSelected ? Theme.accent : Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(isSelected ? .white : .secondary)

                Text(slot.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(.tertiarySystemFill))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isSelected ? Theme.accent : Theme.sage)
                        .frame(width: geo.size.width * usedFraction)
                }
            }
            .frame(height: 5)

            HStack(spacing: 6) {
                Text("\(bytes(slot.imageSize)) / \(bytes(slot.capacity))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()

                if slot.available {
                    Button("安装", action: onInstall)
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .disabled(!firmwareReady)
                }
                if slot.present {
                    Button("切换", action: onSelect)
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.bordered)
                        .disabled(isSelected)
                    Button("清空", role: .destructive, action: onClear)
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 6)
        .opacity(slot.available ? 1 : 0.45)
    }

    private var usedFraction: Double {
        guard slot.capacity > 0, slot.present else { return 0 }
        return min(1, Double(slot.imageSize) / Double(slot.capacity))
    }

    private func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

// MARK: - 目录行

private struct CatalogRow: View {
    let item: CatalogItem
    let installed: Bool
    let busy: Bool
    let percent: Int
    let fits: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if installed {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.sage)
                    }
                }
                Text("\(item.categoryName) · \(item.author) · \(item.sizeText) · 下载 \(item.downloads)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !fits {
                    Text("超出单槽上限，需 USB 整片刷写")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()

            if busy {
                VStack(spacing: 3) {
                    ProgressView(value: Double(percent), total: 100)
                        .frame(width: 54)
                    Text("\(percent)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if fits {
                Button(installed ? "重新下载" : "下载") { onDownload() }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.bordered)
            } else {
                Text("不可用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
