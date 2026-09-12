import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'camera_driver.dart';
import 'camera_session.dart';
import 'ptp/ptp_session.dart' show PtpEvent, PtpObjectInfo;
import 'transports/net_binder.dart';
import '../core/config.dart';
import '../core/gallery.dart';
import '../core/keep_alive.dart';
import '../pan/pull_manager.dart';
import '../pan/upload_queue.dart';

/// 相机对象行（网格用）
class ObjectRow {
  const ObjectRow({required this.handle, required this.info});
  final int handle;
  final PtpObjectInfo info;
}

/// 连接流程阶段（驱动连接浮层动画）
enum ConnectPhase { idle, discovering, handshaking, listing, success, failed }

/// 相机状态中枢：连接/事件/拉取/缩略图/选择，全部集中于此。
/// 相机页（信息中枢）与相机相册页（网格）共同监听。
class CameraHub extends ChangeNotifier {
  CameraHub._();
  static final CameraHub instance = CameraHub._();

  CameraSession? session;
  StreamSubscription<PtpEvent>? _eventSub;
  Timer? _keepAlive;
  Timer? _pollTimer;
  bool busy = false;
  List<ObjectRow> objects = [];

  /// 当前连接的驱动（决定新图策略/轮询周期）
  CameraDriver? _activeDriver;

  /// 当前连接品牌（信息卡/调试用；未连接为 null）
  String? get activeBrand => _activeDriver?.brand;

  // 连接阶段状态机（浮层展示；success 展示后自动归 idle）
  ConnectPhase phase = ConnectPhase.idle;
  String phaseDetail = '';
  String failReason = '';
  String _lastKind = 'usb';
  bool _cancelled = false;

  /// 一次性断开提示（UI 弹一次即清，避免重复弹）
  String? disconnectNote;

  // 缩略图：相机缓存 + Future 去重 + 本地回填
  final Map<int, Uint8List> thumbs = {};
  final Map<int, Future<Uint8List?>> _thumbFutures = {};
  final Map<String, String> localFilePaths = {};

  // 防重：已拉取文件名集合（连接时重建，进程重启免疫）
  final Set<String> pulledNames = {};

  // 视口精确加载范围（相机相册页滚动时更新）
  int reqStart = 0;
  int reqEnd = 30;

  // 选择（相机相册页）
  final Set<int> selectedHandles = {};
  bool batchRunning = false;

  // 连接信息（信息卡展示）
  String? connKind; // 'usb' | 'wifi'
  String? connHost;
  String? deviceModel; // GetDeviceInfo 读取的真实型号
  int? deviceBattery; // 0~100，null = 不可读
  int? storageFree; // 字节，null = 不可读

  // 本次自动拉取统计（信息卡「本次自动拉取」汇总）
  int autoCount = 0;
  int autoBytes = 0;

  bool get connected => session != null;
  int get fileCount => objects.where((r) => !r.info.isFolder).length;

  List<ObjectRow> get fileRows =>
      objects.where((r) => !r.info.isFolder).toList();

  // ---------- 连接 ----------

  /// 按品牌偏好过滤驱动（auto=全部；具体品牌=只保留该品牌）
  List<CameraDriver> get _preferredDrivers {
    final p = AppConfig.instance.brandPreference;
    if (p == AppConfig.brandAuto) return CameraDrivers.all;
    return CameraDrivers.all.where((d) => d.brand == p).toList();
  }

  /// 品牌中文名（失败提示用）
  String _brandLabel(String brand) => switch (brand) {
    'nikon' => '尼康',
    'sony' => '索尼',
    _ => brand,
  };

  Future<void> connectUsb() async {
    if (busy) return;
    busy = true;
    _cancelled = false;
    _setPhase(ConnectPhase.discovering, '正在枚举 USB 设备…');
    try {
      final preferred = _preferredDrivers;
      final cams = await CameraDrivers.discoverUsb(preferred);
      if (_cancelled) return;
      if (cams.isEmpty) {
        final p = AppConfig.instance.brandPreference;
        _fail(
          p == AppConfig.brandAuto
              ? '未发现 USB 相机\n请确认数据线已连接，相机 USB 模式设为 PTP/MTP'
              : '未发现${_brandLabel(p)} USB 相机\n若品牌选择有误，请在连接方式上方改为「自动」',
        );
        return;
      }
      final cam = cams.first;
      final driver = CameraDrivers.byBrand(cam.brand);
      connKind = 'usb';
      connHost = null;
      _lastKind = 'usb';
      _setPhase(ConnectPhase.handshaking, 'PTP 握手中…');
      await _finishConnect(() => driver.connectUsb(cam.id), driver);
    } catch (e) {
      if (!_cancelled) _fail('连接失败：$e');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> connectWifi([String? host]) async {
    if (busy) return;
    busy = true;
    _cancelled = false;
    _setPhase(ConnectPhase.discovering, '正在探测相机热点…');
    try {
      // 相机热点无互联网，先把进程路由绑到 WiFi（防 ColorOS 智能选网走蜂窝）
      final bound = await NetBinder.bindWifi();
      var h = host ?? '';
      CameraDriver? driver;
      final preferred = _preferredDrivers;
      if (h.isNotEmpty) {
        // 手动指定地址：按品牌顺序试探
        for (final d in preferred) {
          if (await d.probeWifi(h)) {
            driver = d;
            break;
          }
        }
        if (driver == null) {
          _fail('无法连接 $h\n未探测到相机服务');
          return;
        }
      } else {
        // 自动发现：按品牌偏好逐个探测各自的热点网关
        // （尼康 192.168.1.1 盲连 / 索尼 192.168.122.1 HTTP 探测）
        for (final d in preferred) {
          h = await d.discoverWifiHost() ?? '';
          if (h.isNotEmpty) {
            driver = d;
            break;
          }
        }
        if (driver == null) {
          final p = AppConfig.instance.brandPreference;
          _fail(switch (p) {
            AppConfig.brandNikon =>
              '未发现尼康相机\n请确认手机已连接相机热点（192.168.1.1）\n'
                  '${bound ? '' : '未检测到 WiFi 网络'}',
            AppConfig.brandSony =>
              '未发现索尼相机热点（192.168.122.1）\n'
                  '请确认相机已进入「发送到智能手机」界面\n'
                  '${bound ? '' : '未检测到 WiFi 网络'}',
            _ =>
              '未发现相机\n${bound ? '' : '未检测到 WiFi 网络 / '}\n'
                  '可尝试在连接方式上方指定相机品牌',
          });
          return;
        }
      }
      connKind = 'wifi';
      connHost = h;
      _lastKind = 'wifi';
      _setPhase(ConnectPhase.handshaking, '正在连接 $h…');
      await _finishConnect(() => driver!.connectWifi(h), driver);
    } catch (e) {
      if (!_cancelled) {
        final msg = e.toString();
        final hint = msg.contains('索尼') || msg.contains('Sony')
            ? msg
            : '$e\n若为索尼新机型（扫码配对世代），请改用 USB 连接';
        _fail('连接失败：$hint');
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _finishConnect(
    Future<CameraSession> Function() connect,
    CameraDriver driver,
  ) async {
    CameraSession? s;
    try {
      s = await connect();
      if (_cancelled) {
        try {
          await s.close();
        } catch (_) {}
        return;
      }
      _setPhase(ConnectPhase.listing, '读取对象列表…');
      final handles = await s.listObjectHandles();
      final rows = <ObjectRow>[];
      for (final h in handles) {
        try {
          rows.add(ObjectRow(handle: h, info: await s.getObjectInfo(h)));
        } catch (_) {
          /* 个别句柄读不出来就跳过 */
        }
      }
      if (_cancelled) {
        try {
          await s.close();
        } catch (_) {}
        return;
      }
      // 真实型号：GetDeviceInfo 优先，握手友好名兜底（失败降级为「相机」）
      try {
        final m = await s.model();
        if (m.isNotEmpty) deviceModel = m;
      } catch (_) {}
      _sortRows(rows);
      session = s;
      objects = rows;
      thumbs.clear();
      _thumbFutures.clear();
      selectedHandles.clear();
      reqStart = 0;
      reqEnd = 30;
      autoCount = 0;
      autoBytes = 0;
      _setPhase(ConnectPhase.success, '${rows.length} 个对象');
      s.markKnown(handles);
      await _loadPulledNames();
      _readDeviceStatus();
      _startKeepAlive();
      _listenEvents();
      _startPolling(driver); // 轮询拉新图（索尼等不推事件的机型）
      unawaited(KeepAliveSync.sync()); // 后台保活：连接成功即启动前台服务
      // 成功态展示后自动归位（浮层淡出）
      Future.delayed(const Duration(milliseconds: 700), () {
        if (phase == ConnectPhase.success) {
          phase = ConnectPhase.idle;
          notifyListeners();
        }
      });
    } catch (e) {
      // 失败必须关闭半开的连接，否则相机被占用、下次连接直接被拒
      try {
        await s?.close();
      } catch (_) {}
      rethrow;
    }
  }

  void _setPhase(ConnectPhase p, [String detail = '']) {
    phase = p;
    phaseDetail = detail;
    if (p != ConnectPhase.failed) failReason = '';
    notifyListeners();
  }

  void _fail(String reason) {
    phase = ConnectPhase.failed;
    failReason = reason;
    notifyListeners();
  }

  /// 浮层「取消」：停止后续阶段推进（在途连接由失败路径关闭兜底）
  void cancelConnect() {
    _cancelled = true;
    phase = ConnectPhase.idle;
    failReason = '';
    notifyListeners();
  }

  /// 浮层「重试」：按上次连接方式重来
  void retryConnect() {
    if (_lastKind == 'wifi') {
      connectWifi(connHost);
    } else {
      connectUsb();
    }
  }

  /// 相机信息卡：电量 + 存储卡可用（读取失败静默降级，不显示该行）
  Future<void> _readDeviceStatus() async {
    final s = session;
    if (s == null) return;
    final b = await s.deviceBattery();
    final f = await s.storageFreeBytes();
    if (session != s) return;
    deviceBattery = b;
    storageFree = f;
    notifyListeners();
  }

  Future<void> _loadPulledNames() async {
    final names = <String>{};
    final paths = <String, String>{};
    try {
      for (final g in await Gallery.query()) {
        if (g.name.isNotEmpty) {
          names.add(g.name);
          if (g.path.isNotEmpty) paths[g.name] = g.path;
        }
      }
    } catch (_) {}
    try {
      final dir = await getApplicationDocumentsDirectory();
      final saveDir = Directory('${dir.path}/camera_pull');
      if (saveDir.existsSync()) {
        for (final f in saveDir.listSync().whereType<File>()) {
          final n = f.uri.pathSegments.last;
          names.add(n);
          paths.putIfAbsent(n, () => f.path);
        }
      }
    } catch (_) {}
    pulledNames
      ..clear()
      ..addAll(names);
    localFilePaths
      ..clear()
      ..addAll(paths);
    notifyListeners();
  }

  /// 文件在前、文件夹在后；文件按拍摄时间倒序（最近在顶）
  void _sortRows(List<ObjectRow> rows) {
    final folders = rows.where((r) => r.info.isFolder).toList();
    final files = rows.where((r) => !r.info.isFolder).toList()
      ..sort((a, b) {
        final da = a.info.captureDate;
        final db = b.info.captureDate;
        if (da != null && db != null) return db.compareTo(da);
        if (da != null) return -1;
        if (db != null) return 1;
        return b.handle.compareTo(a.handle);
      });
    rows
      ..clear()
      ..addAll(files)
      ..addAll(folders);
  }

  void _startKeepAlive() {
    _keepAlive?.cancel();
    // WiFi 空闲时相机可能断开；定期 GetStorageIDs 保活（AeroShutter 同策略）
    _keepAlive = Timer.periodic(const Duration(seconds: 25), (_) async {
      try {
        await session?.getStorageIds();
      } catch (_) {}
    });
  }

  /// 轮询拉新图：不保证推 ObjectAdded 事件的机型（索尼等）用句柄差集兜底。
  /// 周期由品牌驱动给出；拉图/批量进行中跳过一轮，避免抢串行队列。
  void _startPolling(CameraDriver driver) {
    _pollTimer?.cancel();
    _activeDriver = driver;
    if (driver.newFileStrategy != NewFileStrategy.pollHandles) return;
    _pollTimer = Timer.periodic(driver.pollInterval, (_) => _pollNewObjects());
  }

  Future<void> _pollNewObjects() async {
    final s = session;
    if (s == null || busy || batchRunning || _cancelled) return;
    try {
      final handles = await s.listObjectHandles();
      if (session != s) return; // 会话已切换
      final handleSet = handles.toSet();
      // 同步删除：SD 卡上已移除的文件从网格消失（对齐 ObjectRemoved 语义）
      final removed = objects
          .where((r) => !handleSet.contains(r.handle))
          .map((r) => r.handle)
          .toList();
      if (removed.isNotEmpty) {
        objects.removeWhere((r) => handleSet.contains(r.handle) == false);
        for (final h in removed) {
          thumbs.remove(h);
          selectedHandles.remove(h);
        }
        notifyListeners();
      }
      // 新增：跳过已知与现有，走与 ObjectAdded 相同的处理管线
      final existing = objects.map((r) => r.handle).toSet();
      for (final h in handles) {
        if (!existing.contains(h) && !s.isKnown(h)) {
          await _processNewHandle(s, h);
        }
      }
    } catch (_) {
      /* 单轮轮询失败忽略（链路死亡由事件流 onDone 兜底） */
    }
  }

  void _listenEvents() {
    _eventSub?.cancel();
    final s = session;
    if (s == null) return;
    _eventSub = s.events.listen(
      (ev) => _handleEvent(s, ev),
      // 事件流关闭 = 链路死亡（超时作废/相机断开）：复位，提示重连
      onDone: () {
        if (session == null) return;
        _keepAlive?.cancel();
        _pollTimer?.cancel();
        session = null;
        disconnectNote = '连接已断开，请重新连接';
        notifyListeners();
        KeepAliveSync.sync(); // 链路死亡：若无上传任务则停保活
      },
    );
  }

  Future<void> _handleEvent(CameraSession s, PtpEvent ev) async {
    if (ev.eventCode == PtpEvent.objectRemoved) {
      final handle = ev.params.isEmpty ? null : ev.params.last;
      if (handle == null) return;
      objects.removeWhere((r) => r.handle == handle);
      thumbs.remove(handle);
      selectedHandles.remove(handle);
      notifyListeners();
      return;
    }
    if (ev.eventCode != PtpEvent.objectAdded) return;
    final handle = ev.params.isEmpty ? null : ev.params.last;
    if (handle == null || s.isKnown(handle)) return;
    await _processNewHandle(s, handle);
  }

  /// 新句柄统一处理管线（事件推送与轮询共用）：
  /// 读信息 → 标记已知 → 插入网格 → 自动拉取（开关 + 类型过滤 + 批量互斥）
  Future<void> _processNewHandle(CameraSession s, int handle) async {
    if (s.isKnown(handle)) return;
    try {
      final info = await s.getObjectInfo(handle);
      s.markKnown([handle]);
      // 只跳过文件夹；size=0 允许通过（索尼 WiFi 的 RAW 条目无 size，
      // 真实大小在下载时由 HTTP content-length 回填）
      if (info.isFolder) return;
      // 新图插到最前（拍摄时间倒序语义）
      objects.insert(0, ObjectRow(handle: handle, info: info));
      _sortRows(objects);
      notifyListeners();
      // 自动拉取：开关 + 类型过滤（设置页拉取策略）；批量拉取进行中不穿插。
      // 注意：类型过滤只约束自动拉取——用户手动多选拉取不受限制。
      if (!AppConfig.instance.autoPull || batchRunning) return;
      final ext = info.filename.contains('.')
          ? info.filename.split('.').last
          : '';
      final type = AppConfig.extToPullType(ext);
      if (!AppConfig.instance.pullTypes.contains(type)) return;
      await pullObject(handle, info, auto: true);
    } catch (_) {
      /* 事件到达时对象可能还没就绪，忽略 */
    }
  }

  // ---------- 拉取 ----------

  /// 拉取单个对象（自动拉取走这里；手动只有批量入口）。
  Future<void> pullObject(
    int handle,
    PtpObjectInfo info, {
    bool auto = false,
  }) async {
    final s = session;
    if (s == null) return;
    if (pulledNames.contains(info.filename)) return;
    if (PullManager.instance.hasActive(info.filename)) return;
    final job = PullManager.instance.begin(
      info.filename,
      info.size,
      thumbs[handle],
      isRaw: info.isRaw,
    );
    busy = true;
    notifyListeners();
    try {
      await _downloadJob(s, job, handle, info);
      if (auto) {
        // 本次自动拉取统计（仅成功的自动拉取计数）
        autoCount++;
        autoBytes += info.size;
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 批量拉取：任务先全部入队（排队中），再逐个拉取。
  /// [handles] 允许为空集合 → 什么都不做。手动拉取不受类型过滤约束。
  Future<int> batchPull(Set<int> handles) async {
    if (busy || batchRunning || handles.isEmpty) return 0;
    final targets = objects
        .where((r) => handles.contains(r.handle) && !r.info.isFolder)
        .toList();
    if (targets.isEmpty) return 0;
    batchRunning = true;
    busy = true;
    notifyListeners();
    final queue = <(CameraSession, PullJob, int, PtpObjectInfo)>[];
    for (final r in targets) {
      if (pulledNames.contains(r.info.filename)) continue;
      queue.add((
        session!,
        PullManager.instance.begin(
          r.info.filename,
          r.info.size,
          thumbs[r.handle],
          isRaw: r.info.isRaw,
          queued: true,
        ),
        r.handle,
        r.info,
      ));
    }
    notifyListeners();
    var okCount = 0;
    for (final (s, job, handle, info) in queue) {
      // 连接死亡后剩余任务不再逐个尝试
      if (session == null || s != session) break;
      PullManager.instance.start(job);
      try {
        await _downloadJob(s, job, handle, info);
        okCount++;
      } catch (_) {}
    }
    batchRunning = false;
    busy = false;
    notifyListeners();
    return okCount;
  }

  /// 「立即拉取全部」：排除已拉取，返回将拉取的文件（UI 先弹确认框）
  List<ObjectRow> pullAllCandidates() =>
      fileRows.where((r) => !pulledNames.contains(r.info.filename)).toList();

  Future<void> _downloadJob(
    CameraSession s,
    PullJob job,
    int handle,
    PtpObjectInfo info,
  ) async {
    File? target; // 失败时清理半成品
    try {
      final dir = await getApplicationDocumentsDirectory();
      final saveDir = Directory('${dir.path}/camera_pull')
        ..createSync(recursive: true);
      // 本地优先：文件名冲突自动加序号（DSC_0001.JPG → DSC_0001_1.JPG）
      // WiFi 后端可能改名（RAW 预览落盘为 .JPG）
      target = _uniqueFile(
        File('${saveDir.path}/${await s.outputName(handle, info)}'),
      );
      final sink = target.openWrite();
      try {
        await s.download(
          handle,
          info.size,
          sink.add,
          onProgress: (r, t) => PullManager.instance.update(job, r, total: t),
        );
      } finally {
        await sink.close();
      }

      // 本地保存：可选存入系统相册（按拍摄日期分文件夹，设置页开关）
      if (AppConfig.instance.saveToGallery) {
        final date = info.captureDate ?? DateTime.now();
        final sub = AppConfig.instance.dateFolders
            ? '${date.year.toString().padLeft(4, '0')}-'
                  '${date.month.toString().padLeft(2, '0')}-'
                  '${date.day.toString().padLeft(2, '0')}'
            : null;
        await Gallery.save(
          target.path,
          target.uri.pathSegments.last,
          subFolder: sub,
        );
      }

      // 防重集合更新（在通知已拉取面板之前）：本地名 + 相机原始名都记
      pulledNames
        ..add(target.uri.pathSegments.last)
        ..add(info.filename);
      // 本地回填：成功拉取的图立即有本地路径，缩略图秒开
      localFilePaths[info.filename] = target.path;
      localFilePaths[target.uri.pathSegments.last] = target.path;

      // 再按策略决定是否上传（上传的是本地副本）
      if (AppConfig.instance.uploadMode != AppConfig.modeLocalOnly) {
        UploadQueue.instance.enqueue([target]);
      }
      // 先让「已拉取」刷新，最后才把任务移出「正在拉取」——保证两页同步无缝
      LocalLibrary.instance.notifyChanged();
      PullManager.instance.finish(job);
    } catch (e) {
      // 清理下载失败的半成品文件（避免 0 字节残留）
      try {
        final t = target;
        if (t != null && t.existsSync()) t.deleteSync();
      } catch (_) {}
      PullManager.instance.fail(job, e.toString());
      rethrow;
    }
  }

  /// 冲突自动改名：name.ext 存在 → name_1.ext、name_2.ext …
  File _uniqueFile(File f) {
    if (!f.existsSync()) return f;
    final dir = f.parent.path;
    final base = f.uri.pathSegments.last;
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final ext = dot > 0 ? base.substring(dot) : '';
    for (var i = 1; i < 9999; i++) {
      final cand = File('$dir/${stem}_$i$ext');
      if (!cand.existsSync()) return cand;
    }
    return File('$dir/${DateTime.now().millisecondsSinceEpoch}$ext');
  }

  // ---------- 断开 ----------

  Future<void> disconnect() async {
    _eventSub?.cancel();
    _keepAlive?.cancel();
    _pollTimer?.cancel();
    await session?.close();
    session = null;
    objects = [];
    thumbs.clear();
    _thumbFutures.clear();
    selectedHandles.clear();
    localFilePaths.clear();
    deviceBattery = null;
    storageFree = null;
    deviceModel = null;
    _activeDriver = null;
    disconnectNote = '已断开';
    notifyListeners();
    KeepAliveSync.sync(); // 无上传任务则停保活
  }

  void disposeSession() {
    _eventSub?.cancel();
    _keepAlive?.cancel();
    session?.close();
  }

  // ---------- 缩略图（相机相册页用） ----------

  /// 视口精确加载：滚动停 150ms 后由相机相册页调用
  void updateRange(int start, int end) {
    final files = fileCount;
    final s = start.clamp(0, files);
    final e = end.clamp(0, files);
    if (s != reqStart || e != reqEnd) {
      reqStart = s;
      reqEnd = e;
      notifyListeners();
    }
  }

  /// 缩略图三级策略见 CameraAlbumPage._buildThumb：
  /// 相机缓存 → 本地回填 → 视口范围内向相机请求
  Future<Uint8List?> fetchThumb(int handle) async {
    // 下载让路：拉图进行中挂起缩略图请求（最多等 30s）
    var waited = 0;
    while (busy && waited < 30000) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      waited += 300;
    }
    try {
      final t = await session?.thumb(handle);
      if (t == null) return null;
      thumbs[handle] = t;
      notifyListeners();
      return t;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> thumbFuture(int handle) =>
      _thumbFutures.putIfAbsent(handle, () => fetchThumb(handle));

  void toggleSelect(int handle) {
    selectedHandles.contains(handle)
        ? selectedHandles.remove(handle)
        : selectedHandles.add(handle);
    notifyListeners();
  }

  void selectAll() {
    selectedHandles.addAll(fileRows.map((r) => r.handle));
    notifyListeners();
  }

  void clearSelection() {
    selectedHandles.clear();
    notifyListeners();
  }
}
