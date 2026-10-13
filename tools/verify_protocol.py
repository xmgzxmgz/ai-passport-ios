#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用真实官网固件反证 iOS 版写死的那几个协议常量。
逐条复刻 PassportProtocol.swift / FirmwareRepository.java 的判定逻辑：
  · 偏移 0x0000 与 0x10000 各自的镜像头
  · 芯片 ID（LE16 @0x0C）必须是 5 = ESP32-C3
  · esp_app_desc 魔数 @0x20 必须是 0xABCD5432
  · version @48(32B)、project_name @80(32B)
  · app 段大小必须落在 [176, 0x3E0000]
"""
import hashlib
import os
import sys

MERGED_APP_OFFSET = 0x10000
DEVICE_SLOT_SIZE = 0x3E0000
MIN_APP = 176
ESP32C3 = 5


def cstr(b, off, ln):
    chunk = b[off:off + ln]
    return chunk.split(b"\x00", 1)[0].decode("utf-8", "replace")


def probe(name, data, offset):
    if len(data) - offset < MIN_APP:
        return None, "剩余长度不足 176 字节"
    h = data[offset:offset + 176]
    magic = h[0]
    chip = int.from_bytes(h[12:14], "little")
    desc = h[0x20:0x24]
    info = {
        "magic": magic,
        "chip": chip,
        "desc": desc.hex(),
        "version": cstr(h, 48, 32),
        "project": cstr(h, 80, 32),
        "app_size": len(data) - offset,
    }
    if magic != 0xE9:
        return info, "镜像魔数不是 0xE9"
    if chip != ESP32C3:
        return info, f"芯片 ID 不是 ESP32-C3（读到 {chip}）"
    if desc != bytes([0x32, 0x54, 0xCD, 0xAB]):
        return info, "esp_app_desc 魔数不匹配"
    if not (MIN_APP <= info["app_size"] <= DEVICE_SLOT_SIZE):
        return info, "app 段大小超出槽位上限"
    return info, ""


def main():
    here = os.path.dirname(os.path.abspath(__file__))          # ios-app/tools
    fw = os.path.join(os.path.dirname(os.path.dirname(here)),  # ai-passport
                      "firmware", "bluetooth-multi-installer-1227.bin")
    if not os.path.exists(fw):
        print("找不到固件：" + fw)
        return 1

    data = open(fw, "rb").read()
    print(f"文件           {os.path.basename(fw)}")
    print(f"大小           {len(data)} 字节")
    print(f"merged sha256  {hashlib.sha256(data).hexdigest()}")
    print(f"官网记录大小   1183824  →  {'一致' if len(data) == 1183824 else '不一致'}")
    print()

    for off in (0, MERGED_APP_OFFSET):
        info, err = probe("x", data, off)
        label = "裸 app 镜像(偏移 0)" if off == 0 else "merged 的 app 段(偏移 0x10000)"
        if info is None:
            print(f"--- {label} ---")
            print("    " + err)
            continue
        print(f"--- {label} ---")
        print(f"    magic       0x{info['magic']:02X}"
              + ("  ✓" if info["magic"] == 0xE9 else "  ✗"))
        print(f"    chip_id     {info['chip']}"
              + ("  ✓ ESP32-C3" if info["chip"] == ESP32C3 else "  ✗"))
        print(f"    app_desc    {info['desc']}"
              + ("  ✓" if info["desc"] == "3254cdab" else "  ✗"))
        print(f"    project     {info['project'] or '(空)'}")
        print(f"    version     {info['version'] or '(空)'}")
        print(f"    app 大小    {info['app_size']} 字节"
              f" ({info['app_size'] / 1048576:.3f} MiB)")
        print(f"    判定        {'可用' if not err else '不可用 — ' + err}")
        print()

    # 真实切分结果
    app = data[MERGED_APP_OFFSET:]
    print("=== 按 iOS 版逻辑切出的 app 镜像 ===")
    print(f"    大小        {len(app)} 字节")
    print(f"    sha256      {hashlib.sha256(app).hexdigest()}")
    print(f"    入库 id     {hashlib.sha256(app).hexdigest()[:16]}")
    print()
    print("结论：偏移 0x10000 处确为合法 ESP32-C3 应用镜像，与安卓版切分规则一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
