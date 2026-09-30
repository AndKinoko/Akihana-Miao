import 'dart:io';

import '../camera_driver.dart';
import '../camera_session.dart';
import '../nikon/nikon_driver.dart' show PtpCameraSession;
import '../transports/usb_transport.dart';
import 'canon_ccapi.dart';
import 'canon_wifi_session.dart';

/// 佳能驱动。
///
/// USB：EOS 机身走标准 PTP（与尼康/索尼 USB 共用整套管线），
/// 新图靠句柄差集轮询（佳能不保证推标准 ObjectAdded 事件）。
///
/// WiFi：官方 CCAPI（HTTP REST，默认端口 8080；相机菜单需开启
/// 「Camera Control API」并连上其热点）。新图用 event/polling 的
/// addedcontents 事件；不支持 polling 的机型自动退回句柄差集。
class CanonDriver implements CameraDriver {
  const CanonDriver();

  @override
  String get brand => 'canon';

  /// Canon Inc. 的 USB VID
  @override
  List<int> get usbVendorIds => const [0x04A9];

  /// CCAPI event/polling 事件（会话内部在机型不支持时自动退回列表差集）
  @override
  NewFileStrategy get newFileStrategy => NewFileStrategy.eventPoll;

  @override
  Duration get pollInterval => const Duration(seconds: 4);

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

  @override
  Future<CameraSession> connectWifi(String host) => CanonWifiSession.connect(host);

  /// 佳能直连热点网关不固定（实测 192.168.1.1 / 192.168.1.2 都有），
  /// 从本机网卡地址派生同网段候选并并发探测 /ccapi。
  @override
  Future<String?> discoverWifiHost() async {
    final hosts = await _candidates();
    final results = await Future.wait([
      for (final h in hosts)
        CanonCcapi.probe(
          h,
          timeout: const Duration(seconds: 3),
        ).then((ok) => ok ? h : null),
    ]);
    for (final r in results) {
      if (r != null) return r;
    }
    return null;
  }

  @override
  Future<bool> probeWifi(String host) => CanonCcapi.probe(host);

  Future<List<String>> _candidates() async {
    final out = <String>['192.168.1.1', '192.168.1.2'];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final p = addr.address.split('.');
          if (p.length == 4) {
            out
              ..add('${p[0]}.${p[1]}.${p[2]}.1')
              ..add('${p[0]}.${p[1]}.${p[2]}.2');
          }
        }
      }
    } catch (_) {}
    final seen = <String>{};
    return [
      for (final h in out)
        if (seen.add(h)) h,
    ];
  }
}
