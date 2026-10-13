//
//  PassportSlotApp.swift
//  PassportSlot — AI Passport 玩法槽安装器（iOS 版）
//
//  iOS 版对应安卓端的 AI-Passport-Bluetooth-Installer。
//  用 CoreBluetooth 直连设备的加密 GATT 服务，把准备好的 app 镜像
//  通过 0xF0 控制帧 + 数据分片写进设备的 3 个玩法槽。
//

import SwiftUI

@main
struct PassportSlotApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
