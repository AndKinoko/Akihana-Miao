import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../cameras/camera_hub.dart';
import '../pan/upload_queue.dart';
import 'config.dart';

/// 后台保活统一决策入口：根据「相机连接 / 上传队列」状态启停前台服务。
/// 通知常显，提醒用户服务是否正在进行。
/// （类名不用 KeepAlive——与 Flutter 框架 sliver.dart 的 KeepAlive 冲突）
class KeepAliveSync {
  KeepAliveSync._();

  static const _channel = MethodChannel('dev.akihana/usb_host');

  /// 生命周期监听：退后台/回前台时兜底同步一次（失败静默）
  // 字段本身无读取方，存在的意义是让监听常驻整个 App 生命周期
  // ignore: unused_field
  static final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onHide: () => sync(),
    onShow: () => sync(),
  );

  /// 通知文案按当前状态生成
  static String _text() {
    final active = UploadQueue.instance.items
        .where(
          (i) =>
              i.status == UploadStatus.waiting ||
              i.status == UploadStatus.uploading,
        )
        .length;
    if (active > 0) return '$active 个文件传输中，请保持 App 在后台运行';
    return '相机已连接 · 拍摄后自动拉取';
  }

  /// 统一决策：需要保活则启动（幂等，同时刷新通知文案），否则停止
  static Future<void> sync() async {
    if (!AppConfig.instance.backgroundRun) {
      await _stop();
      return;
    }
    final need =
        CameraHub.instance.connected ||
        UploadQueue.instance.items.any(
          (i) =>
              i.status == UploadStatus.waiting ||
              i.status == UploadStatus.uploading,
        );
    if (!need) {
      await _stop();
      return;
    }
    try {
      await _channel.invokeMethod('startKeepAlive', {'text': _text()});
    } catch (_) {
      /* 后台启动受限等场景静默失败 */
    }
  }

  static Future<void> _stop() async {
    try {
      await _channel.invokeMethod('stopKeepAlive');
    } catch (_) {}
  }

  /// 设置页开关关闭时立即停服务
  static Future<void> onSettingChanged() async {
    if (AppConfig.instance.backgroundRun) {
      await sync();
    } else {
      await _stop();
    }
  }
}
