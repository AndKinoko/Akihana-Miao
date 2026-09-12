# Akihana Miao

相机直传网盘的 Android 应用。连接相机（USB 数据线或 WiFi 热点），拍摄后自动把新图拉到手机本地，再按你设定的策略上传到自建的 Rust 网盘。

技术上没有依赖任何厂商 SDK：自实现 PTP / PTP-IP 协议栈（ISO 15740），组包格式以 AeroShutter 的实测代码为蓝本（见 `docs/reference/`），不依赖 SnapBridge 配对。多品牌通过 `CameraDriver` 驱动抽象接入，目前支持：

- **尼康**：USB + WiFi（PTP/IP 双 TCP + 三步握手）。WiFi 新图靠 ObjectAdded 事件推送；USB 靠句柄差集轮询（约 5 秒周期，厂商事件命令在 USB 上不稳定）
- **索尼**：USB 为标准 PTP/MTP；WiFi 走旧世代「发送到智能手机」私有 HTTP 协议（A7M3 及更早的 DIRECT-xxxx 直连世代，新图靠句柄轮询）。Creators' App 扫码配对的 newer 机型不支持，请用 USB

## 功能

- 相机页：品牌选择（自动/尼康/索尼，底部抽屉菜单）+ USB / WiFi 两种连接方式，连接过程有过渡浮层（转圈提示，失败时浮层内展示原因并可重试），连接成功后信息卡显示真实型号、电量与存储余量。
- 相册页：三列缩略图网格，RAW 角标，按拍摄时间倒序。缩略图按视口精确加载（只请求可见范围 ±2 行，滚动停 150ms 后生效），已拉取过的图直接读本地文件秒开，拉图下载进行中缩略图自动让路。点选文件后弹出悬浮选择面板（全选/取消/拉取），点「拉取」直接跳转传输页看队列；相机增删图片实时刷新。
- 拉取一律先保存到本地：文件写入应用目录并可选存入系统相册（图片在 `Pictures/AkihanaMiao`，视频在 `Movies/AkihanaMiao`，RAW 在 `Download/AkihanaMiao`，可按拍摄日期分文件夹），然后按上传策略决定是否上传。
- 传输页三个子页：拉取中（连拍新图先全部登记「排队中」再串行执行，实时进度；断开时队列自动清空）、已拉取（只显示软件专属相册文件夹内容，与系统相册一一对应，多选悬浮窗批量上传）、上传（顶部常驻「全部暂停/全部取消」，每条任务可单独取消——在途上传在分片边界中止，失败可重试）。
- 上传策略三档：保存到本地 / WiFi 环境上传 / 立即上传。WiFi 档通过 Android 网络能力检测判断是否可上网，相机热点不算。条件保护：仅充电时上传、低电量暂停。
- 上传目标是自建 Rust 网盘（`POST /api/files/upload` 流式 multipart），按拍摄日期自动建目录，401 自动重登。
- 后台运行：前台服务保活（常驻通知，锁屏/退后台/Doze 下继续自动拉取和上传），设置页可开关。

## 环境要求

- Flutter 3.35（Windows 下用 `flutter.bat`），JDK 17，Android SDK
- 尼康固件建议升级到最新；相机 USB 模式设为 PTP/MTP（有线），或菜单里开启「连接至智能设备 → Wi-Fi 连接」（无线）
- 索尼机型：USB 模式设为 MTP；WiFi 仅支持「发送到智能手机」直连世代（相机显示 SSID + 密码的那种）
- 测试网盘默认地址 `http://localhost:100`，真机上要改成电脑的局域网 IP，Windows 防火墙放行入站端口，适配的是我的pan\_for\_Photographer\_rust项目

## 构建与运行

```bash
flutter pub get
flutter run            # 真机调试
flutter build apk      # 打包
flutter analyze        # 静态检查
```

## 目录结构

```
lib/
  main.dart             入口，启动直达相机页
  core/                 配置持久化、系统相册封装、后台保活决策
  pan/                  网盘客户端、上传队列、拉取任务中心
  cameras/
    camera_driver.dart  品牌驱动抽象与注册表（按 USB VID 路由）
    camera_session.dart 相机会话抽象（PTP 与 HTTP 两种后端）
    ptp/                PTP 协议核心（组包、事务、USB/WiFi 链路抽象）
    transports/         USB Host 通道、WiFi PTP-IP 链路、网络绑定
    nikon/              尼康驱动（PTP 会话实现）
    sony/               索尼驱动（USB 标准 PTP + WiFi HTTP 适配）
  ui/                   相机、传输、设置三个主页面
docs/reference/         AeroShutter 的 PTP-IP 参考实现（MIT）
```

## 已知限制

- Z6 一代的智能设备 WiFi 只有接入点模式（手机连相机热点后无互联网），所以是本地优先架构：先落图再择机上传。上传与拉图通过进程级网络绑定并行工作。
- 相机同时只允许一个客户端，测试前要关掉 SnapBridge 和官方 App。
- 索尼 WiFi 模式拿不到原始 RAW：相机只提供转出的 JPEG（官方行为），需要原始 RAW 请用 USB；Creators' App 世代（扫码配对）机型不支持 WiFi。
- 索尼 USB 不保证推 ObjectAdded 事件，新图靠句柄差集轮询（约 4 秒周期）发现。
- USB 传输约束（Z6 实测）：分块下载上限 64KB（更大会让相机挂起复位）；不使用 interrupt 事件端点（与 bulk 数据争抢内核管道）；所有 PTP 事务严格串行，USB 接入需在 Manifest 声明 device\_filter（本仓库已配置）。
- 同一时间同一文件只允许一个拉取任务，重复触发会跳过；防重记录在每次连接时从相册和本地目录重建，进程重启后依然有效。
- 国产系统（ColorOS 等）可能额外限制后台：建议把应用加入电池白名单并锁定后台。

## 后续计划

佳能（CCAPI）、松下等更多品牌驱动（接入成本已因驱动抽象大幅降低），iOS 与鸿蒙适配（iOS 定位 WiFi-only）。详细的阶段划分和避坑清单见 `BUILD_SPEC.md`。
