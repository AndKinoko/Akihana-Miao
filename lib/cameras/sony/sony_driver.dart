import 'package:http/http.dart' as http;

import '../camera_driver.dart';
import '../camera_session.dart';
import '../nikon/nikon_driver.dart' show PtpCameraSession;
import '../transports/usb_transport.dart';
import 'sony_wifi_session.dart';

/// 索尼 WiFi 内容服务的固定端口（旧世代「发送到智能手机」协议）
const _servicePort = 64321;

/// 索尼驱动。
///
/// USB：α 系列为标准 PTP/MTP 设备，列目录/下载/缩略图全走标准操作，
/// 与尼康共用整套管线。新图策略用句柄轮询（索尼不保证推 ObjectAdded 事件）。
///
/// WiFi：旧世代（A7M3 及更早 / DIRECT-xxxx 直连输密码）走索尼私有 HTTP
/// 协议（非 PTP/IP），见 [connectWifi]（Phase 2）；Creators' App 世代
/// 加密配对明确不支持，连接失败时提示用户改用 USB。
class SonyDriver implements CameraDriver {
  const SonyDriver();

  @override
  String get brand => 'sony';

  /// Sony Corporation 的 USB VID
  @override
  List<int> get usbVendorIds => [0x054C];

  /// 索尼不保证 ObjectAdded 事件（因机型/模式而异），统一用句柄轮询
  @override
  NewFileStrategy get newFileStrategy => NewFileStrategy.pollHandles;

  @override
  Duration get pollInterval => const Duration(seconds: 4);

  @override
  Future<List<DiscoveredCamera>> discoverUsb() async {
    final devices = await UsbTransport.listDevices();
    return [
      for (final d in devices)
        if (usbVendorIds.contains(d['vendorId']))
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
  Future<CameraSession> connectWifi(String host) async {
    // Phase 2：旧世代索尼 WiFi（DIRECT-xxxx AP，HTTP/JSON 内容接口）
    final session = await SonyWifiSession.connect(host);
    return session;
  }

  @override
  Future<String?> discoverWifiHost() async {
    // 索尼相机热点网关固定 192.168.122.1；探测其 HTTP 服务在线才算发现
    const host = '192.168.122.1';
    return await probeWifi(host) ? host : null;
  }

  @override
  Future<bool> probeWifi(String host) async {
    try {
      final resp = await http
          .get(Uri.parse('http://$host:$_servicePort/DmsDescPush.xml'))
          .timeout(const Duration(seconds: 4));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
