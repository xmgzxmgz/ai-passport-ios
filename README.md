# PassportSlot — AI Passport 玩法槽安装器（iOS 版）

安卓版 `AI-Passport-Bluetooth-Installer` 的 iPhone 对等实现。用 CoreBluetooth 直连 AI Passport
（ESP32-C3，`PassportNotify`）的加密 GATT 服务，把固件写进设备的 3 个玩法槽，支持查看槽位、
切换/清空玩法，附带推送消息到设备屏幕。

写它的原因很直接：那个安装器只有安卓 APK，iPhone 用不了。协议是公开可逆的，安卓端是 Java、
仓库里甚至有一个 Swift 参考脚本，所以补齐 iOS 端是纯粹的工作量问题。

---

## 零、直接下载（已构建好，无需 Mac）

已经用 GitHub Actions 的 macOS 机器编译并发布，未签名 ipa 从这里拿：

**→ [最新 Release](https://github.com/xmgzxmgz/ai-passport-ios/releases/latest)**

| 项 | 值 |
| --- | --- |
| 文件 | `PassportSlot-unsigned.ipa`（约 258 KB） |
| Bundle ID | `cn.folotoy.passportslot` |
| 最低系统 | iOS 17.0（arm64） |
| 签名 | 未签名 —— 需自己侧载签名 |

侧载步骤（免费 Apple ID 即可）：

1. 电脑装 [Sideloadly](https://sideloadly.io)，iPhone 用数据线连电脑
2. 把 ipa 拖进 Sideloadly，填 Apple ID，Start
3. iPhone 上「设置 → 通用 → VPN与设备管理」信任该开发者
4. 免费账号签名 **7 天过期**，到期重复上述流程重签

> 想自己编译也行：有 Mac 就 `open PassportSlot.xcodeproj` 直接 Run；
> 没有 Mac 就 fork 本仓库，Actions 页面点一次 `Run workflow`。

---

## 一、目录结构

```
ios-app/
├── PassportSlot.xcodeproj/            ← 双击就能打开（含共享 scheme）
├── PassportSlot/
│   ├── PassportSlotApp.swift          App 入口
│   ├── Models.swift                   数据模型（槽位、状态快照、固件条目、目录条目）
│   ├── PassportProtocol.swift         BLE 协议层：UUID、组帧、状态解析、镜像切分校验
│   ├── PassportBleClient.swift        CoreBluetooth 客户端 + 写入状态机
│   ├── FirmwareStore.swift            固件库：拉目录、下载校验、本地导入、索引落盘
│   ├── ContentView.swift              SwiftUI 界面
│   └── Assets.xcassets/
├── .github/workflows/ios-build.yml    GitHub Actions 云构建（不用自己的 Mac）
└── tools/
    ├── make_xcodeproj.py              生成并回读校验 .xcodeproj
    ├── check_swift.py                 Swift 结构体检（括号配平 + 关键符号）
    └── verify_protocol.py             用真实固件反证协议常量
```

约 2200 行 Swift，零第三方依赖（只用 CoreBluetooth / CryptoKit / SwiftUI）。
部署目标 iOS 17.0，Bundle ID `cn.folotoy.passportslot`。

---

## 二、协议（逆向结果，逐字节）

### GATT

| 用途 | UUID |
|---|---|
| 服务 | `4a17d400-34ad-4d7b-93f8-84237aacc001` |
| 通知写入（0xA5 帧） | `4a17d400-34ad-4d7b-93f8-84237aacc002` |
| 固件控制（0xF0 帧） | `4a17d400-34ad-4d7b-93f8-84237aacc010` |
| 固件数据（裸分片） | `4a17d400-34ad-4d7b-93f8-84237aacc011` |
| 固件状态（只读） | `4a17d400-34ad-4d7b-93f8-84237aacc012` |

设备广播名 `PassportNotify`。**写入需要安全配对**：首次写特征时系统弹窗，需要输入设备屏幕上的 6 位码。

### 控制命令（写 0xC010）

| 命令 | 字节 |
|---|---|
| 开始安装 | `F0 01 <slot> <size LE32> <nameLen> <name UTF-8>` |
| 结束安装 | `F0 02` |
| 取消 | `F0 03` |
| 清空槽位 | `F0 05 <slot>` |
| 切换槽位 | `F0 06 <slot>` |

`slot` 为 0..2；`name` 最长 47 字节（按 UTF-8 边界截断，不会切坏汉字）。

### 数据（写 0xC011）

安装开始后，把 app 镜像原样切块写入，单块长度取系统协商出的 ATT 载荷。
全部字节写完后再发 `F0 02`，设备做 `esp_ota_end` + 描述块校验，成功则槽位置为 present。

### 状态包（读 0xC012）

**v2（首字节 = 2，多槽协议）**

```
[0]=2  [1]=state  [2]=progress  [3]=selectedSlot(FF=无)  [4]=保留  [5]=槽位数
[10..13]=剩余总量 LE32   [14..17]=最大空槽 LE32
[18...] 每槽： [0]=index [1]=flags [2..5]=capacity LE32 [6..9]=imageSize LE32 [10]=nameLen [11..]=name
```

`flags` bit0 = available（槽位可用），bit1 = present（已写入固件）。
state：0 空闲 / 1 接收中 / 2 就绪 / 3 错误。

**v1（首字节 = 1，老单槽固件）**

```
[1]=state [2]=progress [3]=present!=0 [4..7]=imageSize LE32 [12]=nameLen [13..]=name
```

单槽容量 4 MiB。

### 通知帧（写 0xC002）

`A5 <type> <len LE16> <body UTF-8>`，`type` 1=短信 2=应用 3=其他，body 最多 160 字节。

### 固件镜像切分 ★

官网 `/api/plays` 下发的是 **`esp-merged-0x0` 全片镜像**：`0x0000` 起是 bootloader + 分区表，
`0x10000` 起才是可加载的 app。**槽位只吃 app 段**，必须切掉前 `0x10000` 字节。

合法性判定（与安卓端 `FirmwareRepository.validateImage` 一致）：

- `bytes[0] == 0xE9`（ESP 镜像魔数）
- 芯片 ID（`LE16 @0x0C`）== `5`（ESP32-C3）
- `esp_app_desc` 魔数（`@0x20`）== `32 54 CD AB`（即 `0xABCD5432`）
- app 段大小 ∈ [176, `0x3E0000`]（3.875 MiB，单个玩法槽上限）

`project_name` 在 `@0x50`(80)，`version` 在 `@0x30`(48)，各 32 字节 C 字符串。

**这条已用真实固件实测验证**（见 `tools/verify_protocol.py`）：

```
偏移 0x0000     magic 0xE9 ✓  chip 5 ✓  app_desc 50000000 ✗  → 正确拒绝（bootloader）
偏移 0x10000    magic 0xE9 ✓  chip 5 ✓  app_desc 3254cdab ✓  → 可用
                project = FoloToy-AI-Passport
                version = 2.0.0-installer
                app 大小 = 1118288 字节（1.066 MiB）
```

注意偏移 0 处 **有** `0xE9` 魔数和正确的芯片 ID，只有 `esp_app_desc` 能把它识别成 bootloader ——
所以描述块校验不是可选项，它是唯一的区分依据。

### 官网接口

| 用途 | 请求 |
|---|---|
| 玩法目录 | `GET https://ai-passport.folotoy.cn/api/plays?limit=50&page=N` → `{plays:[…], allTotal:N}` |
| 玩法详情 | `GET https://ai-passport.folotoy.cn/api/plays/id/{id}` → `{play:{…}}` |
| 下载固件 | `GET https://ai-passport.folotoy.cn` + `firmware.url` |

关键字段：`title{zh,en}`、`slug`、`source`、`author`、`category`、`firmwareSize`、
`firmwareSha256`、`firmware.format`（必须为 `esp-merged-0x0`）。

---

## 三、与安卓版的差异（iOS 平台的硬限制）

| 项 | 安卓 | iOS | 处理方式 |
|---|---|---|---|
| 调大 MTU | `gatt.requestMtu(247)` | **无此 API**，系统自行协商 | 用 `peripheral.maximumWriteValueLength(for:)` 取实际载荷 |
| 主动配对 | `device.createBond()` | **无此 API** | 首次写加密特征时系统自动弹配对框，失败退避 2 秒重试（最多 6 次） |
| 蓝牙权限 | 运行时动态申请 | Info.plist 声明 | `INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription` 已写入工程 |
| 解除配对 | `removeBond()` | 无此 API | 提示用户去「设置 → 蓝牙 → 忽略此设备」 |
| 下载/存储 | Kotlin/Java + SharedPreferences | URLSession + Documents/index.json | 等价实现 |
| 写特征方式 | `WRITE_TYPE_DEFAULT` | `withResponse`（优先） | 与安卓一致，保证 1MB+ 传输可靠 |

唯一的 API 缺口是 MTU 与配对：两者都不影响功能，只影响实现路径。**传输本身没有平台依赖。**

---

## 四、装到 iPhone 上（两条路，选一条）

### 路线 A：有 Mac（推荐，最省事）

```bash
open PassportSlot.xcodeproj
```

1. Xcode 里选中 `PassportSlot` target → Signing & Capabilities
2. Team 选你自己的 Apple ID（免费账号即可，Xcode 会自动生成个人签名）
3. 如果 Bundle ID 冲突，把 `cn.folotoy.passportslot` 改成你自己的
4. iPhone 用数据线连上 Mac，Xcode 顶部选中你的设备 → 按 ▶︎

免费 Apple ID 签的名 **7 天过期**，到期重新 Run 一次即可。想长期用就上开发者账号。

### 路线 B：没有 Mac —— 云构建 + Windows 侧载

`.github/workflows/ios-build.yml` 已写好。步骤：

1. 把这个 workflow 放到你仓库根目录的 `.github/workflows/` 下
2. GitHub → Actions → 「Build PassportSlot (unsigned ipa)」 → Run workflow
3. 跑完在 Artifacts 里下载 `PassportSlot-unsigned-ipa`
4. Windows 上装 [Sideloadly](https://sideloadly.io/)，用数据线连 iPhone，
   把 `.ipa` 拖进去，填 Apple ID，Start
5. 首次运行要去 iPhone「设置 → 通用 → VPN与设备管理」信任你的开发者证书

免费 Apple ID 同样是 **7 天有效期**，到期用 Sideloadly 重签一次。这条路不需要买 Mac。

> ⚠️ 注意：未签名 ipa 不能直接双击安装，必须经 Sideloadly / AltStore 之类工具重签后装。
> 免费证书不是「一次装好永久可用」，这点是 Apple 的限制，绕不过去。

---

## 五、怎么用

1. 设备插上 USB，按任意键唤醒（空闲会休眠断连，属正常）
2. App 里点「连接设备」→ 首次会弹配对码输入，码在设备屏幕上
3. 连上后自动读取槽位表，显示每槽的名称、已用/容量
4. 在「官网玩法库」里搜索并下载固件（自动校验 SHA-256 并切出 app 段），
   或点右上角从「文件」导入本地 `.bin`
5. 在「我的固件库」点某个固件的「安装」→ 选目标槽位 → 等进度跑完
6. 「设备校验中」可能要十几秒（设备在做 OTA 落盘 + 分区校验），别拔线
7. 装完在设备上按键选择并启动该玩法

槽位容量：槽 1/2 各 1.4375 MiB，槽 3 为 3.875 MiB（老固件是单槽 4 MiB）。
目录里约 1044 款玩法，其中能塞进单槽的只是子集 —— 超过 3.875 MiB 的（太空弹珠、口袋诗卷等）
只能 USB 整片刷写，App 里会标成「超出单槽上限」并禁用下载。

---

## 六、验证状态（如实说明）

| 项 | 状态 |
|---|---|
| 协议还原 | ✅ 从安卓 APK 反编译 + 官方仓库 Java/C 源码逐条比对 |
| 镜像切分规则 | ✅ 用真实固件实测，偏移/魔数/描述块全部命中 |
| `.xcodeproj` | ✅ 生成后用 pbxproj 库回读，目标/阶段/文件引用全部解析正常 |
| Swift 源码结构 | ✅ 2193 行，括号配平与关键符号检查全绿（`tools/check_swift.py`） |
| Swift 编译通过 | ⚠️ **未验证** —— 这台机器是 Windows，没有 Xcode / iOS SDK |
| 真机跑通 | ⚠️ **未验证** —— 需要你在 Mac 或云构建上编译后实测 |

所以：协议和工程结构是可信的，**编译报错不能排除**。第一次在 Xcode 里打开时如果报错，
把报错贴给我，我来改。首次从零编译出现零星类型推断问题很正常。

需要重点确认的三处（都是 iOS 平台特性，无法在 Windows 上验证）：

1. **配对流程** —— iOS 是否会在写入时正确弹出 6 位码输入框。若配对失败，
   系统设置的「忽略此设备」后重连。
2. **单次可写长度** —— 若 `maximumWriteValueLength(for: .withResponse)` 返回值异常小，
   传输会变慢但不会出错。必要时可在 `PassportBleClient.chunkCeiling` 调整上限。
3. **状态特征的通知** —— 若设备对 0xC012 不支持 notify，只会走主动读取，
   进度更新频率降低，功能不受影响。

---

## 七、维护脚本

```bash
# 改了源码文件列表后重新生成工程（会回读校验）
python tools/make_xcodeproj.py

# Swift 结构体检
python tools/check_swift.py

# 用真实固件反证协议常量
python tools/verify_protocol.py
```

`make_xcodeproj.py` 用的是稳定 ID（由名字哈希得出），重复运行不会把工程搅乱。

---

## 八、致谢与许可

协议来自 [yhh-l/ai-passport-notification-portal](https://github.com/yhh-l/ai-passport-notification-portal)
（作者 ian）的安卓实现与设备端固件源码；`tools/macos_ble_test.swift` 在协议还原时提供了
关键佐证。本 iOS 版为独立重写，未复用其代码。
