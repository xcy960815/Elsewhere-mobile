# Elsewhere Mobile

[English](README.md) | **简体中文**

Elsewhere Mobile 是 iPhone 和 iPad 上的原生定位工具。你可以把本机或同一局域网内另一台已配对设备的模拟位置设到代理出口、常用城市或地图上的一点，用完后点「恢复真实定位」。首次配对需要电脑，之后可以在移动端操作。

## 能做什么

- **跟随代理出口。** 通过本机网络或指定的 HTTP 代理查询出口 IP，使用其估算位置。出口变化时可提醒或自动跟随。「自动改」只作用于上次跟随出口的设备，手选城市或地图点会保留。后台检查时间由系统安排。 IPinfo 的 TLS 连接失败时，App 会通过相同网络或指定代理使用 IPIP 查询出口 IP 和城市，再用 Apple 地理编码估算城市坐标。缺少城市时会提示查询失败。
- **地图选点。** 在大地图上落针、输入经纬度，或用 Apple 地图和 OpenStreetMap 搜地名。大陆地图坐标与设备坐标之间按多边形做 GCJ-02 ↔ WGS-84 转换，修正了首尔被误转、深圳市中心被漏转的问题。港澳台及海外跳过转换。
- **常用城市与多设备。** 内置 11 个城市，可添加、删除和拖动排序。每台设备分别保存配对记录和上次设置的位置，可单独操作，也可选择「同时修改所有设备」应用到所有就绪设备。
- **重连恢复与时区检查。** 目标重启会清除模拟位置。开启「重新连接后恢复定位」，App 检测到设备重新就绪时可重设上次的位置。「上次设置」显示的是操作记录。App 还会检查设备与目标位置的时区偏移，给出调整提示。
- **快捷指令与小组件。** 四个 App Intents 可用于跟随出口、切换到常用城市、设置坐标和恢复真实定位。中号交互式 Widget 提供跟随出口与恢复按钮，iOS / iPadOS 18 起也可把这两个动作加入控制中心。
- **演示与语言。** 配置向导和设置里都可进入 Demo，用模拟设备与示例出口试用。地名查询及部分提示支持简体中文和英文，当前版本的界面仍有仅提供中文的文字。

## 工作原理与系统要求

| 设备角色 | 系统版本 | 能力 |
| --- | --- | --- |
| 运行 App 的宿主 | iOS / iPadOS 17.0+ | 可安装 App、管理配对或运行 Demo。操作本机时还需满足目标要求。 |
| 接受定位的目标 | iOS / iPadOS 17.4+ | 已实现 Lockdown → CoreDeviceProxy → RSD → `com.apple.coredevice.locationservice`，需开启开发者模式。 |
| 接受定位的目标 | iOS / iPadOS 17.0–17.3 | 需要另一条 RemotePairing 协议路径，目前未列为支持。 |

App 静态链接 Rust 库 `ElsewhereCore.xcframework`，通过 `idevice 0.1.68` 的 `TcpProvider` 连到目标的 Lockdown 服务，再通过 CoreDevice 软件隧道发现定位服务，发送设置或清除模拟位置的请求。首次设置可能需要准备开发者磁盘镜像（DDI）。上表给出协议适用范围，具体机型、系统和镜像组合仍需真机验证。[架构说明](ARCHITECTURE.md)

## 首次配对与配置

1. 用 USB 将目标接到电脑，解锁并确认「信任」。在这台已获信任的电脑上打开 `idevice_pair`，选择目标，导出 **Lockdown** 配对记录，将 `.mobiledevicepairing` 或 `.plist` 文件存到宿主的「文件」App。RemotePairing 是另一种凭据格式，改扩展名也无法导入。[idevice_pair](https://github.com/jkcoxson/idevice_pair)
2. 在目标的「设置 › 隐私与安全性 › 开发者模式」中打开开关，按提示重启，解锁后确认开启。
3. 在配置向导填写目标 IP，点「选择配对文件」从「文件」导入。也可在「文件」的系统共享菜单中选择 Elsewhere，再打开主 App 完成导入。可在「设置 › 设备与配对」检查或修改地址。
4. 选择下节的一种通道，允许宿主访问本地网络，点「测试连接」。测试通过后，设置一个容易辨认的地点，在**目标设备**的地图中查看，再点「恢复真实定位」验证清除。

配对文件含有私钥。导入后，每份记录使用独立密钥做 AES-256-GCM 静态加密，密文存于 App 私有目录，密钥存于标记为 `WhenUnlockedThisDeviceOnly` 的钥匙串项。导出的原文件仍需自行保管，请勿附到问题报告中。

## 连接通道与代理共存

**方案 A · 已有路由（推荐默认）。** 在向导中选「已有路由」。连接本机时填已配置的 LocalDevVPN、StosVPN 或 WireGuard 回环对端地址（默认示例为 `10.7.0.1`）。连接另一台设备时，先启用无线配对，填它在同一 Wi-Fi 下的局域网 IP。保持平时用的代理开启，再测试连接。

此模式下 Elsewhere 自身不占 VPN 槽位。如果局域网可直达，或 Surge、Shadowrocket、Loon、Clash 的现有配置能将流量送到目标，就可以保留该代理。另行启动回环 VPN 仍可能占用同一槽位。测试时既要能连到 Lockdown 的 TCP 62078 端口，也要能访问随后协商的服务端口，最终以目标能设置和清除位置为准。

**方案 B · 内置回环（可选）。** 连接本机且没有现成路由时，选「内置通道」，首次在前台批准系统 VPN 配置。内置的 `NEPacketTunnelProvider` 只接管虚拟对端这一条主机路由（IPv4 `/32` 或 IPv6 `/128`），连接期间仍会占用系统 VPN 槽位。

要跟随代理出口，先让代理连通。Elsewhere 会先查询出口，再启动内置通道。开启「操作完成后自动断开」后，操作结束会断开本次由 Elsewhere 启动的通道，释放槽位。第三方代理能否自动恢复取决于它自己的按需连接规则，也可手动重连。

## 从源码构建与侧载

使用装有 Xcode 16+ 和 iOS 模拟器运行时的 Mac。脚本构建 arm64 真机及 Apple Silicon 模拟器切片。先安装工具链，再从仓库根目录运行以下命令。如未安装示例中的模拟设备，请将 `name` 改成本机可用的型号。

```sh
brew install rustup xcodegen cbindgen
export PATH="$(brew --prefix rustup)/bin:$PATH"
rustup toolchain install 1.94.0 --profile minimal
rustup target add --toolchain 1.94.0 aarch64-apple-ios aarch64-apple-ios-sim

cargo +1.94.0 test --locked --manifest-path elsewhere-core/Cargo.toml
scripts/build-rust-ios.sh --all
xcodegen generate
xcodebuild -project ElsewhereMobile.xcodeproj -scheme ElsewhereMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' build test
```

### 选择签名方式

| 使用场景 | Scheme | 安装后可用的通道 |
| --- | --- | --- |
| 免费个人 Apple ID | `ElsewhereMobileFree` | 已有路由。使用 LocalDevVPN、StosVPN 或局域网，在 App 内从「文件」导入配对记录。此目标只占一个 App ID，无扩展或 App Group 依赖。 |
| 有相应能力的付费开发者账号 | `ElsewhereMobile` | 已有路由、内置回环通道，另含 Widget 和共享导入扩展。 |
| AltStore、SideStore、Sideloadly 或其他自签工具 | 推荐免费版 IPA | 由侧载工具完成签名。App 根据安装包内实际的扩展和可访问的 App Group 选择功能。 |

从 Xcode 运行时，把 `Config/Signing.local.xcconfig.example` 复制为 `Config/Signing.local.xcconfig`，选一组示例，填入自己的 `DEVELOPMENT_TEAM` 和唯一的 `APP_BUNDLE_ID`。免费版也可单独指定 `FREE_APP_BUNDLE_ID`。完整版会同步派生三个扩展的 Bundle ID、两个 App Group 和运行时标识，Swift 和 entitlements 均由同一配置驱动。宿主与隧道扩展的开发描述文件需要授权 Packet Tunnel，宿主、Widget 与共享导入扩展也各自需要对应的 App Group。[Apple 签名与权限说明](https://developer.apple.com/documentation/bundleresources/diagnosing-issues-with-entitlements)

### 使用侧载脚本

准备好真机 XCFramework 后执行以下命令。仅构建真机切片可使用 `scripts/build-rust-ios.sh --device`。首次使用可运行 `chmod +x scripts/sideload.sh`，也可以用 `bash scripts/sideload.sh` 调用。

```sh
./scripts/sideload.sh --mode free --check
./scripts/sideload.sh --mode free --bundle-id net.example.myelsewhere --team ABC1234567 --install
./scripts/sideload.sh --mode full --open
./scripts/sideload.sh --mode free --ipa
```

将示例 Bundle ID 和 Team ID 换为自己的值。`--check` 会列出可用证书、Team ID、真机 UDID 和每个目标的本地描述文件匹配情况。连接多台设备时，为 `--install` 加上 `--device <UDID>`。未配置 Team 且只有一张有效开发证书时，脚本会从证书的 OU 自动选择 Team。本地描述文件齐全时优先离线签名，否则由 Xcode 联网申请并安装到设备。

`--ipa` 无需登录 Apple 账号，产物为 `build/sideload/ElsewhereMobile-free-unsigned.ipa`，可交给侧载工具签名。脚本在 `build/sideload/project/` 中生成用于构建或打开的源码副本，每次运行时同步。持久签名设置保存在仓库忽略的 `Config/Signing.local.xcconfig`。免费版和完整版默认共用 Bundle ID；需要并排安装时，为免费版单独设置 `FREE_APP_BUNDLE_ID`。更换 Bundle ID 或签名团队后，原有的配对密钥可能无法读取，请保留受保护的原始配对文件。

## 常见问题

- **锁屏、配对失效或开发者模式未开？** 解锁宿主和目标后重试。若提示配对失效，在目标上重新信任电脑，再导出并导入该设备的新记录。若提示开发者模式关闭，检查重启后是否已解锁并确认开启。
- **DDI 下载、签名或挂载失败？** 下载或校验失败时，检查宿主能否访问镜像源后重试。App 会对照清单校验镜像的 SHA-384。个性化签名失败时检查能否访问 Apple TSS。上传或挂载失败时保持目标解锁、检查通道，再用原始报错确认失败阶段。[DDI 镜像源](https://github.com/doronz88/DeveloperDiskImage)
- **Wi-Fi 版 iPad 恢复后仍显示旧位置？** 清除模拟定位后，没有 GPS 的 iPad 需要靠周边 Wi-Fi 重新定位。先等系统取得新位置。如果长时间未更新，可在「设置 › 隐私与安全性 › 定位服务」关闭再开启定位服务。
- **时区与位置不一致？** 在目标的「设置 › 通用 › 日期与时间」检查。Wi-Fi 设备可开启「自动设置」。蜂窝设备可能优先采用运营商时区，需要匹配模拟位置时，可关闭自动设置并手选目标城市。
- **在哪里看原始报错？** 在失败提示里展开「原始输出」，点「拷贝」。排查时附上失败阶段、宿主和目标的系统版本、所用通道。分享前隐去私钥和设备标识。

## 项目结构

```text
.
├── App/                    App 入口、状态与生命周期
├── Features/               定位、地图、常用城市、设置与配置向导
├── DesignSystem/           共享界面组件与字标
├── Domain/                 坐标、城市、设备状态与出口规则
├── Engine/                 Swift/Rust 桥接、真机与 Demo 引擎
├── Services/               配对、通道、DDI、搜索、坐标转换与时区
├── Intents/                快捷指令动作
├── Widgets/                Widget 与控制中心控件
├── TunnelExtension/        内置回环通道
├── PairingImportExtension/ 系统共享菜单导入
├── elsewhere-core/         Rust 静态库、C 接口与 Rust 测试
├── scripts/build-rust-ios.sh
├── project.yml             XcodeGen 工程与测试 scheme
├── Tests/                  Swift XCTest
└── Licenses/               字标许可
```

## 数据来源与许可

- 项目代码使用 MIT 许可。ELSEWHERE 字标取自 Jost Light，使用 SIL Open Font License 1.1。[MIT License](LICENSE) · [Jost 字标许可](Licenses/Jost-OFL.txt)
- 地名搜索结合 Apple 地图和 OpenStreetMap（Photon 联想、Nominatim 提交搜索）。部分岸线和岛屿轮廓也取自 © OpenStreetMap contributors，衍生顶点按 ODbL 1.0 提供。[OpenStreetMap 版权与许可](https://www.openstreetmap.org/copyright)
- 深港界线取自香港特别行政区政府民政事务总署《地方行政区分界》开放数据。大陆轮廓取自公有领域数据 Natural Earth v5.1.2 Admin 0 Map Units。简化多边形仅用于选择坐标转换区域。[香港开放数据](https://data.gov.hk/en-data/dataset/hk-had-json1-hong-kong-administrative-boundaries) · [政府数据使用条款](https://data.gov.hk/en/terms-and-conditions) · [Natural Earth](https://www.naturalearthdata.com/)

**免责声明。** 请在自己有权管理的设备上使用，并遵守当地法律和相关 App 服务条款。模拟定位可能影响「查找」、天气和叫车等服务，用完请恢复真实定位。
