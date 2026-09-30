import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'camera_driver.dart';
import 'camera_session.dart';
import 'ptp/ptp_session.dart' show PtpEvent, PtpObjectInfo, PtpException;
import 'ptp/ptp_link.dart' show DownloadCancelled;
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

/// 落盘结果不可信（截断 / 零字节 / 相册落盘失败）：按失败处理。
///
/// 存在的意义：`CameraSession.download()` 的契约是「短包即正常返回已读部分」
/// （见 PtpTransport.read 注释），所以**截断不是异常路径而是正常返回**——
/// 不显式拦截，一份坏图会被写进相册、标记完成、上传网盘。
class DownloadFailure implements Exception {
  const DownloadFailure(this.message, {this.keepFile = false});

  final String message;

  /// true = 数据本身是好的，只是没进到用户可见的位置（相册落盘失败）。
  /// 此时**不要删文件**——删了才是真的丢数据。
  final bool keepFile;

  @override
  String toString() => message;
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

  /// 最近一次拉取失败的原因（诊断用）
  String? lastPullError;

  /// 轮询连续失败计数（设备掉线感知）
  int _pollFailCount = 0;

  /// 对象列表连续「异常缩水」计数（见 _pollNewObjects 的列表即全集防护）
  int _shrinkStreak = 0;

  /// 最近一次 USB 发现的相机描述（型号兜底用）
  String? _lastCamLabel;

  // 连接阶段状态机（浮层展示；success 展示后自动归 idle）
  ConnectPhase phase = ConnectPhase.idle;
  String phaseDetail = '';
  String failReason = '';
  String _lastKind = 'usb';
  bool _cancelled = false;

  /// 一次性断开提示（UI 弹一次即清，避免重复弹）
  String? disconnectNote;

  /// 一次性批量拉取结果提示（传输页跳转后由相机页弹一次即清）
  String? pullNote;

  void setPullNote(String note) {
    pullNote = note;
    notifyListeners();
  }

  /// 自动拉取待办队列（连拍场景：先全部登记「排队中」，再串行消费，
  /// 保证传输-拉取面板能看到完整队列，而不是一个拉完才出现下一个）
  final List<({int handle, PullJob job, PtpObjectInfo info})> _autoQueue = [];
  bool _autoDraining = false;

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
    'canon' => '佳能',
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
              ? '未发现 USB 相机\n请确认：① 数据线支持数据传输（OTG）'
                    '② 相机已开机 ③ 手机支持 OTG'
              : '未发现${_brandLabel(p)} USB 相机\n若品牌选择有误，请在连接方式上方改为「自动」',
        );
        return;
      }
      final cam = cams.first;
      final driver = CameraDrivers.byBrand(cam.brand);
      _lastCamLabel = cam.label;
      connKind = 'usb';
      connHost = null;
      _lastKind = 'usb';
      _setPhase(ConnectPhase.handshaking, 'PTP 握手中…');
      await _finishConnect(() => driver.connectUsb(cam.id), driver);
    } catch (e) {
      if (!_cancelled) {
        // 读取超时最常见的原因是相机被其他应用占用
        // （接入时的系统选择框选了别的 App，或相册/文件管理器正在浏览相机）。
        // 判据走异常分类，不再匹配「超时/bulkRead」这类文案
        final hint = _isLinkFailure(e)
            ? '$e\n排查：接入相机时系统弹框请选择 Akihana；'
                  '关闭正在浏览相机的其他应用；或相机关机重开后再试'
            : '连接失败：$e';
        _fail(hint);
      }
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
        // （佳能 同网段候选 / 索尼 192.168.122.1 / 尼康 192.168.1.1 盲连）
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
            AppConfig.brandCanon =>
              '未发现佳能相机（CCAPI 8080 不可达）\n'
                  '请确认相机已开启「Camera Control API」并连上其热点\n'
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
        // 品牌明确的错误直接展示；其余补一句索尼世代排查提示
        final hint =
            msg.contains('索尼') ||
                msg.contains('Sony') ||
                msg.contains('佳能') ||
                msg.contains('Canon')
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
      // 列表是扁平全量（storage=all, parent=0），文件夹与文件混在一起。
      // 不建目录树：逐个 GetObjectInfo 会把 isFolder 一并带回来，目录与文件
      // 一并正确归类，一次事务一个对象。
      //
      // 这里曾经有一版「目录句柄猜测」（用句柄相邻性推断父目录）作为提速手段，
      // 已删除：PTP 只保证「子句柄 > 父句柄」不保证相邻，句柄连续时它反而
      // 让每个句柄被查询两次（先探测、主循环再查一遍），净效果是事务翻倍；
      // 而它想省下的那次 GetObjectInfo 本来就是必要的。
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
      // 真实型号：GetDeviceInfo 优先，USB 发现描述兜底，最后降级为「相机」
      var m = '';
      try {
        m = await s.model();
      } catch (_) {}
      if (m.isEmpty) {
        // USB 发现时的系统描述，如 "USB · NIKON DSC Z 6 (04b0:1091)"
        m =
            RegExp(
              r'USB · ([^(]+)',
            ).firstMatch(_lastCamLabel ?? '')?.group(1)?.trim() ??
            '';
      }
      debugPrint('相机型号: "$m"');
      if (m.isNotEmpty) deviceModel = m;
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
      debugPrint(
        '连接成功: brand=$_activeDriver? model=$deviceModel '
        '对象=${rows.length} kind=$connKind host=$connHost',
      );
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
    debugPrint('连接失败: $reason');
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
    // WiFi 空闲时相机可能断开；定期 GetStorageIDs 保活（AeroShutter 同策略）。
    // busy/batchRunning 门禁：下载进行中绝不插队发事务——USB 是共享 bulk 数据流，
    // 数据阶段中途收到新命令会让相机复位掉线（Z6 实测「接入约 25~30s 必死」）；
    // 下载本身就是最好的保活，无需额外心跳。
    _keepAlive = Timer.periodic(const Duration(seconds: 25), (_) async {
      if (busy || batchRunning) return;
      try {
        await session?.getStorageIds();
      } catch (_) {}
    });
  }

  /// 链路死亡/断开统一清理：自动拉取待办与拉取面板任务全部作废，
  /// 避免残留死任务一直显示「排队中/拉取中」
  void _clearPullQueues() {
    _autoQueue.clear();
    PullManager.instance.clearAll();
  }

  /// 轮询拉新图：不保证推 ObjectAdded 事件的机型（索尼等）用句柄差集兜底，
  /// 尼康/佳能用事件检查（0x90C1 / CCAPI addedcontents）。拉图/批量进行中
  /// 跳过一轮，避免抢串行队列。
  void _startPolling(CameraDriver driver) {
    _pollTimer?.cancel();
    _activeDriver = driver;
    if (driver.newFileStrategy == NewFileStrategy.eventPush) return;
    _pollTimer = Timer.periodic(driver.pollInterval, (_) {
      if (driver.newFileStrategy == NewFileStrategy.eventPoll) {
        _pollEvents();
      } else {
        _pollNewObjects();
      }
    });
  }

  /// 事件轮询（eventPoll 策略）：会话层返回品牌相关的事件数组
  /// （尼康 0x90C1；佳能 CCAPI addedcontents），与 interrupt 事件同管线处理。
  Future<void> _pollEvents() async {
    final s = session;
    if (s == null || busy || batchRunning || _cancelled) return;
    try {
      final events = await s.pollNewObjects();
      _pollFailCount = 0; // 成功即清零（失败计数必须连续才有意义）
      if (session != s || events.isEmpty) return;
      var changed = false;
      for (final ev in events) {
        final handle = _eventHandle(ev);
        if (handle == null) continue;
        if (ev.eventCode == PtpEvent.objectRemoved) {
          objects.removeWhere((r) => r.handle == handle);
          thumbs.remove(handle);
          selectedHandles.remove(handle);
          changed = true;
        } else if (ev.eventCode == PtpEvent.objectAdded) {
          final before = objects.length;
          await _processNewHandle(s, handle);
          if (objects.length != before) changed = true;
        }
      }
      if (changed) notifyListeners();
    } catch (e) {
      // 事件轮询失败同样计连败（佳能 WiFi 没有事件流 onDone，掉线靠这里感知）
      await _notePollFailure(e);
    }
  }

  /// 轮询失败统一处理：连续 3 次 = 设备已失联，标记链路死亡提示重连
  /// （USB 上没有事件流 onDone，WiFi HTTP 后端的事件流也不会因断网关闭）。
  Future<void> _notePollFailure(Object e) async {
    _pollFailCount++;
    debugPrint('轮询失败 x$_pollFailCount: $e');
    if (_pollFailCount < 3) return;
    _linkLost('相机无响应，连接已断开，请重新连接');
  }

  /// 链路死亡统一清理（轮询连败 / 事件流关闭 / 下载超时 三条路径共用）。
  /// 此前三处各自复制一遍同样的收尾代码，改一处必漏两处。
  void _linkLost(String note) {
    _eventSub?.cancel();
    _eventSub = null;
    _keepAlive?.cancel();
    _pollTimer?.cancel();
    _pollFailCount = 0;
    _clearPullQueues();
    final dead = session;
    session = null;
    _activeDriver = null;
    disconnectNote = note;
    notifyListeners();
    if (dead != null) {
      unawaited(dead.close().catchError((Object e) => debugPrint('关闭会话异常: $e')));
    }
    // 相机热点会把整个进程绑在没有互联网的网络上（防 ColorOS 智能选网）。
    // 链路死了必须解开，否则后续上传（含「立即上传」档，它不走 gate 的
    // 解绑分支）全部出不去，且没有任何恢复路径
    if (connKind == 'wifi') unawaited(NetBinder.unbind());
    KeepAliveSync.sync();
  }

  /// 链路故障判定：只认异常类型与 [PtpFailureKind]，**不匹配异常文案**。
  /// 原实现是 `msg.contains('超时') || msg.contains('bulkRead')`——
  /// 协议层或 Kotlin 侧改一个字，掉线检测就静默失效（文案一变即回归）。
  static bool _isLinkFailure(Object e) {
    if (e is PtpException) return e.isLinkFailure;
    if (e is TimeoutException) return true;
    if (e is SocketException) return true;
    return false;
  }

  /// 句柄差集轮询（索尼等 pollHandles 策略；尼康 USB 暂用同款）。
  /// 连续失败 3 次 = 设备已从总线消失，标记链路死亡提示重连
  /// （USB 上没有事件流 onDone，掉线只能靠轮询失败感知）。
  Future<void> _pollNewObjects() async {
    final s = session;
    if (s == null || busy || batchRunning || _cancelled) return;
    try {
      final handles = await s.listObjectHandles();
      _pollFailCount = 0;
      if (session != s) return; // 会话已切换
      final handleSet = handles.toSet();
      // 同步删除：SD 卡上已移除的文件从网格消失（对齐 ObjectRemoved 语义）
      final removed = objects
          .where((r) => !handleSet.contains(r.handle))
          .map((r) => r.handle)
          .toList();
      // 「列表即全集」防护：把「不在本轮列表里」直接等同于「已删除」是危险的——
      // 换个只返回根 association 的机型，或相机忙时只回了半截列表，网格里的
      // 照片会被集体清空（用户看到照片凭空消失）。列表大幅缩水时先当可疑响应
      // 处理，连续 3 轮都如此才认账（真清空卡也只需多等 3 轮）。
      if (removed.length > 3 && removed.length > objects.length ~/ 2) {
        _shrinkStreak++;
        if (_shrinkStreak < 3) {
          debugPrint(
            '对象列表异常缩水（本轮 ${handles.length} / 现网格 ${objects.length}），'
            '第 $_shrinkStreak 次，本轮不执行删除',
          );
          return;
        }
      } else {
        _shrinkStreak = 0;
      }
      if (removed.isNotEmpty) {
        objects.removeWhere((r) => !handleSet.contains(r.handle));
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
    } catch (e) {
      await _notePollFailure(e);
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
        _linkLost('连接已断开，请重新连接');
      },
    );
  }

  /// 事件里的对象句柄：PIMA 15740 规定 ObjectAdded/ObjectRemoved 的首个参数
  /// 即 ObjectHandle（部分机型会再追加存储 id 等参数）。
  ///
  /// 此前事件推送路径取 `params.last`、轮询路径取 `params.first`：同一批事件码
  /// 两套语义，多参数机型上二者必有一错（尼康 WiFi 用轮询策略、同时又有事件
  /// 通道，两条路径会在同一台机器上同时生效）。统一按规范取首个参数。
  static int? _eventHandle(PtpEvent ev) =>
      ev.params.isEmpty ? null : ev.params.first;

  Future<void> _handleEvent(CameraSession s, PtpEvent ev) async {
    if (ev.eventCode == PtpEvent.objectRemoved) {
      final handle = _eventHandle(ev);
      if (handle == null) return;
      objects.removeWhere((r) => r.handle == handle);
      thumbs.remove(handle);
      selectedHandles.remove(handle);
      notifyListeners();
      return;
    }
    if (ev.eventCode != PtpEvent.objectAdded) return;
    final handle = _eventHandle(ev);
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
      _enqueueAutoPull(handle, info);
    } catch (_) {
      /* 事件到达时对象可能还没就绪，忽略 */
    }
  }

  /// 自动拉取登记：先入队显示「排队中」，再由 drain 串行消费。
  /// 连拍时多张新图一次性全部可见，而不是拉完一张才冒出下一张。
  void _enqueueAutoPull(int handle, PtpObjectInfo info) {
    if (pulledNames.contains(info.filename)) return;
    if (PullManager.instance.hasActive(info.filename)) return;
    final job = PullManager.instance.begin(
      info.filename,
      info.size,
      thumbs[handle],
      isRaw: info.isRaw,
      queued: true,
    );
    _autoQueue.add((handle: handle, job: job, info: info));
    notifyListeners();
    unawaited(_drainAutoQueue());
  }

  Future<void> _drainAutoQueue() async {
    if (_autoDraining) return;
    _autoDraining = true;
    try {
      while (_autoQueue.isNotEmpty) {
        final s = session;
        if (s == null) {
          // 会话没了：清掉剩余排队任务（断开路径也会清，这里防并发窗口）
          for (final t in _autoQueue) {
            PullManager.instance.fail(t.job, '连接已断开');
          }
          _autoQueue.clear();
          return;
        }
        if (batchRunning) return; // 批量优先，batchPull 结束后会继续消费
        final t = _autoQueue.removeAt(0);
        if (!PullManager.instance.jobs.contains(t.job)) continue;
        PullManager.instance.start(t.job);
        busy = true;
        notifyListeners();
        try {
          // 返回 false = 取消或失败（含完整性校验不过）：不计入「本次自动拉取」
          if (await _downloadJob(s, t.job, t.handle, t.info)) {
            autoCount++;
            autoBytes += t.info.size;
          }
        } catch (e) {
          debugPrint('自动拉取失败 ${t.info.filename}: $e');
        } finally {
          busy = false;
          notifyListeners();
        }
      }
    } finally {
      _autoDraining = false;
    }
  }

  // ---------- 拉取 ----------

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
    final errors = <String>[];
    for (final (s, job, handle, info) in queue) {
      // 连接死亡后剩余任务不再逐个尝试
      if (session == null || s != session) break;
      PullManager.instance.start(job);
      try {
        // 取消/失败都不计入成功数：此前 DownloadCancelled 被吞掉后正常返回，
        // 拔线也会报「已拉取 N 张」，与实际成功数不符
        if (await _downloadJob(s, job, handle, info)) {
          okCount++;
        } else {
          errors.add('${info.filename}: ${job.error ?? '拉取失败'}');
        }
      } catch (e) {
        // _downloadJob 内部已兜底，这里只防它自身抛错
        errors.add('${info.filename}: $e');
      }
    }
    batchRunning = false;
    busy = false;
    lastPullError = errors.isEmpty ? null : errors.first;
    notifyListeners();
    // 批量期间挂起的自动拉取继续消费
    unawaited(_drainAutoQueue());
    return okCount;
  }

  /// 「立即拉取全部」：排除已拉取，返回将拉取的文件（UI 先弹确认框）
  List<ObjectRow> pullAllCandidates() =>
      fileRows.where((r) => !pulledNames.contains(r.info.filename)).toList();

  /// 拉取并落盘一个对象。
  ///
  /// 返回 true = 完整落盘且已进相册/下载目录；false = 取消或失败（半成品已清理，
  /// 失败原因已记入任务）。**调用方必须用返回值判断成败**，不能把正常返回当作成功。
  Future<bool> _downloadJob(
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
      // 后端在下载过程中报告的真实总长（WiFi 后端的 content-length 比列表
      // 阶段拿到的 size 可靠；列表阶段 size=0 的 RAW 条目靠它回填）
      var reportedTotal = 0;
      final int received;
      try {
        received = await s.download(
          handle,
          info.size,
          sink.add,
          onProgress: (r, t) {
            if (t > 0) reportedTotal = t;
            PullManager.instance.update(job, r, total: t);
          },
          // 会话被换掉（断开/拔线/链路死亡）即视为取消：在途下载在下一个
          // 分片边界中止，不必等 GetPartialObject 的 10 分钟超时
          isCancelled: () => session != s,
        );
      } finally {
        await sink.close();
      }

      // ---------- 完整性校验（此前完全缺失，是本项目最严重的数据风险） ----------
      // 「短包即结束」是协议层的**正常返回路径**（见 PtpTransport.read 注释：
      // 设备提前结束返回已读部分），相机掉线/USB 短包/WiFi 中断/相机休眠都会
      // 产出一个「成功」的短文件。不校验的话：坏图 → 写进相册 → 标记已完成
      // → 上传网盘，而「上传后删除本地副本」会把干净的那份也删掉。
      final expected = reportedTotal > 0 ? reportedTotal : info.size;
      final sizeError = downloadIntegrityError(
        received: received,
        expected: expected,
      );
      if (sizeError != null) throw DownloadFailure(sizeError);
      if (expected > 0 && received > expected) {
        // 只记不拦：多收说明 size 字段不准，但内容通常是完整的
        debugPrint(
          '拉取 ${info.filename}: 收到 $received > 期望 $expected，size 字段可能不准',
        );
      }

      // 本地保存：可选存入系统相册（按拍摄日期分文件夹，设置页开关）。
      // 关闭「保存到相册」时改存 Download/AkihanaMiao——不污染相册时间线，
      // 但「已拉取」面板照样能扫到（面板只认这三个专属目录，见 Gallery.query）。
      // 早前版本落应用私有目录，saveToGallery=false 时文件用户完全看不到。
      final String? mediaUri;
      if (AppConfig.instance.saveToGallery) {
        final date = info.captureDate ?? DateTime.now();
        final sub = AppConfig.instance.dateFolders ? _dateSub(date) : null;
        mediaUri = await Gallery.save(
          target.path,
          target.uri.pathSegments.last,
          subFolder: sub,
        );
      } else {
        mediaUri = await Gallery.save(
          target.path,
          target.uri.pathSegments.last,
          forceDownload: true,
          subFolder: AppConfig.instance.dateFolders
              ? _dateSub(info.captureDate ?? DateTime.now())
              : null,
        );
      }
      // 落盘失败（存储满 / MediaStore 拒绝）：此前返回值被丢弃，用户全程无感，
      // 任务还标记「已完成」。这里按失败上报，但**保留已下好的文件**——
      // 数据是好的，只是没进到用户可见的位置，删了才是真丢。
      if (mediaUri == null) {
        throw const DownloadFailure(
          '文件已下载但保存到相册/下载目录失败（存储空间不足？）',
          keepFile: true,
        );
      }

      // 防重集合更新（在通知已拉取面板之前）：本地名 + 相机原始名都记
      pulledNames
        ..add(target.uri.pathSegments.last)
        ..add(info.filename);
      // 本地回填：成功拉取的图立即有本地路径，缩略图秒开
      localFilePaths[info.filename] = target.path;
      localFilePaths[target.uri.pathSegments.last] = target.path;

      // 再按策略决定是否上传（上传的是本地副本）。带上相册 uri：
      // 上传成功后「删除本地副本」要连用户可见的那份一起删
      if (AppConfig.instance.uploadMode != AppConfig.modeLocalOnly) {
        UploadQueue.instance.enqueue([
          target,
        ], mediaUris: {target.path: mediaUri});
      }
      // 先让「已拉取」刷新，最后才把任务移出「正在拉取」——保证两页同步无缝
      LocalLibrary.instance.notifyChanged();
      PullManager.instance.finish(job);
      return true;
    } catch (e) {
      final t = target;
      // 取消不是故障：相机已经断开，链路死亡的判定与提示已由断开路径发出，
      // 这里只需清理半成品，不该再弹错误或把失败原因写进状态栏
      if (e is DownloadCancelled) {
        debugPrint('拉取中止 ${info.filename}: $e');
        _deleteQuietly(t);
        PullManager.instance.fail(job, e.toString());
        return false;
      }
      debugPrint('拉取失败 ${info.filename}: $e');
      // 清理半成品（截断文件、0 字节残留）。keepFile 的失败类型保留文件
      if (!(e is DownloadFailure && e.keepFile)) _deleteQuietly(t);
      PullManager.instance.fail(job, e.toString());
      // 链路故障（超时/拔出）也走统一清理：提示重连 + 解开 WiFi 网络绑定
      if (_isLinkFailure(e)) _linkLost('相机无响应，连接已断开，请重新连接');
      return false;
    }
  }

  static void _deleteQuietly(File? f) {
    try {
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 下载完整性判定。返回 null = 通过，否则返回失败原因（供 UI 展示）。
  ///
  /// 抽成纯函数是为了能单测——这是本项目最严重的数据风险点，
  /// 而它所在的 _downloadJob 需要真机/平台通道才能跑。
  ///
  /// [expected] 优先取下载过程中后端报告的真实总长，拿不到时回落到列表里的
  /// size（为 0 表示未知，此时只拦「一个字节都没收到」）。
  static String? downloadIntegrityError({
    required int received,
    required int expected,
  }) {
    if (received == 0) return '未收到任何数据（相机未返回对象内容）';
    if (expected > 0 && received < expected) {
      return '数据不完整：收到 $received / 期望 $expected 字节'
          '（相机中断或链路不稳）';
    }
    return null;
  }

  /// yyyy-MM-dd 子目录名（相册/下载目录通用）
  static String _dateSub(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// 冲突自动改名：name.ext 存在 → name_1.ext、name_2.ext …
  File _uniqueFile(File f) {    if (!f.existsSync()) return f;
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
    _clearPullQueues();
    // 先复位状态让 UI 立即响应；传输收尾放后台（链路可能已死，CloseSession
    // 可能挂起 30s，绝不能卡住断开操作）
    final s = session;
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
    if (s != null) {
      unawaited(s.close().catchError((Object e) => debugPrint('关闭会话异常: $e')));
    }
    // WiFi 连接时整个进程被绑在相机热点上（无互联网）：断开必须解开，
    // 否则「立即上传」档不走 gate 的解绑分支，网盘请求永远出不去
    if (connKind == 'wifi') unawaited(NetBinder.unbind());
    KeepAliveSync.sync(); // 无上传任务则停保活
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
  ///
  /// 门禁与保活事务保持一致：**下载进行中（busy）直接让路，不排队**。
  /// 原实现是「忙等最多 30s 再照发」——大 RAW 分块下载必然超过 30s，
  /// 之后视口里每个图块都会往串行队列插一条命令，正是注释里写明的
  /// 「数据阶段中途插命令会让相机复位掉线」的高危模式。
  /// 让路的代价只是占位图多显示一会儿：busy 翻回 false 会通知重建。
  Future<Uint8List?> thumbFuture(int handle) {
    final cached = thumbs[handle];
    if (cached != null) return Future.value(cached);
    if (busy || batchRunning) return Future.value(null);
    if (session == null) return Future.value(null);
    return _thumbFutures.putIfAbsent(handle, () => _fetchThumb(handle));
  }

  Future<Uint8List?> _fetchThumb(int handle) async {
    final s = session;
    if (s == null) return null;
    try {
      final t = await s.thumb(handle);
      if (t.isEmpty) return null;
      thumbs[handle] = t;
      notifyListeners();
      return t;
    } catch (e) {
      debugPrint('缩略图 $handle 获取失败: $e');
      return null;
    } finally {
      // 失败/空结果不缓存：此前失败的 Future 永久留在表里，
      // 那张图的缩略图到断开为止都不会再重试
      if (thumbs[handle] == null) _thumbFutures.remove(handle);
    }
  }

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
