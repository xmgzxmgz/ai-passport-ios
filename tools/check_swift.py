#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Swift 源码结构体检：括号配平 + 关键符号存在性。没有 Swift 工具链时的兜底检查。"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "PassportSlot")

OPEN, CLOSE = "([{", ")]}"
MATCH = {")": "(", "]": "[", "}": "{"}

# 每个文件应当出现的关键符号
EXPECT = {
    "PassportSlotApp.swift": ["@main", "struct PassportSlotApp: App"],
    "Models.swift": ["struct DeviceSlot", "struct CatalogItem", "struct FirmwareImage",
                     "enum LinkState", "struct DeviceSnapshot"],
    "PassportProtocol.swift": ["enum PassportProtocol", "4A17D400", "static func parseStatus",
                               "extractAppImage", "validateImage", "sha256Hex"],
    "PassportBleClient.swift": ["final class PassportBleClient", "CBCentralManagerDelegate",
                                "CBPeripheralDelegate", "func pump()", "handleWriteSuccess",
                                "handleWriteFailure", "MainActor.assumeIsolated"],
    "FirmwareStore.swift": ["final class FirmwareStore", "enum FirmwareLibrary", "func fetchCatalog",
                            "func download", "func importFile"],
    "ContentView.swift": ["struct ContentView", "private struct Card", "private struct SlotRow",
                          "private struct CatalogRow", "enum Theme"],
}


def strip_code(src: str) -> str:
    """去掉注释与字符串字面量，只留结构字符"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
        elif c == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                if src[i] == "\n":          # 多行字符串，直接当普通字符处理
                    i += 1
                    continue
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def check_balance(code: str):
    stack = []
    for ch in code:
        if ch in OPEN:
            stack.append(ch)
        elif ch in CLOSE:
            if not stack or stack[-1] != MATCH[ch]:
                return False, f"遇到 {ch} 但栈顶是 {stack[-1] if stack else '空'}"
            stack.pop()
    if stack:
        return False, "有未闭合的 " + "".join(stack)
    return True, ""


def main():
    problems = 0
    for name in sorted(os.listdir(SRC)):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(SRC, name)
        source = open(path, encoding="utf-8").read()
        code = strip_code(source)

        ok, why = check_balance(code)
        lines = len(source.splitlines())

        missing = [s for s in EXPECT.get(name, []) if s not in source]

        status = "OK  " if (ok and not missing) else "FAIL"
        print(f"[{status}] {name:<24} {lines:>4} 行")
        if not ok:
            print("        结构：" + why)
            problems += 1
        if missing:
            print("        缺少符号：" + ", ".join(missing))
            problems += 1

    total = sum(len(open(os.path.join(SRC, f), encoding="utf-8").read().splitlines())
                for f in os.listdir(SRC) if f.endswith(".swift"))
    print()
    print(f"合计 {total} 行 Swift；问题 {problems} 处")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
