import 'package:flutter/services.dart';

/// 进程级网络绑定：连接相机热点时把默认路由切到 WiFi，
/// 防止 ColorOS「智能选网」把 192.168.1.x 流量发给蜂窝/VPN。
/// M3 引入分 socket 绑定后，此实现仅供相机连接阶段使用。
class NetBinder {
  static const MethodChannel _channel = MethodChannel('dev.akihana/usb_host');

  /// 绑定到 WiFi 网络；没有可用 WiFi 返回 false
  static Future<bool> bindWifi() async {
    try {
      return await _channel.invokeMethod<bool>('bindWifi') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 恢复默认路由
  static Future<void> unbind() async {
    try {
      await _channel.invokeMethod('unbindNetwork');
    } catch (_) {}
  }

  /// 当前是否在可上网的 WiFi 环境（相机热点不算）
  static Future<bool> isOnWifi() async {
    try {
      return await _channel.invokeMethod<bool>('isOnWifi') ?? false;
    } catch (_) {
      return false;
    }
  }
}
