#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 LocationSimulator 转换成 xtool 可编译的 SwiftPM 工程。
用法: python build_locsim_xtool.py
输出: LocationSimulator-XTool/
"""
import plistlib
import shutil
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "LocationSimulator"
OUT = ROOT / "LocationSimulator-XTool"


def make_icon(dst: Path) -> None:
    """生成一个 1024x1024 蓝底白色定位针风格的 PNG 图标（纯标准库）。"""
    w = h = 1024
    # 蓝底 + 白色圆形+三角组合模拟定位 pin
    rows = []
    cx, cy = 512, 440
    for y in range(h):
        row = bytearray()
        for x in range(w):
            # 背景：渐变蓝
            t = y / h
            r = int(30 + 20 * t)
            g = int(80 + 40 * t)
            b = int(200 - 40 * t)
            # 白色圆（pin head）
            dx, dy = x - cx, y - cy
            if dx * dx + dy * dy < 180 * 180:
                r, g, b = 255, 255, 255
            # 白色三角（pin tail）
            ty = y - (cy + 100)
            if 0 < ty < 280:
                halfw = int(60 * (1 - ty / 280))
                if abs(x - cx) < halfw + 60:
                    r, g, b = 255, 255, 255
            # 中心蓝点
            if dx * dx + dy * dy < 70 * 70:
                r, g, b = 30, 100, 220
            row += bytes([r, g, b])
        rows.append(b'\x00' + bytes(row))
    raw = b''.join(rows)

    def chunk(typ, payload):
        return (struct.pack(">I", len(payload)) + typ + payload
                + struct.pack(">I", zlib.crc32(typ + payload) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    dst.write_bytes(png)


def main() -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "Sources" / "LocationSimulator").mkdir(parents=True)
    (OUT / "Sources" / "idevice").mkdir(parents=True)
    (OUT / "Libraries").mkdir(parents=True)
    (OUT / "Resources").mkdir(parents=True)
    (OUT / "Support").mkdir(parents=True)

    # 1. Swift 源码（主 app，排除扩展目录）
    swift_files = sorted(SRC.rglob("*.swift"))
    for f in swift_files:
        rel = f.relative_to(SRC)
        dst = OUT / "Sources" / "LocationSimulator" / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, dst)
    print(f"[1] 主 App Swift: {len(swift_files)} 个文件")

    # 2. C 静态库
    shutil.copy2(SRC / "Native" / "idevice.h", OUT / "Sources" / "idevice" / "idevice.h")
    shutil.copy2(SRC / "Native" / "module.modulemap", OUT / "Sources" / "idevice" / "module.modulemap")
    shutil.copy2(SRC / "Native" / "libidevice_ffi.a", OUT / "Libraries" / "libidevice_ffi.a")
    print("[2] idevice: 头文件 + modulemap + arm64 静态库")

    # 3. 图标 + 头像
    make_icon(OUT / "Resources" / "AppIcon.png")
    avatar_src = SRC / "Resources" / "avatar.jpg"
    if avatar_src.exists():
        shutil.copy2(avatar_src, OUT / "Resources" / "avatar.jpg")
        print("[3] AppIcon.png + avatar.jpg")
    else:
        print("[3] AppIcon.png (无 avatar.jpg)")

    # 4. Info.plist
    info = plistlib.loads((SRC / "App" / "Info.plist").read_bytes())
    # 移除 Xcode 构建变量（xtool 不会解析它们）
    for k in ("CFBundleExecutable", "CFBundleName", "PRODUCT_NAME", "EXECUTABLE_NAME"):
        info.pop(k, None)
    info.update({
        "CFBundleExecutable": "LocationSimulator",
        "CFBundleName": "LocationSimulator",
        "CFBundleIdentifier": "com.locationsimulator.app",
        "CFBundleShortVersionString": "1.0.0",
        "CFBundleVersion": "1",
        "CFBundleDevelopmentRegion": "en",
        "ITSAppUsesNonExemptEncryption": False,
        "LSSupportsOpeningDocumentsInPlace": True,
        # 允许检测 / 打开 LocalDevVPN
        "LSApplicationQueriesSchemes": ["localdevvpn"],
        # 显式启用 iOS 26 液态玻璃设计语言
        "UIDesignRequiresCompatibility": False,
        # Bonjour 服务声明（配对发现必需，iOS 强制要求）
        "NSBonjourServices": [
            "_remotepairing._tcp",
            "_remotepairing-manual-pairing._tcp",
            "_remotepairing-pairable-host._tcp",
            "_locsimprobe._tcp",
        ],
        "NSLocalNetworkUsageDescription": (
            "LocationSimulator needs local network access to connect to your "
            "iOS device for location simulation."
        ),
        "NSLocationAlwaysAndWhenInUseUsageDescription": (
            "Location access keeps the app alive in the background while "
            "simulating GPS location."
        ),
        "NSLocationWhenInUseUsageDescription": (
            "Location access keeps the app alive in the background while "
            "simulating GPS location."
        ),
        "UIBackgroundModes": ["audio", "location"],
        "UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
    })
    (OUT / "Support" / "Info.plist").write_bytes(
        plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))
    print(f"[4] Info.plist: {len(info)} 个键")

    # 5. entitlements（已回滚 VPN，仅保留空 entitlements）
    entitlements = {}
    (OUT / "Support" / "LocationSimulator.entitlements").write_bytes(
        plistlib.dumps(entitlements, fmt=plistlib.FMT_XML, sort_keys=True))
    print("[5] entitlements (空)")

    # 6. Package.swift（无扩展 target）
    (OUT / "Package.swift").write_text("""// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let libraryDir = packageDir + "/Libraries"

let package = Package(
    name: "LocationSimulator",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LocationSimulator", targets: ["LocationSimulator"]),
    ],
    targets: [
        .systemLibrary(name: "idevice", path: "Sources/idevice"),
        .target(
            name: "LocationSimulator",
            dependencies: ["idevice"],
            path: "Sources/LocationSimulator",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("idevice_ffi"),
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .unsafeFlags(["-L\\(libraryDir)"]),
            ]
        ),
    ]
)
""", encoding="utf-8")
    print("[6] Package.swift")

    # 7. xtool.yml（无扩展声明）
    (OUT / "xtool.yml").write_text("""version: 1
bundleID: com.locationsimulator.app
product: LocationSimulator
infoPath: Support/Info.plist
iconPath: Resources/AppIcon.png
entitlementsPath: Support/LocationSimulator.entitlements
""", encoding="utf-8")
    print("[7] xtool.yml")

    # 8. 校验
    out_swift = list((OUT / "Sources" / "LocationSimulator").rglob("*.swift"))
    assert len(out_swift) == len(swift_files), \
        f"Swift 文件数不一致: {len(out_swift)} vs {len(swift_files)}"
    assert (OUT / "Libraries" / "libidevice_ffi.a").stat().st_size > 50_000_000
    print(f"[8] 校验通过: {len(out_swift)} 个 Swift 文件, 静态库 {OUT.joinpath('Libraries/libidevice_ffi.a').stat().st_size // 1048576} MB")


if __name__ == "__main__":
    main()
