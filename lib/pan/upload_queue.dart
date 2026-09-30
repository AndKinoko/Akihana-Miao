import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../cameras/camera_hub.dart';
import '../cameras/transports/net_binder.dart';
import '../core/battery.dart';
import '../core/config.dart';
import '../core/gallery.dart';
import '../core/keep_alive.dart';
import 'api_client.dart';
import 'pull_manager.dart';

enum UploadStatus { waiting, uploading, done, failed }

/// 一条上传任务
class UploadItem {
  UploadItem(this.filePath, this.fileName, this.size, {this.mediaUri})
    : status = UploadStatus.waiting,
      progress = 0,
      error = null;

  /// 实际被上传/删除的本地文件。拉取场景下这是应用私有目录里的暂存副本；
  /// 「已拉取」面板手动上传时它就是相册里那份。
  final String filePath;
  final String fileName;
  final int size;

  /// 相册/下载目录里那份**用户可见副本**的 uri（而不是应用私有目录里
  /// 那份看不见的暂存副本）：
  /// - 拉取入库：`Gallery.save` 的返回值
  /// - 面板手动上传：为 null，此时 [filePath] 自己就是相册里那份
  ///
  /// 没有它，「上传后删除本地副本」只能删掉用户本来也看不到的那份，
  /// 相册里的文件原封不动——设置页那句「已拉取列表同步移除」也就不成立。
  final String? mediaUri;

  UploadStatus status;
  double progress; // 0.0 ~ 1.0
  String? error;
  int? folderId;

  /// 已重试次数（指数退避；UI 用它说明「重试 2 次后失败」）
  int retries = 0;

  /// 上传成功但本地副本没删掉：如实展示，不谎报「本地已删除」
  bool cleanupFailed = false;

  /// 用户已取消：在途上传在下一个分片边界中止，进度回调不再刷新
  bool cancelled = false;

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
class UploadQueue extends ChangeNotifier {
  UploadQueue._();
  static final UploadQueue instance = UploadQueue._();

  /// 失败重试上限（BUILD_SPEC §6：网络错误/5xx 指数退避 ≤2 次）
  static const _maxRetries = 2;

  /// 门禁不满足时的重探间隔（见 _scheduleGateRetry）
  static const _gateRetryDelay = Duration(seconds: 20);

  final List<UploadItem> _items = [];
  bool _running = false;

  /// 门禁重探 / 异常恢复用的定时器
  Timer? _retryTimer;

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
        // isOnWifi 查的是系统默认网络：相机热点没有互联网（未 VALIDATED），
        // 所以连着相机热点时这里必然为 false —— 也就是说下面那句 unbind
        // 只在「相机走 USB / 另有一路可上网 WiFi」时才会执行，
        // 不会把正在使用的相机 WiFi 链路拆掉。
        final onWifi = await NetBinder.isOnWifi();
        if (!onWifi) return '等待 WiFi 环境';
        // 相机热点连接时会把进程绑死在热点网络上（防止 ColorOS 智能选网
        // 把 192.168.1.x 发给蜂窝）。网盘在公网，必须先解开绑定，
        // 否则 isOnWifi 与网盘请求全被限制在热点里，队列永远等不到。
        if (CameraHub.instance.connected) {
          await NetBinder.unbind();
        }
      case AppConfig.modeImmediate:
        // 立即上传：不能在这里解绑。相机 WiFi 会话进行中解绑会让相机链路
        // 失去网络绑定（默认网络可能已切回蜂窝），断线后才由
        // CameraHub.disconnect() / _linkLost() 负责解绑。
        break;
    }
    // 条件保护（设置-拉取策略）：仅充电时上传 / 低电量暂停
    if (cfg.chargeOnly || cfg.lowBatteryPause) {
      final b = await Battery.get();
      // 读不到电量（level = -1）时不拦：宁可上传，也不让队列卡在
      // 一个永远无法满足的条件上
      if (b.level >= 0) {
        if (cfg.chargeOnly && !b.charging) return '等待充电';
        if (cfg.lowBatteryPause && b.level < AppConfig.batteryThreshold) {
          return '电量不足 ${AppConfig.batteryThreshold}%';
        }
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

  /// 取消一条：等待/失败直接移出队列；上传中置标志（下一个分片边界中止）并移出。
  /// 已完成的保留（用户需要看到结果）。
  void cancel(UploadItem item) {
    if (item.status == UploadStatus.done) return;
    item.cancelled = true;
    _items.remove(item);
    notifyListeners();
    _pump();
  }

  /// 全部取消：清空队列（含中止在途上传），保留已完成条目
  void cancelAll() {
    final removable = _items
        .where((i) => i.status != UploadStatus.done)
        .toList(growable: false);
    if (removable.isEmpty) return;
    for (final i in removable) {
      i.cancelled = true;
      _items.remove(i);
    }
    notifyListeners();
    _pump();
  }

  /// 是否还有可取消的任务（等待/上传中/失败）
  bool get hasCancellable => _items.any((i) => i.status != UploadStatus.done);

  /// 入队。[mediaUris] 为「文件路径 → 相册 uri」映射，只对拉取入库的文件
  /// 有意义（面板手动上传的文件没有 uri，删除时按路径反查）。
  void enqueue(List<File> files, {Map<String, String>? mediaUris}) {
    for (final f in files) {
      _items.add(
        UploadItem(
          f.path,
          f.uri.pathSegments.last,
          f.lengthSync(),
          mediaUri: mediaUris?[f.path],
        ),
      );
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
    // 有新的唤醒源时作废待执行的门禁重探，避免重复循环
    _retryTimer?.cancel();
    _retryTimer = null;
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
          _scheduleGateRetry();
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
    } catch (e, st) {
      // 异常兜底：不接住的话队列就此静止，且 UI 不会给出任何提示
      debugPrint('上传队列异常: $e\n$st');
      _waitReason = '队列异常，稍后自动重试';
      _scheduleGateRetry();
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  /// 门禁不满足时安排一次重探。
  ///
  /// 原实现在这里直接 `break` 就再没人唤醒队列：`_pump()` 的触发源只有
  /// 用户操作（设置页 4 处 kick + 传输页暂停/继续），生命周期回调也不 kick。
  /// 于是「WiFi 环境上传」（默认档）和「低电量暂停」（默认开）都是**单向闩锁**——
  /// 条件恢复后不会自动继续，而设置页写着「恢复充电后自动继续」。
  void _scheduleGateRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    // 手动暂停是用户意图，等他点「继续上传」，不自动重探
    if (_manualPaused) return;
    if (!_items.any((i) => i.status == UploadStatus.waiting)) return;
    _retryTimer = Timer(_gateRetryDelay, () {
      _retryTimer = null;
      _pump();
    });
  }

  Future<void> _upload(UploadItem item) async {
    if (item.cancelled) return;
    item
      ..status = UploadStatus.uploading
      ..progress = 0;
    notifyListeners();
    try {
      // 按拍摄日期归档；日期取文件的修改时间
      final mtime = File(item.filePath).lastModifiedSync();
      item.folderId = await PanClient.instance.ensureDateFolder(mtime);
      await _uploadWithRetry(item);
      if (item.cancelled) return;
      item
        ..status = UploadStatus.done
        ..progress = 1.0;
      // 上传后删除本地文件（用户设置；已拉取列表随之不再显示）
      if (AppConfig.instance.deleteAfterUpload) {
        await _deleteLocalCopies(item);
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

  /// 带上指数退避的上传（1s → 2s，最多 [_maxRetries] 次）。
  ///
  /// BUILD_SPEC §6 明写「网络错误/5xx 指数退避（≤2 次），4xx 不重试，401 自动重登」，
  /// 此前只实现了 401 那一半：失败即停下等用户手点「重试」，拍照现场常见的
  /// 瞬时抖动（弱信号、服务重启、路由抢占）会直接堆出一批需要人工介入的失败项。
  Future<void> _uploadWithRetry(UploadItem item) async {
    var attempt = 0;
    while (true) {
      try {
        await PanClient.instance.uploadFile(
          item.filePath,
          fileName: item.fileName,
          folderId: item.folderId,
          isCancelled: () => item.cancelled,
          onProgress: (sent, total) {
            if (item.cancelled) return;
            final p = total > 0 ? sent / total : 0.0;
            if ((p - item.progress).abs() > 0.005 || p >= 1.0) {
              item.progress = p;
              notifyListeners();
            }
          },
        );
        return;
      } catch (e) {
        if (item.cancelled || !_isRetryable(e) || attempt >= _maxRetries) {
          rethrow;
        }
        attempt++;
        item
          ..retries = attempt
          ..progress = 0;
        notifyListeners();
        await Future<void>.delayed(Duration(seconds: 1 << (attempt - 1)));
        if (item.cancelled) throw const UploadCancelled();
      }
    }
  }

  /// 是否值得重试：连接层失败与 5xx/408/429 可重试；
  /// 其余 4xx 是请求本身的问题（文件名非法、目录不存在），重试无意义
  static bool _isRetryable(Object e) {
    if (e is UploadCancelled) return false;
    if (e is ApiException) {
      final s = e.status;
      if (s == null) return true; // 没走到 HTTP 层
      return s >= 500 || s == 408 || s == 429;
    }
    if (e is SocketException) return true;
    if (e is TimeoutException) return true;
    if (e is http.ClientException) return true;
    return false;
  }

  /// 删除本地副本：相册/下载目录里那份**用户可见的**副本 + 应用私有目录的暂存副本。
  ///
  /// 原实现只删后者：那份文件用户本来也看不到，于是相册里的照片原封不动，
  /// 「已拉取列表同步移除」也不成立（面板扫的就是相册目录）。删不掉时
  /// 置 cleanupFailed，由 UI 如实显示，不谎报「本地已删除」。
  Future<void> _deleteLocalCopies(UploadItem item) async {
    final uri = item.mediaUri;
    final ok = uri != null
        ? await Gallery.delete(uri: uri)
        // 面板手动上传：filePath 自己就是相册里那份
        : await Gallery.delete(path: item.filePath);
    try {
      final f = File(item.filePath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      /* 暂存副本删不掉不影响主流程 */
    }
    item.cleanupFailed = !ok;
  }
}
