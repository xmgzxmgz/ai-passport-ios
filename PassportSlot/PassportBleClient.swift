//
//  PassportBleClient.swift
//  PassportSlot — AI Passport 玩法槽安装器（iOS 版）
//
//  CoreBluetooth 实现。逻辑对齐安卓端 BridgeService.java，差异点：
//   1. iOS 不提供 requestMtu()，MTU 由系统协商；分片大小取
//      peripheral.maximumWriteValueLength(for: .withResponse)
//   2. iOS 不提供 createBond()，首次访问加密特征时系统自动弹配对码输入
//   3. 写入一律用 withResponse，靠 didWriteValueFor 串行推进，与安卓一致
//

import Foundation
import CoreBluetooth
import Combine

@MainActor
final class PassportBleClient: NSObject, ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var link: LinkState = .idle
    @Published private(set) var snapshot: DeviceSnapshot?
    @Published private(set) var progress = TransferProgress()
    @Published private(set) var firmwareSupported = false
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var isInstalling = false
    @Published private(set) var deviceName: String = PassportProtocol.deviceName

    /// 保护上限：即便系统报出更大的值也不超过 512 字节/次
    private let chunkCeiling = 512

    // MARK: - CoreBluetooth

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var service: CBService?
    private var notifyChar: CBCharacteristic?
    private var controlChar: CBCharacteristic?
    private var dataChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?

    // MARK: - 写入状态机

    private enum Op: Equatable {
        case none, notification, fwStart, fwData, fwFinish, fwClear, fwSelect, statusRead
    }

    private var writeBusy = false
    private var currentOp: Op = .none
    private var lastWriteChar: CBCharacteristic?
    private var lastWriteValue: Data?
    /// 首次写入会触发系统配对，失败后重试计数
    private var pairingRetries = 0
    private let pairingRetryLimit = 6
    /// 正在等待配对重试：期间冻结写入引擎，避免重入
    private var retryPending = false
    /// 已发送的分片数，用于周期性回读设备状态
    private var chunkCount = 0
    /// 本次安装实际使用的分片大小（写入成功回调里要按同一值推进游标）
    private var lastChunkLength = 0

    // 安装任务
    private var installImage: Data = Data()
    private var installSlot = -1
    private var installName = ""
    private var installSent = 0
    private var installMeta: PassportProtocol.ImageMeta?

    private enum Phase { case idle, start, data, finish, verify }
    private var phase: Phase = .idle

    // 待发的短命令 / 通知
    private var pendingNotifications: [Data] = []
    private var pendingClear: Int?
    private var pendingSelect: Int?
    private var statusReadPending = false
    private var statusWatchdog: DispatchWorkItem?

    // MARK: - 生命周期

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isConnected: Bool { peripheral?.state == .connected }

    // MARK: - 日志

    func log(_ text: String, _ level: LogLine.Level = .info) {
        logs.append(LogLine(level: level, text: text))
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }

    func clearLogs() { logs.removeAll() }

    // MARK: - 扫描 / 连接

    func startScan() {
        guard central.state == .poweredOn else {
            link = .bluetoothOff
            log("蓝牙不可用，无法扫描", .bad)
            return
        }
        if let p = peripheral, p.state == .connected {
            log("已经连着 \(p.name ?? PassportProtocol.deviceName)，无需重扫")
            return
        }
        central.stopScan()
        // 设备带加密服务，广播里不一定带服务 UUID，因此不加过滤条件，靠名字匹配
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        link = .scanning
        log("开始扫描 \(PassportProtocol.deviceName)…")
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    func forgetDevice() {
        // iOS 不支持程序化解除配对，需用户在系统设置里忽略此设备
        log("如需重新配对：设置 → 蓝牙 → 忽略 \(PassportProtocol.deviceName)", .warn)
    }

    // MARK: - 读取设备状态（槽位表）

    func refreshStatus() {
        guard isConnected, statusChar != nil else { return }
        statusReadPending = true
        pump()
    }

    // MARK: - 清空 / 切换槽位

    func clearSlot(_ index: Int) {
        guard isConnected, firmwareSupported else { return }
        pendingClear = index
        log("请求清空槽位 \(index + 1)…")
        pump()
    }

    func selectSlot(_ index: Int) {
        guard isConnected, firmwareSupported else { return }
        pendingSelect = index
        log("请求切换到槽位 \(index + 1)…")
        pump()
    }

    // MARK: - 推送通知消息（0xA5 帧）

    func sendNotification(_ text: String, type: UInt8 = 3) {
        guard isConnected else { return }
        guard let frame = PassportProtocol.notificationFrame(text: text, type: type) else {
            log("消息为空或超长，已取消", .warn)
            return
        }
        pendingNotifications.append(frame)
        log("已排队推送消息：\(text.prefix(24))")
        pump()
    }

    // MARK: - 安装固件

    func install(image: FirmwareImage, into slot: DeviceSlot) {
        guard isConnected, firmwareSupported else {
            log("设备未就绪或固件不支持多槽安装", .bad)
            return
        }
        guard !isInstalling else { return }

        let url = image.fileURL
        guard let raw = try? Data(contentsOf: url) else {
            log("读不到本地固件文件：\(image.fileName)", .bad)
            return
        }
        guard raw.count >= PassportProtocol.minAppImageSize else {
            log("固件文件过小，拒绝安装", .bad)
            return
        }
        guard raw.count <= slot.capacity else {
            let need = ByteCountFormatter.string(fromByteCount: Int64(raw.count), countStyle: .file)
            let cap = ByteCountFormatter.string(fromByteCount: Int64(slot.capacity), countStyle: .file)
            log("超出槽位容量：需要 \(need)，槽位只有 \(cap)", .bad)
            return
        }
        guard slot.available else {
            log("槽位 \(slot.index + 1) 当前不可用", .bad)
            return
        }

        installImage = raw
        installSlot = slot.index
        installName = image.name.isEmpty ? image.originalName : image.name
        installSent = 0
        installMeta = PassportProtocol.ImageMeta(project: image.project, version: image.version)

        progress = TransferProgress(slot: slot.index,
                                    name: installName,
                                    sent: 0,
                                    total: raw.count,
                                    phase: "准备")
        isInstalling = true
        phase = .start
        pairingRetries = 0

        let mb = ByteCountFormatter.string(fromByteCount: Int64(raw.count), countStyle: .file)
        log("开始安装「\(installName)」\(mb) → 槽位 \(slot.index + 1)", .good)
        log("如果设备屏幕出现 6 位配对码，请在系统弹窗里输入", .warn)
        pump()
    }

    // MARK: - 写入引擎

    private func pump() {
        guard let peripheral, peripheral.state == .connected else { return }
        guard !writeBusy, !retryPending else { return }

        switch phase {
        case .start:
            guard let controlChar else { return }
            let frame = PassportProtocol.startFrame(slot: installSlot,
                                                    size: installImage.count,
                                                    name: installName)
            write(controlChar, frame, op: .fwStart, on: peripheral)

        case .data:
            // 传输途中穿插回读设备状态，让进度与剩余空间保持真实
            if statusReadPending, let statusChar {
                statusReadPending = false
                startStatusWatchdog()
                writeBusy = true
                currentOp = .statusRead
                peripheral.readValue(for: statusChar)
                return
            }
            if installSent >= installImage.count {
                phase = .finish
                pump()
                return
            }
            guard let dataChar else { return }
            let maxLen = chunkLength(on: peripheral)
            lastChunkLength = maxLen
            let end = min(installSent + maxLen, installImage.count)
            let chunk = installImage.subdata(in: installSent..<end)
            write(dataChar, chunk, op: .fwData, on: peripheral)

        case .finish:
            guard let controlChar else { return }
            write(controlChar, PassportProtocol.finishFrame(), op: .fwFinish, on: peripheral)

        case .verify:
            phase = .idle
            statusReadPending = true
            pump()

        case .idle:
            if let slot = pendingClear {
                pendingClear = nil
                guard let controlChar else { return }
                write(controlChar, PassportProtocol.clearFrame(slot: slot), op: .fwClear, on: peripheral)
                return
            }
            if let slot = pendingSelect {
                pendingSelect = nil
                guard let controlChar else { return }
                write(controlChar, PassportProtocol.selectFrame(slot: slot), op: .fwSelect, on: peripheral)
                return
            }
            if !pendingNotifications.isEmpty, let notifyChar {
                let frame = pendingNotifications.removeFirst()
                write(notifyChar, frame, op: .notification, on: peripheral)
                return
            }
            if statusReadPending, let statusChar {
                statusReadPending = false
                startStatusWatchdog()
                writeBusy = true
                currentOp = .statusRead
                peripheral.readValue(for: statusChar)
                return
            }
        }
    }

    /// 单次可写字节数：取系统协商出的 ATT 载荷，并加地板/天花板保护
    private func chunkLength(on peripheral: CBPeripheral) -> Int {
        max(20, min(peripheral.maximumWriteValueLength(for: .withResponse), chunkCeiling))
    }

    private func write(_ characteristic: CBCharacteristic,
                       _ value: Data,
                       op: Op,
                       on peripheral: CBPeripheral) {
        // 优先带响应写入（与安卓 WRITE_TYPE_DEFAULT 等价）；无该属性才降级为无响应
        let withResponse = characteristic.properties.contains(.write)
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse

        writeBusy = true
        currentOp = op
        lastWriteChar = characteristic
        lastWriteValue = value
        peripheral.writeValue(value, for: characteristic, type: type)

        if type == .withoutResponse {
            // 无响应写入不会回调 didWriteValueFor，需手动推进
            handleWriteSuccess(op: op)
        }
    }

    private func handleWriteSuccess(op: Op) {
        writeBusy = false
        currentOp = .none
        pairingRetries = 0
        statusWatchdog?.cancel()

        switch op {
        case .fwStart:
            phase = .data
            chunkCount = 0
            installSent = 0
            progress.phase = "传输中"
            log("开始帧已下发，正在传输镜像数据…")
            pump()

        case .fwData:
            let maxLen = lastChunkLength > 0 ? lastChunkLength : 244
            chunkCount += 1
            installSent = min(installSent + maxLen, installImage.count)
            progress.sent = installSent
            progress.phase = installSent >= installImage.count ? "收尾" : "传输中"
            // 每 64 片回读一次设备状态（设备端进度 + 校验落盘情况）
            if installSent < installImage.count, chunkCount % 64 == 0, statusChar != nil {
                statusReadPending = true
            }
            pump()

        case .fwFinish:
            log("数据发送完毕，等待设备校验并写入分区（可能需要十几秒）…", .info)
            progress.phase = "设备校验中"
            phase = .verify
            pump()

        case .fwClear:
            log("清空指令已下发")
            pendingClear = nil
            statusReadPending = true
            pump()

        case .fwSelect:
            log("切换指令已下发")
            pendingSelect = nil
            statusReadPending = true
            pump()

        case .notification:
            pump()

        case .statusRead, .none:
            pump()
        }
    }

    private func handleWriteFailure(error: Error?, op: Op) {
        let ns: NSError? = error.map { $0 as NSError }
        let desc = ns?.localizedDescription ?? "未知错误"
        let code = ns?.code ?? 0

        // 首次写入必然触发系统安全配对，这属于预期内“失败”：退避后原样重放
        if pairingRetries < pairingRetryLimit,
           let char = lastWriteChar,
           let value = lastWriteValue {
            pairingRetries += 1
            retryPending = true
            writeBusy = false
            currentOp = .none
            link = .pairing
            log("写入被安全配对拦下（\(desc)），2 秒后第 \(pairingRetries) 次重试…", .warn)
            if pairingRetries == 1 {
                log("请在设备屏幕上查看 6 位数字，然后输入 iPhone 弹出的配对框", .warn)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.retryPending = false
                guard let p = self.peripheral, p.state == .connected else { return }
                if self.link == .pairing { self.link = .ready }
                self.write(char, value, op: op, on: p)
            }
            return
        }

        writeBusy = false
        currentOp = .none
        log("写入失败：\(desc)（code \(code)）", .bad)

        if isInstalling {
            isInstalling = false
            phase = .idle
            progress.phase = "失败"
            log("安装中断。设备侧未完成的写入会自行丢弃，可重连后重试。", .bad)
        } else if code == 6 || code == 7 {
            link = .failed("配对被拒绝，请重新连接并核对配对码")
        }
        pump()
    }

    private func handleReadValue(characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == PassportProtocol.status else { return }

        // 关键：只有“我们主动发起的那次读取”才允许解除写入锁。
        // 设备被动推送的状态通知绝不能碰 writeBusy，否则会打断正在进行的写入。
        let wasActiveRead = (currentOp == .statusRead)
        if wasActiveRead {
            statusWatchdog?.cancel()
            writeBusy = false
            currentOp = .none
            statusReadPending = false
        }

        guard error == nil, let data = characteristic.value else {
            if wasActiveRead {
                log("读取设备槽位状态失败：\(error?.localizedDescription ?? "空数据")", .warn)
            }
            pump()
            return
        }

        if let snap = PassportProtocol.parseStatus(data) {
            apply(snapshot: snap)
        } else if wasActiveRead {
            if snap0Unsupported(data) {
                log("设备上报的固件协议版本不受支持，请先升级设备端的门户固件", .bad)
            } else {
                log("设备返回的状态包不完整（\(data.count) 字节）", .warn)
            }
        }
        pump()
    }

    private func snap0Unsupported(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return first != 1 && first != 2
    }

    private func apply(snapshot snap: DeviceSnapshot) {
        let first = self.snapshot == nil
        snapshot = snap

        if first {
            log("读取到设备槽位表：共 \(snap.slots.count) 槽，当前玩法「\(snap.selectedSlotName)」", .good)
            for s in snap.slots {
                let cap = ByteCountFormatter.string(fromByteCount: Int64(s.capacity), countStyle: .file)
                if s.present {
                    let used = ByteCountFormatter.string(fromByteCount: Int64(s.imageSize), countStyle: .file)
                    log("  槽位 \(s.index + 1)：\(s.displayName)（\(used) / \(cap)）")
                } else {
                    log("  槽位 \(s.index + 1)：空（可用 \(cap)）")
                }
            }
        }

        // 安装完成后校验：目标槽位必须已 present
        if isInstalling, phase == .idle, installSlot >= 0 {
            if let target = snap.slots.first(where: { $0.index == installSlot }), target.present {
                isInstalling = false
                progress.sent = progress.total
                progress.phase = "完成"
                let shown = target.name.isEmpty ? installName : target.name
                var extra = ""
                if let meta = installMeta, !meta.version.isEmpty { extra = "（v\(meta.version)）" }
                log("安装完成 · 「\(shown)」\(extra)已写入槽位 \(installSlot + 1)", .good)
                log("现在可以在设备上按键选择并启动这个玩法", .good)
                installSlot = -1
                installImage = Data()
                installMeta = nil
            } else if snap.state == 3 {
                isInstalling = false
                progress.phase = "设备报错"
                log("设备报告写入错误，请重试（若反复失败请检查电源与距离）", .bad)
                installSlot = -1
                installImage = Data()
            }
            // 否则设备仍在接收，等下一次状态读取
        }
    }

    private func startStatusWatchdog() {
        statusWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.currentOp == .statusRead, self.writeBusy {
                    self.writeBusy = false
                    self.currentOp = .none
                    self.log("设备状态读取超时，继续后续流程", .warn)
                    if self.isInstalling || self.phase != .idle { self.pump() }
                }
            }
        }
        statusWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    private func resetConnection(reason: String) {
        notifyChar = nil; controlChar = nil; dataChar = nil; statusChar = nil
        service = nil
        writeBusy = false
        currentOp = .none
        statusReadPending = false
        statusWatchdog?.cancel()
        phase = .idle
        pendingNotifications.removeAll()
        pendingClear = nil
        pendingSelect = nil
        firmwareSupported = false
        if isInstalling {
            isInstalling = false
            progress.phase = "断开"
            log("安装过程中连接断开：\(reason)", .bad)
            log("设备侧未完成的写入会自行回滚，重新连接后可再试", .warn)
        }
        snapshot = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension PassportBleClient: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if !link.isReady && !link.isBusy { link = .idle }
                log("蓝牙已就绪")
            case .poweredOff:
                link = .bluetoothOff
                log("蓝牙已关闭，请打开后重试", .bad)
            case .unauthorized:
                link = .failed("未授权蓝牙权限，请在设置里允许")
                log("蓝牙权限被拒绝", .bad)
            default:
                link = .failed("蓝牙状态异常（\(central.state.rawValue)）")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            let nameHit = localName == PassportProtocol.deviceName || peripheral.name == PassportProtocol.deviceName
            let serviceHit = advertised.contains(PassportProtocol.service)
            guard nameHit || serviceHit else { return }

            central.stopScan()
            self.peripheral = peripheral
            self.deviceName = peripheral.name ?? localName ?? PassportProtocol.deviceName
            peripheral.delegate = self
            link = .connecting
            log("发现 \(deviceName)（RSSI \(RSSI)），正在连接…")
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            link = .discovering
            log("已连接，正在发现服务…", .good)
            peripheral.discoverServices([PassportProtocol.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            link = .failed(error?.localizedDescription ?? "连接失败")
            log("连接失败：\(error?.localizedDescription ?? "未知")", .bad)
            self.peripheral = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    timestamp: CFAbsoluteTime,
                                    isReconnecting: Bool,
                                    error: Error?) {
        MainActor.assumeIsolated {
            let reason = error?.localizedDescription ?? "设备主动断开或进入休眠"
            resetConnection(reason: reason)
            link = .idle
            log("连接已断开：\(reason)", .warn)
            if error == nil {
                log("提示：设备空闲会主动休眠断连，按任意键即可唤醒重连", .info)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension PassportBleClient: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                link = .failed("发现服务失败：\(error.localizedDescription)")
                log("发现服务失败：\(error.localizedDescription)", .bad)
                return
            }
            guard let svc = peripheral.services?.first(where: { $0.uuid == PassportProtocol.service }) else {
                link = .failed("未找到 PassportNotify 服务")
                log("未找到目标服务，可能刷的不是带门户功能的固件", .bad)
                return
            }
            service = svc
            peripheral.discoverCharacteristics(nil, for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                link = .failed("发现特征失败：\(error.localizedDescription)")
                log("发现特征失败：\(error.localizedDescription)", .bad)
                return
            }
            let chars = service.characteristics ?? []
            notifyChar  = chars.first { $0.uuid == PassportProtocol.notify }
            controlChar = chars.first { $0.uuid == PassportProtocol.control }
            dataChar    = chars.first { $0.uuid == PassportProtocol.data }
            statusChar  = chars.first { $0.uuid == PassportProtocol.status }

            firmwareSupported = controlChar != nil && dataChar != nil && statusChar != nil

            if notifyChar == nil {
                link = .failed("设备缺少通知特征")
                log("设备缺少通知写入特征，固件可能不匹配", .bad)
                return
            }

            // 状态特征若支持通知则订阅，便于拿到实时进度
            if let statusChar, statusChar.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: statusChar)
            }

            link = .ready
            log("已连接 · 门户功能可用", .good)
            if !firmwareSupported {
                log("未发现 0xC010/0xC011/0xC012 固件特征，安装功能不可用", .warn)
                log("请先给设备刷入带安装器的固件", .warn)
            }

            let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
            log("单次可写 \(mtu) 字节（系统已自动协商 MTU）")

            statusReadPending = true
            pump()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                handleWriteFailure(error: error, op: currentOp)
            } else {
                handleWriteSuccess(op: currentOp)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            handleReadValue(characteristic: characteristic, error: error)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                log("订阅状态通知失败：\(error.localizedDescription)", .warn)
            }
        }
    }
}
