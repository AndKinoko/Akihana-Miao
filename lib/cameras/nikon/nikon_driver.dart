import 'dart:async';
import 'dart:typed_data';

import '../camera_driver.dart';
import '../camera_session.dart';
import '../ptp/ptp_session.dart';
import '../transports/usb_transport.dart';
import '../transports/wifi_link.dart';

export '../camera_session.dart';
export '../ptp/ptp_session.dart' show PtpObjectInfo, PtpEvent, PtpDeviceInfo;

/// 标准 PTP 会话（USB bulk / WiFi PTP/IP 皆可承载）。
/// 尼康全部路径与索尼 USB 走这里。
class PtpCameraSession extends CameraSession {
  PtpCameraSession._(this._ptp, String label) : super(label, 'ptp');

  final PtpSession _ptp;
  final Set<int> _knownHandles = {};

  static Future<PtpCameraSession> fromLink(PtpLink link) async {
    final ptp = PtpSession(link);
    await ptp.openSession();
    return PtpCameraSession._(ptp, link.name);
  }

  static Future<PtpCameraSession> usb(UsbTransport transport) =>
      fromLink(UsbLink(transport));

  static Future<PtpCameraSession> wifi(WifiLink link) => fromLink(link);

  @override
  Stream<PtpEvent> get events => _ptp.link.events;

  @override
  Future<List<int>> getStorageIds() => _ptp.getStorageIds();

  @override
  Future<List<int>> listObjectHandles() => _ptp.getObjectHandles();

  @override
  Future<PtpObjectInfo> getObjectInfo(int handle) => _ptp.getObjectInfo(handle);

  /// 设备信息（厂商/型号）
  @override
  Future<PtpDeviceInfo> getDeviceInfo() => _ptp.getDeviceInfo();

  /// 相机型号：GetDeviceInfo 优先，握手友好名兜底（如 "NIKON DSC Z6_2"）。
  /// 两者都拿不到返回空串，由调用方决定降级文案。
  @override
  Future<String> model() async {
    try {
      final info = await _ptp.getDeviceInfo();
      final m = info.model.trim();
      if (m.isNotEmpty) return m;
    } catch (_) {}
    return _ptp.link.responderName.trim();
  }

  /// 尼康厂商事件检查（0x90C1）：
  /// 数据格式 [count u16][eventCode u16][param u32] × count
  @override
  Future<List<PtpEvent>> getNikonEvents() async {
    final data = await _ptp.getNikonEvents();
    return data;
  }

  /// 流式下载对象；返回收到的总字节数。
  /// 分块不支持时由 PtpSession 自动回退 GetObject。
  @override
  Future<int> download(
    int handle,
    int size,
    void Function(List<int> chunk) sink, {
    void Function(int received, int total)? onProgress,
  }) async {
    final stream = await _ptp.downloadObject(
      handle,
      size,
      onProgress: (r) => onProgress?.call(r, size),
    );
    var total = 0;
    await for (final chunk in stream) {
      sink(chunk);
      total += chunk.length;
    }
    return total;
  }

  @override
  Future<Uint8List> thumb(int handle) => _ptp.getThumb(handle);

  /// 相机电池电量（0~100），不支持返回 null
  @override
  Future<int?> deviceBattery() => _ptp.deviceBattery();

  /// 存储卡剩余空间（字节），不支持返回 null
  @override
  Future<int?> storageFreeBytes() => _ptp.storageFreeBytes();

  /// 把已列出的句柄记为「已知」（自动拉图时跳过旧图）
  @override
  void markKnown(Iterable<int> handles) => _knownHandles.addAll(handles);
  @override
  bool isKnown(int handle) => _knownHandles.contains(handle);
  @override
  void forgetHandles() => _knownHandles.clear();

  @override
  Future<void> close() => _ptp.close();
}

/// 尼康驱动：USB + WiFi PTP/IP（Z6）
class NikonDriver implements CameraDriver {
  const NikonDriver();

  @override
  String get brand => 'nikon';

  /// Nikon Corporation 的 USB VID；VID 未知（0）的 Still Image 设备也归尼康，
  /// 避免小众机型漏发现（索尼等有专属驱动的品牌在注册表里优先认领）
  @override
  List<int> get usbVendorIds => const [0x04B0, 0];

  // 实验结论（2026-09-13）：USB 上 0x90C1 事件检查疑似触发 Z6 掉线
  // （连接后 20~30 秒相机自我复位），暂改用句柄差集轮询（纯标准命令）。
  // 待硬件层面（供电/线材）排除后再验证 0x90C1。
  @override
  NewFileStrategy get newFileStrategy => NewFileStrategy.pollHandles;

  @override
  Duration get pollInterval => const Duration(seconds: 5);

  /// 枚举 USB 上的 Still Image 设备（即 PTP 相机）
  @override
  Future<List<DiscoveredCamera>> discoverUsb() async {
    final devices = await UsbTransport.listDevices();
    return [
      for (final d in devices)
        if (usbVendorIds.contains((d['vendorId'] as num?)?.toInt() ?? 0))
          DiscoveredCamera(
            brand: brand,
            id: d['name'] as String,
            vendorId: (d['vendorId'] as num?)?.toInt() ?? 0,
            label:
                'USB · ${d['productName'] ?? ''} (${d['vendorId']}:${d['productId']})',
          ),
    ];
  }

  @override
  Future<CameraSession> connectUsb(String deviceName) async {
    final transport = await UsbTransport.open(deviceName);
    return PtpCameraSession.usb(transport);
  }

  /// WiFi 连接（相机热点 AP 模式，默认网关 192.168.1.1，可手动指定 IP）
  @override
  Future<CameraSession> connectWifi(String host) async {
    final link = await WifiLink.connect(host);
    return PtpCameraSession.wifi(link);
  }

  /// 自动发现：尼康热点网关固定 192.168.1.1。
  /// 不做硬探测——裸 TCP 探测误杀率高（路由绑定未生效/相机忙时被拒），
  /// 交给真正的 PTP/IP 握手（8s 超时）判定成败。
  @override
  Future<String?> discoverWifiHost() async => '192.168.1.1';

  @override
  Future<bool> probeWifi(String host) => CameraDrivers.probePtpIp(host);
}
