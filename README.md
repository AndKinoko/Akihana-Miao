# Akihana Miao

相机拍完，照片自动进手机，再自动传到你自己的网盘。
协议栈是自己用 Dart 写的，不依赖任何厂商 SDK，也不用 SnapBridge 之类的官方 App 配对。

支持的相机：

- **尼康** —— USB / WiFi
- **索尼** —— USB；旧款还支持 WiFi（相机能显示 SSID 和密码的那些）
- **佳能** —— USB / WiFi（WiFi 需在相机菜单里开启 Camera Control API）

> 目前只有尼康 Z6 做过完整实机测试，其余机型是否可用欢迎反馈。

## 怎么用

1. 设置 → 私有网盘：填地址、账号、密码，登录
2. 相机页选品牌，点 USB 或 WiFi 连接
3. 设置 → 拉取策略：勾选要自动拉的类型（默认 JPEG + NEF）
4. 设置 → 上传策略：选「WiFi 环境上传」或「立即上传」
5. 连上之后正常拍照，新照片会自动进相册并按策略上传

WiFi 连接前，手机要先连上相机的热点。佳能还要先在相机里开 CCAPI。

## 安装

从 [Releases](https://github.com/AndKinoko/Akihana-Miao/releases) 下载
`Akihana-Miao-v1.1.0.apk` 装到手机上，需要 **Android 10 及以上**。
仓库里不含安装包（`*.apk` 已在 `.gitignore` 排除）。

自己构建：

```bash
flutter pub get
flutter build apk --release   # 正式包需 android/key.properties，缺失时回退 debug 签名
flutter analyze               # 静态检查
```

需要 Flutter 3.35 和 JDK 17。

## 注意

- 相机同一时间只认一个客户端，连之前请关掉 SnapBridge、Creators' App 这类官方应用
- 连相机热点时手机没网，所以是「先存手机，等有网再传」
- 索尼 WiFi 只能拿到相机转出的 JPEG，要原始 RAW 请用 USB；扫码配对的新机型不支持 WiFi
- 存储卡里照片很多时，连接要花些时间（要逐张读信息）
- 国产系统（ColorOS 等）后台管得严，建议把应用加进电池白名单并锁定后台
- 网盘和相机协议都走明文 HTTP（相机协议本身没有 TLS，网盘地址由你填、没法做白名单），
  填 `http://` 地址时设置页会提示密码为明文传输；服务端支持 HTTPS 就填 `https://`

## 目录

```
lib/
  main.dart      入口
  core/          配置、相册、后台保活
  pan/           网盘客户端、上传队列、拉取任务
  cameras/       品牌驱动 + PTP 协议栈（USB / WiFi 两种链路）
  ui/            相机、传输、设置三个页面
android/         USB 通道、前台保活服务、明文 HTTP 放行（见 AndroidManifest）
```

`docs/`（构建流程、审计记录、第三方参考副本）和 `test/`（单元测试）都是本地资料，
**不随仓库公开**，已经在 `.gitignore` 里排除，仓库里不含也不需要它们。
更细的构建与协议说明见 `BUILD_SPEC.md`。

MIT License，见 [LICENSE](LICENSE)。
