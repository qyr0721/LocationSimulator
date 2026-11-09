# LocationSimulator

一个独立的 iOS GPS 位置模拟工具，从 [StikDebug](https://github.com/StikDebug/StikDebug) 中提取而来。

通过地图界面、路线回放、坐标导入和后台保活，模拟 iOS 设备的 GPS 位置。

## 功能特性

- **首次使用引导** —— 首次启动时逐步引导你连接 LocalDevVPN（附 App Store 跳转）并创建配对文件。推荐在设备端直接配对，也支持导入已有文件。
- **地图选点** —— 点击地图任意位置落点，即可模拟该坐标
- **实时改点** —— 模拟过程中修改坐标（地图点击、搜索、历史/收藏、手动输入）会立即推送到设备，无需停止后重启
- **地点搜索** —— 搜索地址与兴趣点
- **路线模拟** —— 通过地图点选、搜索地点或从当前位置出发规划路线，然后以真实速度回放（使用 OpenStreetMap 限速数据）
- **坐标导入** —— 支持从 GPX、KML、GeoJSON、JSON、CSV 或纯文本文件导入坐标
- **历史与收藏** —— 支持重命名、滑动添加/删除
- **快速连接检测** —— 持续监控网络/VPN 状态；启动模拟时走即时预检门禁，不再等待缓慢的 Bonjour 查询
- **后台保活** —— 静音音频或定位保活，维持后台模拟不中断
- **循环重发** —— 每 4 秒自动重发一次模拟坐标，保持伪装

## 环境要求

- **iOS 17.4+**（使用 RemotePairing / RSD 隧道 API）
- **配对文件**（`.plist` 或 `.mobiledevicepairing`）
- **回环 VPN**，如 [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)（用于设备端模拟）
- **macOS + Xcode 16+** 用于构建
- **XcodeGen** 用于生成 Xcode 工程（也可手动创建）

## 首次启动

应用假定你尚无配对文件，会显示全屏引导：

1. **LocalDevVPN** —— 通过 `localdevvpn://enable` 打开 VPN 应用，未安装则跳转 App Store。
2. **配对** —— 「配对此设备」可在设备端直接生成配对文件（无需电脑）；「从文件导入」接受已有的 `.plist` / `.mobiledevicepairing`。
3. **完成** —— 引导收起且不再出现。之后可从 **设置 → 关于 → 重新查看使用引导** 再次打开。

首页的连接状态条会实时显示就绪状态，VPN 或配对文件缺失时会阻止启动模拟。

## 构建

### 使用 XcodeGen（推荐）

```bash
# 如未安装 XcodeGen
brew install xcodegen

# 生成 Xcode 工程（project.yml 位于仓库根目录）
xcodegen generate

# 用 Xcode 打开
open LocationSimulator.xcodeproj
```

然后在 Xcode 中：

1. 选中 **LocationSimulator** 目标
2. 进入 **Signing & Capabilities**，设置你的 Apple ID / Team
3. 设置唯一的 **Bundle Identifier**（例如 `com.yourname.LocationSimulator`）
4. 构建并运行到真机（Cmd+R）

### 手动配置 Xcode 工程

如果不使用 XcodeGen：

1. 在 Xcode 新建 iOS App 工程（SwiftUI，iOS 17.4+）
2. 将 `LocationSimulator/` 下所有源文件加入工程
3. 把 `Native/libidevice_ffi.a` 加入 **Link Binary With Libraries**
4. 设置 `HEADER_SEARCH_PATHS` 为 `$(SRCROOT)/LocationSimulator/Native`
5. 设置 `LIBRARY_SEARCH_PATHS` 为 `$(SRCROOT)/LocationSimulator/Native`
6. 添加链接参数：`-lidevice_ffi -lc++ -lz`
7. 配置 `Info.plist` 的后台模式与定位权限（参考 `LocationSimulator/App/Info.plist`）

### xtool / SwiftPM

仓库根目录的 `python3 build_locsim_xtool.py` 会把源码转换为可供 [xtool](https://github.com/xtool-org/xtool) 使用的 SwiftPM 包。它会自动收集所有 `*.swift` 文件，新增源文件无需手动注册。

## 使用说明

### 1. 导入配对文件

打开 **设置**（齿轮图标），点击 **导入配对文件**，选择你的 `.mobiledevicepairing` 或 `.plist`。iOS 27+ 还可使用 **创建配对文件（设备端）**。

> 配对文件获取方式：参考 StikDebug 项目的 [PAIRING.md](https://github.com/StikDebug/StikDebug/blob/main/PAIRING.md)，或使用 SideStore/AltStore 的配对工具。

### 2. 配置 VPN

启动 **LocalDevVPN**（或你常用的回环 VPN）并开启。默认设备 IP 为 `10.7.0.1`。

> 非回环场景（如走 Wi-Fi）请在设置中修改设备 IP。

### 3. 模拟位置

- **单点**：点击地图落点，然后点击 **启动模拟**。模拟过程中移动落点会立即生效。
- **路线**：从侧边栏打开「路线模拟」，通过地图点选 / 搜索地点 / 定位按钮设置起点，然后点击 **开始模拟**。
- **导入**：点击导入图标从文件加载坐标（在旧版地图视图中提供）。

### 4. 管理历史与收藏

打开搜索栏旁的时钟 / 星标按钮。向右滑动重命名，向左滑动删除（或从历史加入收藏）。

### 5. 停止模拟

点击 **停止模拟** 清除模拟位置并恢复真实 GPS。

## 项目结构

```
LocationSimulator/
├── App/
│   ├── LocationSimulatorApp.swift        # 应用入口 + 首次引导
│   └── Info.plist
├── Views/
│   ├── MainDrawerView.swift              # 三层抽屉导航
│   ├── OnboardingView.swift              # 首次引导（VPN → 配对）
│   ├── PointSimulationView.swift         # 点模拟：搜索、地图、历史、收藏
│   ├── RouteSimulationView.swift         # 路线模拟：搜索、路径点、回放
│   ├── SettingsDrawerView.swift          # 抽屉使用的设置页
│   ├── SettingsView.swift                # 旧版英文设置（未挂载）
│   ├── OnDevicePairingView.swift         # 设备端配对引导
│   └── LocationSimulationView.swift      # 旧版英文地图视图（未挂载）
├── Services/
│   ├── LocationSimulationSession.swift  # 模拟状态 + 实时坐标更新
│   ├── ConnectionPreflight.swift        # 即时连接门禁 + VPN 链接助手
│   ├── OnDevicePairingService.swift     # 设备端配对实现
│   ├── BackgroundLocationManager.swift  # 定位保活
│   └── BackgroundAudioManager.swift     # 静音音频保活
├── Device/
│   ├── LocationFFIBridge.swift          # idevice 库的 FFI 桥接
│   ├── RemotePairingPortResolver.swift  # Bonjour 端口发现（缓存 / 异步）
│   └── DeviceConnectionContext.swift    # 设备 IP 配置
├── Support/
│   ├── MapLegalHider.swift              # 隐藏地图上的 MapKit Legal 链接
│   ├── PairingFileStore.swift           # 配对文件管理
│   ├── ChinaCoordinateTransform.swift   # GCJ-02 / WGS-84 转换
│   ├── AlertPresenter.swift             # UIKit 弹窗助手
│   └── UserDefaults+Keys.swift          # 设置项键名
└── Native/
    ├── idevice.h                        # C FFI 头文件
    ├── libidevice_ffi.a                 # 编译好的 Rust FFI 库
    └── module.modulemap                 # Clang module map
```

> `LocationSimulationView.swift` 与 `SettingsView.swift` 是最初 StikDebug 风格的英文视图，仅作参考保留，未由 `MainDrawerView` 挂载。Apple 地图归属信息以文字形式保留在 **设置 → 关于** 中。

### 工作原理

1. 应用通过回环 VPN 与 iOS 设备建立 RemotePairing 隧道
2. 连接设备的 RemoteServiceDiscovery（RSD）服务
3. 调用 `location_simulation` API 设置/清除 GPS 坐标
4. 重发定时器每 4 秒重发当前坐标以维持伪装
5. 后台保活机制防止 iOS 挂起应用

## 支持的坐标导入格式

| 格式 | 扩展名 | 说明 |
|------|--------|------|
| GPX | `.gpx` | 路点、轨迹点、路线点 |
| KML | `.kml` | `<coordinates>` 元素 |
| GeoJSON | `.geojson`, `.json` | FeatureCollection、GeometryCollection |
| JSON | `.json` | `lat`/`lon` 或 `latitude`/`longitude` 键 |
| CSV | `.csv` | 有无表头均可（lat/lon 列） |
| 纯文本 | `.txt` | 空格/逗号/分号分隔的坐标对 |

## 开源许可

本项目从 [StikDebug](https://github.com/StikDebug/StikDebug) 提取，采用 **AGPL-3.0** 许可。详见 [LICENSE](https://github.com/StikDebug/StikDebug/blob/main/LICENSE)。

限速数据由 [OpenStreetMap](https://www.openstreetmap.org/copyright) 贡献者提供（ODbL）。

## 致谢

- [StikDebug](https://github.com/StikDebug/StikDebug) —— 原始项目
- [idevice](https://github.com/jkcoxson/idevice) —— iOS 设备通信的 Rust 库
- [OpenStreetMap](https://www.openstreetmap.org/) —— 路线模拟的限速数据
