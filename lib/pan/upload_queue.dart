import 'dart:io';

import 'package:flutter/foundation.dart';

import '../cameras/transports/net_binder.dart';
import '../core/battery.dart';
import '../core/config.dart';
import '../core/keep_alive.dart';
import 'api_client.dart';
import 'pull_manager.dart';

enum UploadStatus { waiting, uploading, done, failed }

/// 一条上传任务
class UploadItem {
  UploadItem(this.filePath, this.fileName, this.size)
    : status = UploadStatus.waiting,
      progress = 0,
      error = null;

  final String filePath;
  final String fileName;
  final int size;

  UploadStatus status;
  double progress; // 0.0 ~ 1.0
  String? error;
  int? folderId;

  String get sizeText {
    final n = size;
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

/// 上传队列：串行处理，按拍摄日期自动建目录（避坑 #8：folder_id 不传 0）。
/// M3 将加入去重与上传时机策略（仅 WiFi / 立即 / 手动）。
class UploadQueue extends ChangeNotifier {
  UploadQueue._();
  static final UploadQueue instance = UploadQueue._();

  final List<UploadItem> _items = [];
  bool _running = false;

  List<UploadItem> get items => List.unmodifiable(_items);
  bool get isRunning => _running;
  int get pendingCount =>
      _items.where((i) => i.status == UploadStatus.waiting).length;

  /// 当前队列被挂起的原因（null = 可以处理）；供 UI 展示
  String? _waitReason;
  String? get waitReason => _waitReason;

  /// 手动全部暂停（传输页「全部暂停」按钮；运行态，不入配置）
  bool _manualPaused = false;
  bool get manualPaused => _manualPaused;

  /// 判定当前是否满足上传条件；不满足时返回原因
  Future<String?> checkGate() async {
    final cfg = AppConfig.instance;
    if (_manualPaused) return '已手动暂停';
    if (!cfg.isLoggedIn) return '未登录网盘（设置页配置）';
    switch (cfg.uploadMode) {
      case AppConfig.modeLocalOnly:
        return '仅本地模式（设置页可改）';
      case AppConfig.modeWifi:
        final onWifi = await NetBinder.isOnWifi();
        if (!onWifi) return '等待 WiFi 环境';
    }
    // 条件保护（设置-拉取策略）：仅充电时上传 / 低电量暂停
    if (cfg.chargeOnly || cfg.lowBatteryPause) {
      final b = await Battery.get();
      if (cfg.chargeOnly && !b.charging) return '等待充电';
      if (cfg.lowBatteryPause &&
          b.level >= 0 &&
          b.level < AppConfig.batteryThreshold) {
        return '电量不足 ${AppConfig.batteryThreshold}%';
      }
    }
    return null;
  }

  /// 全部暂停（正在上传的任务继续完成，剩余任务不再出队）
  void pauseAll() {
    _manualPaused = true;
    notifyListeners();
    _pump();
  }

  /// 恢复上传
  void resumeAll() {
    _manualPaused = false;
    notifyListeners();
    _pump();
  }

  void enqueue(List<File> files) {
    for (final f in files) {
      _items.add(UploadItem(f.path, f.uri.pathSegments.last, f.lengthSync()));
    }
    notifyListeners();
    KeepAliveSync.sync(); // 有传输任务：确保前台服务在跑（锁屏上传）
    _pump();
  }

  void retry(UploadItem item) {
    if (item.status != UploadStatus.failed) return;
    item
      ..status = UploadStatus.waiting
      ..error = null
      ..progress = 0;
    notifyListeners();
    _pump();
  }

  /// 外部状态变化后唤醒队列（登录成功 / 策略变更 / 回到前台 / 网络恢复）
  void kick() {
    notifyListeners();
    _pump();
  }

  /// 入口同步置位 _running，杜绝 await 间隙的重入竞态
  ///（checkGate 是 async，若先 await 再置位，快速连续 enqueue 会产生并发上传循环）
  void _pump() {
    if (_running) return;
    _running = true;
    _pumpLoop();
  }

  Future<void> _pumpLoop() async {
    try {
      while (true) {
        final gate = await checkGate();
        if (gate != null) {
          _waitReason = gate;
          KeepAliveSync.sync(); // 等待中也要保活（任务未完成）
          break;
        }
        final next = _items
            .where((i) => i.status == UploadStatus.waiting)
            .toList(growable: false);
        if (next.isEmpty) {
          _waitReason = null;
          KeepAliveSync.sync(); // 队列清空：无任务且相机断开时自动停保活
          break;
        }
        await _upload(next.first);
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _upload(UploadItem item) async {
    item
      ..status = UploadStatus.uploading
      ..progress = 0;
    notifyListeners();
    try {
      // 按拍摄日期归档；日期取文件的修改时间
      final mtime = File(item.filePath).lastModifiedSync();
      item.folderId = await PanClient.instance.ensureDateFolder(mtime);
      await PanClient.instance.uploadFile(
        item.filePath,
        fileName: item.fileName,
        folderId: item.folderId,
        onProgress: (sent, total) {
          final p = total > 0 ? sent / total : 0.0;
          if ((p - item.progress).abs() > 0.005 || p >= 1.0) {
            item.progress = p;
            notifyListeners();
          }
        },
      );
      item
        ..status = UploadStatus.done
        ..progress = 1.0;
      // 上传后删除本地文件（用户设置；已拉取列表随之不再显示）
      if (AppConfig.instance.deleteAfterUpload) {
        try {
          File(item.filePath).deleteSync();
        } catch (_) {
          /* 删除失败不影响上传成功状态 */
        }
      }
      LocalLibrary.instance.notifyChanged();
    } on ApiException catch (e) {
      item
        ..status = UploadStatus.failed
        ..error = e.message;
    } catch (e) {
      item
        ..status = UploadStatus.failed
        ..error = e.toString();
    }
    notifyListeners();
  }
}
