# Elsewhere Mobile · Architecture & Migration Plan

宿主最低版本为 iOS / iPadOS 17.0。手机直接连接用户已配对的目标设备，目标可以是本机，也可以是同一局域网内的另一台 iPhone 或 iPad。首次建立信任可以借助电脑，日常设置和清除定位在移动端完成。

**功能基线**取自相邻的 Elsewhere 工作树，HEAD 为 `ed381ee`（1.2.0），包含 `PlaceSearch.swift` 和 `Splash.swift` 的本地改动。已通读中文 README、Models、AppModel、Intents、App 入口、全部七个 Services、十个 Views，以及 Rust helper、Cargo 配置和锁文件。外部资料用于核对协议、平台能力与服务约束。

## 1. 四个影响交付的事实

| 问题 | 源码或平台证据 | 移动端决定 |
| --- | --- | --- |
| iOS 17 能安装 App，目标设备能否接受模拟定位还要看协议 | 基线的自动模式能回退到 Mac 上的 Xcode。上游记录显示目标系统 17.0–17.3 早于 Lockdown CoreDeviceProxy。 | 分开记录宿主与目标版本。17.4 起优先验证 TCP → CoreDeviceProxy。17.0–17.3 单列原生 RemotePairing / RSD 可行性试验，须分别证明凭据取得、服务发现及真实 set/clear，方可列入支持范围。[原引擎回退逻辑](https://github.com/Layla-NL/Elsewhere/blob/ed381ee976d9f8e52c46acf5c27cbc2c204b142a/Elsewhere/AppModel.swift#L565) · [上游隧道版本说明](https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/ios17-tunnels.md) |
| 外部回环工具也可能占代理的 VPN 槽位 | Apple 对同类常规隧道 VPN 只允许启用一个配置，每个 App 只能管理自己创建的配置。独立运行的回环 VPN 和同类代理存在竞争。 | 默认沿现有可达路由。代理工作期间能否访问目标，要用真实配对会话验证。内置通道自动断开只释放 Elsewhere 的配置，第三方代理由其按需规则或用户重新连接。[Apple VPN 配置作用域](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager) |
| 上次成功设置的位置与设备当前实测位置是两种信息 | helper 提供 set 和 clear。AppModel 以离线后重新出现触发重设，首次枚举只建立在线集合，重试上限为 15。 | 按 UDID 保存成功记录、时间及来源。冷启动缺少证据时显示“上次设置”，将重连、确认重启、执行结果未知分别处理。[重连检测](https://github.com/Layla-NL/Elsewhere/blob/ed381ee976d9f8e52c46acf5c27cbc2c204b142a/Elsewhere/AppModel.swift#L329) · [协议动作](https://github.com/Layla-NL/Elsewhere/blob/ed381ee976d9f8e52c46acf5c27cbc2c204b142a/helper/src/main.rs#L412) |
| 大陆坐标的误差主要可能出在区域判定 | 实际运行基线函数，首尔 `37.5665, 126.9780` 被转换成 `37.567402, 126.983083`，深圳市中心 `22.5431, 114.0579` 却跳过了转换。 | 保留正变换及六次反解，把矩形限于粗筛，最终使用有版本和许可的行政边界多边形，显式排除港澳台及海外。厘米级验收针对数学往返误差，地图基准另用地标验收。[原区域判定与反解](https://github.com/Layla-NL/Elsewhere/blob/ed381ee976d9f8e52c46acf5c27cbc2c204b142a/Elsewhere/Services/ChinaCoordinate.swift#L11) |

## 2. 工程与执行边界

```text
project.yml                           XcodeGen，Swift 6，最低 iOS 17
App/                                  依赖组装、前后台生命周期、文件入口
Domain/                               DeviceID、WGS84、城市、按设备保存的定位记录、规则与状态机
Engine/                               LocationEngineProtocol、RustLocationEngine、DemoLocationEngine
Services/                             ExitIP、PlaceSearch、ChinaCoordinate、TimeZone、DDI
                                      PairingStore、TunnelCoordinator、Notifier、状态持久化
Features/{Location,Map,Cities,Settings,Onboarding}/
                                      各页的 SwiftUI View 和轻量 Store
DesignSystem/                         主题、反馈、CodeField、WordmarkGlyphs、Splash
Intents/                              四个动作、CityEntity、CityQuery、ElsewhereShortcuts
Widgets/                              WidgetKit 和 iOS 18 Control Center 控件
TunnelExtension/                      可选的 NEPacketTunnelProvider
PairingImportExtension/               系统共享菜单收件入口
Resources/  Licenses/                 三个 String Catalog、离线地理数据及许可
elsewhere-core/{src,include}/         Rust staticlib、cbindgen 头文件、module.modulemap
scripts/build-rust-ios.sh             --device、--simulator、--all
Tests/                                XCTest、协议及故障夹具，Rust 单测随 crate
```

App、Widget、Tunnel、共享导入扩展和 Unit Tests 分别设 target。外部通道版和内置通道版可由同一宿主模板生成，内置版给宿主及 Tunnel 配置 `com.apple.developer.networking.networkextension` 的 `packet-tunnel-provider` 值。App 与 Widget 的 App Group 只共享显示快照，App 与导入扩展使用另一个受保护的收件区。主 App 的 Info.plist 声明 `NSLocalNetworkUsageDescription`、后台 fetch 和 `BGTaskSchedulerPermittedIdentifiers`。首次本地网络授权在前台连接向导触发。实际签名所需的 App ID、App Groups 和 profile 按 Team 核验。[Apple 能力表](https://developer.apple.com/help/account/reference/supported-capabilities-ios) · [本地网络权限](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

View 和展示用 Store 在 `@MainActor`，领域值为 `Sendable`。所有写入口共用按设备串行的命令服务，通过 `LocationEngineProtocol` 的异步 probe、prepare、set、clear 驱动单台设备。网络查询返回后、真正下发前复核设备、开关和操作版本，手动选择优先。文件读写、摘要计算和协议运行在后台，外部 URL、数组和数值均经可失败解析。Swift 文件按职责拆分，通常控制在 250–350 行以内。Demo 在依赖组装处替换引擎、地图数据、出口、通知和存储，使用内存配置与离线样例，模拟器和预览可验证零外网请求、零生产配置写入。

## 3. 配对与两层通道

**导入。** 向导依次提示开启开发者模式并完成重启确认、导入配对文件、选择通道并测试。可在已获设备信任的电脑上用 `idevice_pair` 导出 **Lockdown** 记录。支持 `fileImporter`、从“文件”打开及系统共享菜单。主 App 在 security-scoped URL 有效期内读取有大小限制的 `.mobiledevicepairing` 或 `.plist`，将 XML 或二进制内容交给 `PairingFile::from_bytes`。共享扩展用受保护且排除备份的收件区交接，导入完成或过期后清理。校验证书、密钥及必需字段，UDID 和设备名允许缺失。首次认证后用 `UniqueDeviceID` 和 `DeviceName` 绑定，重连核对身份，防止局域网 IP 重分配后写错设备。RemotePairing 记录使用独立格式识别。配对原文按记录加密存于 App 私有目录，密钥放在 `WhenUnlockedThisDeviceOnly` Keychain，支持多份记录、替换与删除。[配对工具](https://github.com/jkcoxson/idevice_pair) · [锁定版本的 PairingFile](https://github.com/jkcoxson/idevice/blob/d32c8189c51c2789496b0768039419c3705498c3/idevice/src/pairing_file.rs)

| 连接方式 | 用户操作与成功条件 |
| --- | --- |
| A · 已有路由，默认 | 选择已配置的 LocalDevVPN、StosVPN、WireGuard 对端地址，或输入已开启无线配对的局域网目标 IP。可预填 `10.7.0.1`，这是可修改的虚拟对端地址。LAN 直连或当前代理本身提供目标路由时，可保留该代理。测试先连 Lockdown 的 TCP 62078，再验证配对身份、协商的服务端口和 RSD。界面按失败阶段给出诊断。 |
| B · 内置通道，可选 | 用户在前台授权启用 Elsewhere 的 `NETunnelProviderManager` 配置。扩展负责目标主机路由（IPv4 /32 或 IPv6 /128）、双向数据收发及停止清理。单机侧载试验须在没有电脑和外部回环 App 时，验证本机 Lockdown、协商端口和真实 set/clear。提供“操作完成后自动断开”，批量操作共享一次连接，成功、失败、取消均收尾，并覆盖宿主中断后的回收。Apple 对 packet tunnel 的支持用途有限，侧载可用性及分发条件分别验收。[Apple TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) |

**出口采样顺序。** 用内置通道执行“跟随出口”时，先在用户选定的网络路径上取得出口、坐标和采样时间，再启用内置通道。忽略自身切换造成的路径事件，自动断开只作用于本次启动的自有通道。若已手动切走代理且没有新鲜样本，此前的代理出口无法推断，需重连代理或经仍可达的显式 HTTP 代理重新采样。后台检测只复用已有通道。系统 VPN 解决到 Lockdown 的可达性，CoreDevice 软件隧道负责设备内部的 RSD 和定位服务，两者分别报告状态。

## 4. Rust 与 Swift 的契约

沿用 `Cargo.lock` 和 `idevice = "=0.1.68"`，关闭默认 features，启用 `ring, tcp, core_device, core_device_proxy, rsd, xpc, tunnel_tcp_stack, mobile_image_mounter, tss`。由 `TcpProvider` 持有目标 IP、可选 IPv6 scope 和配对记录。iOS 的可执行模块使用 SwiftUI、系统服务与静态库，桌面的 AppKit、Process、SMAppService、Carbon、devicectl 及 usbmuxd 路径止于 macOS 基线。构建脚本分别产出 `aarch64-apple-ios`、`aarch64-apple-ios-sim`，用 `xcodebuild -create-xcframework` 将所选平台切片与头文件打入 `ElsewhereCore.xcframework`。[基线依赖](https://github.com/Layla-NL/Elsewhere/blob/ed381ee976d9f8e52c46acf5c27cbc2c204b142a/helper/Cargo.toml#L9)

| C ABI 入口（拟定） | 责任与所有权 |
| --- | --- |
| `ew_abi_version`、`ew_engine_create`、`ew_engine_destroy` | 版本化头文件、opaque 引擎句柄、专用后台线程上的 Tokio runtime。销毁前取消并排空任务及回调。 |
| `ew_pairing_inspect(bytes, len, …)` | 文件输入与内存输入共用解析器，只返回可展示的元数据。Swift 在后台调用。 |
| `ew_submit(engine, jobID, request, callback, context)` | 命令涵盖 probe、DDI 状态及校验、挂载、设置和清除。C 请求包含带长度的切片和定长数值，Rust 在返回前复制输入。接受的任务按序回报阶段进度及唯一终态。回调缓冲只在回调期间有效，Swift 当场复制。 |
| `ew_cancel(engine, jobID)` | 支持超时与 Swift Task 取消，回调上下文保留到终态。若命令已送出而回执丢失，记录“结果待确认”。Rust panic 在 ABI 边界转为失败。 |

**设备状态机。** 未导入记录时进入向导。导入后探测 TCP，超时进入“通道未就绪”。Lockdown 拒绝 HostID 进入“配对失效”，设备锁定进入“等待解锁”。会话读取 `DeviceName / ProductType / DeviceClass / ProductVersion / TimeZone / TelephonyCapability`，在 `com.apple.security.mac.amfi` 域读取 `DeveloperModeStatus`。明确关闭时提示开启，字段未知时继续能力探测。连接就绪后，首次 set 可经过“准备开发者组件 → 操作中 → 就绪”。已挂载的设备直接进入操作中。掉线回到待连接，成功记录只在收到协议回执后提交。个性化签名另读 `UniqueChipID`。

**DDI 与定位。** `DDIRepository` 管理下载和缓存，Rust 管理协议和摘要验证。流程依据基线 helper 的实际连接顺序。[下载与校验](https://github.com/Layla-NL/Elsewhere/blob/ed381ee976d9f8e52c46acf5c27cbc2c204b142a/Elsewhere/Services/HelperEngine.swift#L172) · [签名、上传与复查](https://github.com/Layla-NL/Elsewhere/blob/ed381ee976d9f8e52c46acf5c27cbc2c204b142a/helper/src/main.rs#L291)

1. 先识别挂载的个性化开发镜像。基线仅判断 `CopyDevices` 非空，移动端辨认镜像类型并区分探测失败。clear 在确认未挂载时幂等完成。普通 set 按需准备 DDI。
2. 同一次下载固定到镜像仓库的同一修订，将 `BuildManifest.plist`、`Image.dmg`、`Image.dmg.trustcache` 放入同卷临时目录。后台流式计算映像 SHA-384，要求命中 `BuildIdentities[*].Manifest.PersonalizedDMG.Digest`。三件齐备且校验通过后提交不可变版本目录，原子切换 Application Support 中的当前版本指针。在用的版本保留到操作完成。多设备共用同一下载，中断后仍可使用上一份兼容缓存。哈希验证文件配套，挂载授权来自 Apple 的设备签名。[镜像仓库](https://github.com/doronz88/DeveloperDiskImage)
3. 用独立 mounter 连接查询设备已有的签名。缺签名时新建连接，基于设备 ECID 和清单向 Apple TSS 申请，再用全新连接上传并挂载。上传或挂载丢失回复时重连复查，确认已挂载即成功。仍未挂载且为 socket 错误时等待一秒，只重试一次。显示下载、校验、签名、上传、挂载各阶段。锁定版 TSS 客户端使用自己的网络传输，首次挂载单独验证 Apple 服务可达性。[锁定版 TSS 客户端](https://github.com/jkcoxson/idevice/blob/d32c8189c51c2789496b0768039419c3705498c3/idevice/src/tss.rs)
4. `CoreDeviceProxy → create_software_tunnel() → RsdHandshake → com.apple.coredevice.locationservice`。在 `com.apple.coredevice.feature.simulatelocation` 下调用 `com.apple.coredevice.action.setsimulatedlocation` 或 `com.apple.coredevice.action.clearsimulatedlocation`。set 接受有限且合法的 WGS-84 经纬度。新系统、机型及 DDI 构建号进入兼容矩阵，上游已有 Cryptex1 组件格式，对确需该路径的设备单独落实适配与实测。[上游镜像格式](https://github.com/doronz88/DeveloperDiskImage/blob/main/README.md)

Swift 用 `LocalizedError` 将 `locked`、`not_paired`、`not_found`、`ddi_missing`、`ddi_mount`、`no_service`、`tunnel_unavailable`、`failed` 映射为中英文原因和下一步操作。开发者模式关闭属于独立设备状态，用户取消属于操作终态。错误详情携带阶段、设备别名与完整错误链，支持展开、复制，凭据、私钥及签名票据从日志源头排除。

## 5. 用户操作与领域规则

| 功能 | 行为与边界 |
| --- | --- |
| 跟随代理出口 | 默认从运行 Elsewhere 的手机当前网络请求 `https://ipinfo.io/json`，解析 IP、城市、地区、国家、坐标及组织/ASN。高级 HTTP 代理接受 `host:port` 和 `[IPv6]:port`，用 iOS 17 的 `URLSessionConfiguration.proxyConfigurations` 配置 HTTP CONNECT，禁止失败后退回直连。代理只用于出口查询。LAN 目标设备的互联网出口可能与控制端不同。[Apple 会话代理 API](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/proxyconfigurations) |
| 变化检测 | 总开关控制 UI、Intent、通知、Widget 和后台任务。关闭时取消在途请求、使迟到响应失效，隐藏出口卡、地图标注和检测入口，更新 Widget。前台每 30 秒先查 `https://api.ipify.org`，失败回退 `https://ipinfo.io/ip`。合并 `NWPathMonitor` 事件，回到 `scenePhase.active` 且数据超过 60 秒时刷新。首次采样建立基准。IP 变化触发详情查询，失败保留待重试事件。分流或 IPv4/IPv6 导致两个服务报告不同出口时提示差异，暂停这次自动应用。 |
| 自动跟随与通知 | 默认“提醒我”。“不检测”停变化轮询，保留手动刷新。“自动改”逐台检查当前来源仍为 `.exitIP` 且 IP 确实变化。城市、自定义及无模拟记录只提醒。点击通知或“改过去”时复核开关、目标和事件有效期。系统保留的旧快捷指令也经过同一开关。`BGAppRefreshTask` 获调度时做短检查，到期取消，条件不足时留下可操作提醒。[Apple 后台调度](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app) |
| 多设备、清除与恢复 | 支持自动选择、指定 UDID、同时操作所有就绪设备。批次开始时固定目标，按台记录结果，只更新成功设备。恢复真实定位也覆盖上次同批已成功且当前就绪的设备，保留失败或缺席设备的状态。Wi-Fi iPad 提示重新定位可能需要片刻。启用重连恢复时按设备重放最近成功坐标，锁屏等待解锁或后续探测，最多 15 次尝试。冷启动可用先前确认的挂载状态消失等证据触发重放。只有网络抖动时按“重连”表述。新手动操作、成功 clear 或关闭自动恢复会使旧恢复任务失效。 |
| 地图与地名 | 标准、混合、卫星底图，分别标出上次成功模拟、代理出口、待应用图钉。点击或长按落点，异步反查名称时校验当前图钉。地图操作、城市表单、Intent 共用坐标校验，支持中英文逗号及空白。手输、Photon、Nominatim 和出口数据为 WGS-84。Apple 地图输入输出经单独适配器，在已核实的大陆 GCJ-02 数据路径上转换一次。正反向、边境两侧及港澳台分别用基准点校验。 |
| 混合搜索 | `MKLocalSearchCompleter` 与 400 ms 防抖的 Photon 并行，显示来源图标。提交时优先解析坐标，随后 Nominatim 精确查询，最后回退 Apple 候选或自然语言搜索。取消旧查询、校验结果范围并分别显示服务故障。两个 OSM 服务携带应用标识、`User-Agent` 和 `Accept-Language`，展示署名。公共 Nominatim 限整个应用所有用户合计每秒一次，仅用于用户提交的搜索。缓存结果并允许免发版切换端点。公开分发若超出总额度，使用有容量的供应商或自托管 Nominatim，计入运营成本。[Nominatim 公共服务政策](https://operations.osmfoundation.org/policies/nominatim/) · [Photon 服务说明](https://github.com/komoot/photon#readme) |
| 常用城市与时区 | 按原顺序及原坐标预置柏林、法兰克福、伦敦、巴黎、阿姆斯特丹、纽约、洛杉矶、旧金山、东京、香港、新加坡。支持应用、添加、成对粘贴、地图收藏、删除、拖排和二次确认重置，稳定城市 ID 供快捷指令使用。设置定位满 60 秒后，用目标的 Lockdown 时区与地理编码所得时区比较同一时刻的 GMT 偏移，包含夏令时。包内 IANA 代表点表供离线估算，边界附近标估计或未知。Wi-Fi 设备提示检查自动设定，蜂窝设备提示运营商可能影响结果，可在“设置 › 通用 › 日期与时间”手选城市。蜂窝能力未知时给通用指引。[基线城市](https://github.com/Layla-NL/Elsewhere/blob/ed381ee976d9f8e52c46acf5c27cbc2c204b142a/Elsewhere/Models.swift#L31) · [IANA 时区数据](https://www.iana.org/time-zones) |

## 6. 界面与系统入口

- **iPhone** 用四个 Tab。“定位”首先显示目标设备、上次设置及恢复操作，随后是出口和城市快捷网格。“地图”全屏，顶部浮动搜索与底图选择，底部可拖动操作卡显示名称、GPS 坐标、收藏、应用及恢复。“城市”使用可筛选的编辑列表和添加 Sheet。“设置”集中设备、配对、通道测试、出口、重连恢复、演示与关于。
- **iPad** 在常规宽度使用 `NavigationSplitView`，侧栏保持栏目与当前设备上下文，详情列承载地图或表单。分屏变窄时采用紧凑导航。两端均使用语义色、等宽数字、触觉反馈、安全区、Dynamic Type 和 VoiceOver 标签。下载、挂载、查询、逐台执行均有进度，操作期间合并重复点击。
- **快捷指令与小组件** 共用跟随出口、改到常用城市（`CityEntity/CityQuery`）、改到坐标、恢复真实定位四个 App Intent，保留 `ElsewhereShortcuts` 和中英 Siri 短语。Widget 显示选中设备的定位记录、出口和更新时间。iOS 17 的跟随及恢复按钮使用 `Button(intent:)`，选用主 App 进程执行（首版 `openAppWhenRun = true`），点击后直接执行并写回结果。时间线只读快照。iOS 18 控制中心控件复用相同动作，按可用版本注册。[Apple 交互式 Widget](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- **桌面入口的迁移** 将菜单栏和全局快捷键的动作交给上述系统入口，登录项的刷新职责交给场景生命周期和后台调度。首次开通无线连接由已获信任的电脑完成，移动端可读取 `EnableWifiConnections` 辅助诊断。
- **品牌与语言** 保留 Jost Light 字形、H 的高光及 `Licenses/Jost-OFL.txt`。首次 Splash 支持点击和拖动波纹，进入三步向导。CodeField 使用 Canvas/CoreText，常态低帧率，交互短暂提帧，后台暂停，低电量或减弱动态效果时绘制静帧。沿用中文键及英文开发语言，`Localizable.xcstrings / AppShortcuts.xcstrings / InfoPlist.xcstrings` 覆盖简中、英文及英文回退。地理编码在旧 SDK 使用 CLGeocoder/placemark，iOS 26 API 同时受 `#if compiler(>=6.2)` 和 `#available(iOS 26.0, *)` 保护。

## 7. 实施顺序与验收

| 阶段 | 可验证的交付 |
| --- | --- |
| 1 · 工程与规则 | 生成 XcodeGen 工程、App 与扩展骨架、Demo 依赖、两种 arm64 静态库切片。构建 iPhone/iPad Simulator。XCTest 校验大陆往返精度、深圳/香港两侧、澳门、台湾、首尔，坐标分隔符/非有限值、代理地址/空主机/端口越界、出口策略和状态流转。 |
| 2 · 优先证明真机链路 | Rust 单测覆盖参数、错误码、XML/二进制 pairing、可选 UDID、错误密钥、Manifest 摘要命中/不匹配。Swift XCTest 走同一 FFI 校验 DDI。先用有路由的已配对真机完成首次挂载、set、clear，由目标设备另一位置消费 App 观察变化。分别验本机与 LAN，测锁屏、信任失效、已有 DDI、签名失败、挂载回执丢失及单次重试。单列早期 17.x 与较新 DDI 格式的设备结果。 |
| 3 · 内置通道与操作恢复 | 用具备对应权限的签名构建单独验证 B。实测代理切换前的出口、通道生命周期、动态服务端口、多设备部分成功、应用中断、清除与重启重放。通过条件含真实请求和设备回执、网络回收，以及第三方代理的实际状态。 |
| 4 · 移动端主流程 | 完成四页、iPad 分栏、向导、品牌、本地化。用受控网络和时钟测试出口关闭后各入口零请求、手动城市与在途自动跟随竞态、前后台及通知、地图三来源/图钉、城市顺序与时区延迟。验证一次搜索服务失败后其余来源可用。 |
| 5 · 系统入口与发布 | 实测四个快捷指令、冷启动 Widget 按钮、可选控制中心、文件和共享导入。覆盖简中/英文/其他语言回退、大字号、深浅色、低电量。交付中英文 README，列出侧载签名、配对获取、代理共存、版本矩阵、原始报错排查。附 Rust 测试结果、Simulator 的 XCTest 数量及 xcresult、按设备与系统版本记录的真机结果。 |

**当前验证范围。** 本机为 Apple Silicon，Xcode 16.2、Swift 6.0.3、iOS SDK 18.2，已安装 iOS 18.3 模拟器运行时。原锁文件在临时空库中仅将 `usbmuxd` feature 换为 `tcp`，macOS 主机的 `cargo check --lib --offline --locked` 通过。Swift 6 针对 iOS 17 模拟器目标的 HTTP CONNECT 配置类型检查通过。另已实际运行原坐标函数复现上述区域误判。本次交付为架构设计，移动端的 `cargo test`、App 构建、XCTest 与签名真机测试均待实施。

本机现有 Homebrew Rust 1.94.0 仅含 macOS 标准库。当前 PATH 缺 `rustup`、`xcodegen` 和 `cbindgen`。实施时可用以下命令补齐工具，并用固定 Rust 版本构建。[Homebrew rustup](https://formulae.brew.sh/formula/rustup)

```sh
brew install rustup xcodegen cbindgen
export PATH="$(brew --prefix rustup)/bin:$PATH"
rustup toolchain install 1.94.0 --profile minimal
rustup target add --toolchain 1.94.0 aarch64-apple-ios aarch64-apple-ios-sim
```

工程落地后，从根目录执行下列验收命令。构建脚本使用已固定的 Rust 工具链，Xcode scheme 包含 Unit Tests。真机验收另需具备相应 entitlement 的签名和实际配对设备。

```sh
cargo +1.94.0 test --locked --manifest-path elsewhere-core/Cargo.toml
scripts/build-rust-ios.sh --all
xcodegen generate
xcodebuild -project ElsewhereMobile.xcodeproj -scheme ElsewhereMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' build test
```
