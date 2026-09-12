# Akihana_Miao 相机直传 App — 构建规范

## 0. 目标
Android App：尼康 Z6（一代）拍摄后自动把新图拉到手机，并上传到自建 Rust 网盘
（F:\RUST\111\pan_for_Photographer_rust，只做客户端，禁止改动网盘项目）。
USB 有线连接作为兜底。后续覆盖：佳能、索尼、iOS、鸿蒙。

## 1. 技术栈与平台策略
- UI 框架：Flutter（Dart）。Android 首发，iOS/鸿蒙后续覆盖。
- 协议核心：纯 Dart 实现 PTP / PTP-IP，不依赖厂商 SDK（尼康官方 SDK 无移动端）。
  协议层放独立目录，接口稳定，便于未来平移 Rust（鸿蒙路线 B 用）。
- 原生代码最小化（Kotlin，仅三件事）：USB Host 通道、前台服务、socket 网络绑定。
- 插件白名单（越少越利于鸿蒙移植）：dio（或纯 HttpClient 薄封装）、
  path_provider、shared_preferences。禁大杂烩插件。
- 平台矩阵：
  - Android：PTP/IP + USB + 全部上传策略（完整功能）。
  - iOS（后期）：仅 PTP/IP（iOS 无法 USB Host 访问相机，明示此限制）。
  - 鸿蒙（后期）：路线 A = OpenHarmony-SIG flutter_flutter 分支（优先评估）；
    路线 B = ArkTS UI + Rust 核心（NAPI）。

## 2. 设计前提（重要事实）
- Z6 一代智能设备 WiFi 仅有 AP 模式：手机连相机热点后无互联网 → 必须本地优先：
  拉图 → 存本地 → 队列择机上传。
- 上传时机三档：仅 WiFi（可指定 SSID）/ 立即上传（走默认网络，可为蜂窝）/ 手动。
- 相机 socket 绑定 WiFi 网络、上传走默认网络，二者并行（Android
  ConnectivityManager.requestNetwork + network.bindSocket，参考 AeroShutter）。
- 「拍摄后自动上传」= 监听 ObjectAdded 事件自动拉新图；不做遥控拍摄。

## 3. 网盘客户端契约（已从前端源码核实）
- 响应统一信封 { success, data, error }。
- POST /api/auth/login { username, password } → data.token（JWT，
  后续请求带 Authorization: Bearer <token>）。
- POST /api/files/upload，multipart：file（必须）、folder_id（可选；
  禁止传 0 → 会产生孤儿数据；不传即根目录）。流式上传、恒定内存。
- POST /api/folders { name, parent_id }；GET /api/folders?parent_id=；
  GET /api/files?folder_id=；媒体/下载支持 ?token= 查询参数。
- 登录设置页：URL + 账号 + 密码。默认 URL = http://localhost:100（测试），
  可随时改为生产地址。真机调试需填 PC 局域网 IP。
- 上传目录策略：默认在根目录按拍摄日期自动建 yyyy-MM-dd 文件夹。

## 4. 架构与目录
lib/
  main.dart
  core/            # 配置、日志、Result 封装
  pan/             # api_client、models、auth、upload_queue、dedupe
  cameras/
    camera_driver.dart    # 品牌驱动抽象 + 发现/连接接口
    ptp/                  # PTP 会话核心：组包/事务/会话/事件分发（与传输无关）
    transports/
      transport.dart      # 抽象传输层
      usb_transport.dart  # Android USB Host（经 MethodChannel）
      wifi_transport.dart # TCP socket（PTP/IP）
    nikon/                # nikon_driver + Z6 profile（GUID、分块、能力位）
    canon/ sony/          # 二期/三期占位
  ui/              # 登录、连接、图库、传输队列、设置

接口骨架：
abstract class CameraDriver {
  String get brand;
  Future<List<DiscoveredCamera>> discover();
  Future<CameraSession> connect(DiscoveredCamera c);
}
abstract class CameraSession {
  Stream<ObjectAdded> get objectAdded;
  Future<List<ObjectInfo>> listObjects({int? storageId});
  Future<Stream<List<int>>> downloadObject(int handle,
      {void Function(int received, int total)? onProgress});
  Future<void> close();
}

## 5. 尼康实现要点（从 Z6 开始）
WiFi（PTP/IP），以 AeroShutter 开源实现为移植蓝本：
- TCP 15740；双连接：命令/数据连接 + 事件连接；事件连接必须在 OpenSession 前绑定。
- InitCommandRequest 携带固定 16 字节 GUID + friendly name（与尼康官方 App 一致，
  相机视为已配对主机，不再弹确认）。
- 拉图用 GetPartialObject 分块（约 4 MiB）+ 断点续传；缩略图 GetThumb/大缩略图。
- ObjectAdded 事件驱动「拍后自动落图」；另支持相机上「发送至智能设备」队列。
- Z6 profile：默认网关探测 + 192.168.1.1 + 子网扫描并发探测，自动发现相机。
- 连接流程：相机菜单开启「连接至智能设备 → Wi-Fi 连接」→ 手机连相机热点 → App 连接。

USB（Android USB Host，兜底通道，最稳定）：
- C-to-C 线直连；相机 USB 设为 PTP/MTP 模式。
- Android UsbManager 找 Still Image 接口（class 6），bulk in/out + interrupt in。
- PTP over USB 容器封装按 PIMA 15740（Command/Data/Response/Event 容器类型，
  参考 libgphoto2）；事件走 interrupt 端点。同一 PtpSession 核心复用。

## 6. 上传管线
拉取 → 本地缓存（app 目录；「存到系统相册」为可选开关）→ 队列
（去重：文件名+大小+修改时间）→ 按上传时机策略出队 → 按日期建目录后上传。
重试：网络错误/5xx 指数退避（≤2 次），4xx 不重试，401 自动重登。
传输页展示进度、失败原因、手动重试。大文件走流式 multipart，恒定内存。

## 7. 里程碑与验收
- M0 脚手架 + 网盘打通：登录页（URL/账号/密码）、手动选文件上传、
  基础队列与进度。验收：真机登录测试服务器并成功上传一张图。
- M1 PTP 核心 + USB 传输：USB 连 Z6 → 列出对象 → 下载一张 JPG 到本地。
  验收：USB 拉图成功（此通道确定性最高，先验证 PTP 核心正确性）。
- M2 WiFi PTP/IP：握手、双连接、GUID 身份、自动发现、ObjectAdded 监听。
  验收：相机 WiFi 直连，拍照后数秒内新图自动落到本地。
- M3 自动上传 + 策略：上传时机三档、去重、日期目录、网络绑定并行、前台服务。
  验收：拍照 → 图出现在网盘对应日期目录。
- M4 设置与打磨：网盘配置、WiFi 策略、相册开关、日志页。
- M5 佳能：CCAPI（HTTP over WiFi，官方 API）驱动。
- M6 索尼：Camera Remote API（SSDP 发现 + JSON-RPC）驱动。
- M7 iOS（仅 PTP/IP）与鸿蒙路线评估。

## 8. 避坑清单（历史教训 + 调研结论，逐条遵守）
1. 禁止走 SnapBridge BLE 配对路线（Blowfish 握手 + 传统蓝牙双栈 + 机型密钥，
   社区验证不可行）。WiFi 直连 + GUID 身份伪装是正解。
2. 事件连接必须先于 OpenSession 绑定；OpenSession 组包以 AeroShutter 实测代码
   为准，不凭文档猜测（上一项目 tid=0 教训）。
3. 相机同时只允许一个客户端：测试前关闭 SnapBridge / 官方 App。
4. 连接失败相机会自动关热点，需在相机上重新开启。
5. ColorOS：Log.d 会被吞 → 日志用 Log.i；前台服务晚启动（会话建立成功后再启）。
6. 真机上 localhost ≠ PC：测试时填 PC 局域网 IP；Windows 防火墙放行入站 TCP 100。
7. Android 明文 HTTP：network_security_config 或 usesCleartextTraffic 放行。
8. folder_id 传 0 会产生孤儿数据：不传或传真实 id。
9. Windows 下用 flutter.bat / dart.bat；同文件并行编辑会互相覆盖；
   Kotlin 增量缓存损坏时 flutter clean。
10. 上传必须流式（对齐网盘后端约束）；服务器端口避开 Chromium 保留端口。

## 9. 参考实现（必读）
- AeroShutter（MIT）github.com/subhashraveendran/aero-shutter：
  Go internal/ptpip 与 mobile 的 TS 实现是主要移植蓝本；
  internal/camera 含 Z6 profile；WMU_PARITY_AUDIT.md 是协议实测笔记。
- libgphoto2：PTP over USB 容器封装参考（ptp.c / ptpusb.c）。
- 佳能 CCAPI、索尼 Camera Remote API：M5/M6 时再细化。

## 10. 环境
Windows + flutter.bat；JDK 17；Android SDK；真机 USB 调试。
Z6 固件建议升到最新 3.0x。测试网盘：http://localhost:100（App 内可改）。
