import 'dart:async';
import 'dart:io';

import 'nikon/nikon_driver.dart';
import 'sony/sony_driver.dart';

/// PTP/IP 固定端口
const ptpIpPort = 15740;

/// 新图获取策略：不同品牌对 PTP 事件的实现差异很大
enum NewFileStrategy {
  /// 相机主动推 ObjectAdded 事件（interrupt / 事件通道）
  eventPush,

  /// 周期性发尼康厂商事件检查命令（0x90C1），解析事件数组
  eventPoll,

  /// 不保证推事件，用 GetObjectHandles 差集轮询兜底（索尼等）
  pollHandles,
}

/// 可发现的相机
class DiscoveredCamera {
  const DiscoveredCamera({
    required this.brand,
    required this.id,
    this.vendorId = 0,
    this.label,
  });
  final String brand; // nikon / sony / canon ...
  final String id; // USB: 设备名；WiFi: ip
  final int vendorId; // USB VID（品牌路由用）
  final String? label;

  @override
  String toString() => label ?? '$brand:$id';
}

/// 品牌驱动抽象：发现 + 连接 + 新图策略。
/// 每个品牌一个实现（尼康/索尼/佳能…），CameraHub 只面向本接口。
abstract class CameraDriver {
  String get brand;

  /// 该品牌 USB vendorId 列表（发现时按此过滤/归属品牌）
  List<int> get usbVendorIds;

  NewFileStrategy get newFileStrategy => NewFileStrategy.eventPush;

  /// 轮询拉新图周期（仅 pollHandles 策略生效）
  Duration get pollInterval => const Duration(seconds: 4);

  /// 枚举本品牌的 USB 相机
  Future<List<DiscoveredCamera>> discoverUsb();

  Future<CameraSession> connectUsb(String id);

  /// WiFi 连接（尼康 PTP/IP / 索尼旧协议 HTTP 等，各品牌自定）
  Future<CameraSession> connectWifi(String host);

  /// 探测相机热点地址；不支持返回 null
  Future<String?> discoverWifiHost() async => null;

  /// 快速探测 host 是否为本品牌可达的相机
  Future<bool> probeWifi(String host) async => false;
}

/// 品牌注册表：发现聚合 + VID/品牌路由
class CameraDrivers {
  CameraDrivers._();

  static final List<CameraDriver> all = [
    const NikonDriver(),
    const SonyDriver(),
  ];

  /// 枚举指定品牌范围的 USB 相机（带品牌归属；drivers 缺省=全部品牌）
  static Future<List<DiscoveredCamera>> discoverUsb([
    List<CameraDriver>? drivers,
  ]) async {
    final out = <DiscoveredCamera>[];
    for (final d in drivers ?? all) {
      try {
        out.addAll(await d.discoverUsb());
      } catch (_) {
        /* 单品牌发现失败不影响其他 */
      }
    }
    return out;
  }

  static CameraDriver byBrand(String brand) =>
      all.firstWhere((d) => d.brand == brand, orElse: () => all.first);

  /// PTP/IP 端口探测（尼康等 PTP/IP 品牌）
  static Future<bool> probePtpIp(
    String host, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final s = await Socket.connect(host, ptpIpPort, timeout: timeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
