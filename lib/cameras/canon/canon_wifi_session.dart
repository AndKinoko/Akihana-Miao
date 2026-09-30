import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../camera_session.dart';
import '../ptp/ptp_session.dart' show PtpDeviceInfo, PtpEvent, PtpObjectInfo;
import '../ptp/ptp_link.dart' show PtpException, DownloadCancelled;
import 'canon_ccapi.dart';

/// 佳能 WiFi 会话（CCAPI：官方 HTTP REST 接口）。
///
/// - 目录树：存储卡 → 目录（100CANON 等）→ 文件；每页 100 条自动翻页
/// - 新图：官方 event/polling 的 addedcontents（无需全量重列）；
///   机型不支持时自动退回「全量列表差集」，行为与索尼轮询一致
/// - 下载 = 文件 URL 流式 GET；缩略图 = ?kind=thumbnail
/// - 大小/修改时间 = ?kind=info（连接时并发预取，新文件到达时单取）
class CanonWifiSession extends CameraSession {
  CanonWifiSession._(this._api, this._model) : super('WiFi:${_api.host}', 'canon');

  final CanonCcapi _api;
  final String _model;

  final Map<int, _CanonContent> _contents = {};
  final Set<int> _known = {};
  final StreamController<PtpEvent> _events = StreamController.broadcast();

  /// event/polling 是否可用（404 等明确不支持时置 false，退回列表差集）
  bool _eventPollingOk = true;

  /// 连接：先探 /ccapi，再读 deviceinformation（型号）。失败抛 PtpException
  static Future<CanonWifiSession> connect(String host) async {
    final api = CanonCcapi(host);
    if (!await CanonCcapi.probe(host)) {
      api.close();
      throw const PtpException(
        '未发现佳能相机（CCAPI 不可达）\n'
        '请确认相机已开启「Camera Control API」并连上其热点',
      );
    }
    final model = await api.model();
    return CanonWifiSession._(api, model);
  }

  @override
  Stream<PtpEvent> get events => _events.stream;

  @override
  Future<List<int>> getStorageIds() async {
    try {
      final storages = await _api.listStorages();
      return [for (var i = 0; i < storages.length; i++) i + 1];
    } catch (_) {
      return const [];
    }
  }

  /// 全量刷新目录树（连接时；event/polling 不可用时的差集兜底）
  @override
  Future<List<int>> listObjectHandles() async {
    final urls = await _listAllFileUrls();
    final fresh = <int, _CanonContent>{};
    for (final u in urls) {
      final handle = u.hashCode;
      fresh[handle] = _contents[handle] ?? _CanonContent(url: u, name: _filename(u));
    }
    _contents
      ..clear()
      ..addAll(fresh);
    // 新句柄并发补大小/时间（排序与进度条依赖）；已有信息的复用缓存
    await _prefetchInfo(
      fresh.values.where((c) => c.size == null || c.date == null),
    );
    return fresh.keys.toList();
  }

  Future<List<String>> _listAllFileUrls() async {
    final out = <String>[];
    final storages = await _api.listStorages();
    for (final storage in storages) {
      await _walk(storage, out, 0);
    }
    return out;
  }

  Future<void> _walk(String url, List<String> out, int depth) async {
    if (depth > 3) return;
    final items = await _listPaged(url);
    for (final item in items) {
      if (_looksLikeDir(item)) {
        await _walk(item, out, depth + 1);
      } else {
        out.add(item);
      }
    }
  }

  /// 目录分页读取：优先 ?kind=number 拿页数；不支持时按「满 100 条继续」探测
  Future<List<String>> _listPaged(String url) async {
    final out = <String>[];
    final pages = await _api.pageCount(url);
    if (pages != null && pages > 0) {
      final limit = pages > 200 ? 200 : pages; // 防御：异常页数上限 2 万条
      for (var p = 1; p <= limit; p++) {
        final items = await _api.listPage(url, p);
        out.addAll(items);
        if (items.isEmpty) break;
      }
      return out;
    }
    // 页数不可用：满 100 条继续翻页；同一首页重复出现 = 相机忽略 page 参数
    String? prevFirst;
    for (var p = 1; p <= 50; p++) {
      final items = await _api.listPage(url, p);
      if (items.isNotEmpty && items.first == prevFirst) break;
      prevFirst = items.isEmpty ? null : items.first;
      out.addAll(items);
      if (items.length < 100) break;
    }
    return out;
  }

  /// 并发预取文件信息（8 路并发；相机热点延迟低，避免串行 N 次往返）
  Future<void> _prefetchInfo(Iterable<_CanonContent> files) async {
    final list = files.toList();
    if (list.isEmpty) return;
    var next = 0;
    Future<void> worker() async {
      while (next < list.length) {
        final c = list[next++];
        await _fillInfo(c);
      }
    }

    await Future.wait([for (var i = 0; i < 8; i++) worker()]);
  }

  Future<void> _fillInfo(_CanonContent c) async {
    final info = await _api.fileInfo(c.url);
    if (info == null) return;
    final size = info['filesize'] ?? info['size'];
    if (size is num) {
      c.size = size.toInt();
    } else if (size is String) {
      c.size = int.tryParse(size) ?? c.size;
    }
    final date = info['lastmodifieddate'] ?? info['lastmodified'] ?? info['date'];
    if (date is String) {
      c.date = _parseCcapiDate(date) ?? c.date;
    }
  }

  @override
  Future<PtpObjectInfo> getObjectInfo(int handle) async {
    final c = _contents[handle];
    if (c == null) throw PtpException('对象不存在');
    if (c.size == null || c.date == null) await _fillInfo(c);
    return PtpObjectInfo(
      storageId: 0xFFFFFFFF,
      objectFormat: 0x3801, // JPEG；CCAPI 不暴露 PTP 格式码，RAW 角标按扩展名判断
      size: c.size ?? 0,
      parentObject: 0,
      filename: c.name,
      captureDate: c.date,
    );
  }

  @override
  Future<int> download(
    int handle,
    int size,
    void Function(List<int> chunk) sink, {
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final c = _contents[handle];
    if (c == null) throw PtpException('对象不存在');
    // 原图：直接 GET 文件 URL；个别机型要求显式 kind=original
    var resp = await _open(c.url);
    resp ??= await _open(c.url, query: const {'kind': 'original'});
    if (resp == null) throw PtpException('下载失败：相机未返回文件');
    final total = resp.contentLength ?? (size > 0 ? size : 0);
    var received = 0;
    final completer = Completer<void>();
    resp.stream.listen(
      (chunk) {
        if (isCancelled?.call() == true) {
          if (!completer.isCompleted) {
            completer.completeError(
              const DownloadCancelled('下载已取消（连接中断）'),
            );
          }
          return;
        }
        received += chunk.length;
        sink(chunk);
        onProgress?.call(received, total);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      cancelOnError: true,
    );
    await completer.future;
    return received;
  }

  Future<http.StreamedResponse?> _open(
    String url, {
    Map<String, String>? query,
  }) async {
    try {
      final resp = await _api
          .streamGet(url, query: query)
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) return resp;
      try {
        await resp.stream.drain<void>();
      } catch (_) {}
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List> thumb(int handle) async {
    final c = _contents[handle];
    if (c == null) throw PtpException('对象不存在');
    for (final kind in const ['thumbnail', 'display']) {
      final data = await _api.bytes(c.url, query: {'kind': kind});
      if (data != null && data.isNotEmpty) return data;
    }
    throw PtpException('缩略图获取失败');
  }

  /// 新对象事件：CCAPI event/polling 的 addedcontents/removedcontents；
  /// 机型不支持（404 等）时退回全量列表差集，语义与句柄轮询一致
  @override
  Future<List<PtpEvent>> pollNewObjects() async {
    if (_eventPollingOk) {
      try {
        final changes = await _api.pollContentChanges();
        if (changes.added.isEmpty && changes.removed.isEmpty) return const [];
        final events = <PtpEvent>[];
        for (final u in changes.removed) {
          final handle = u.hashCode;
          if (_contents.remove(handle) != null) {
            _known.remove(handle);
            events.add(PtpEvent(eventCode: PtpEvent.objectRemoved, params: [handle]));
          }
        }
        for (final u in changes.added) {
          final handle = u.hashCode;
          final c = _contents[handle] ?? _CanonContent(url: u, name: _filename(u));
          _contents[handle] = c;
          if (c.size == null || c.date == null) await _fillInfo(c);
          events.add(PtpEvent(eventCode: PtpEvent.objectAdded, params: [handle]));
        }
        return events;
      } on PtpException catch (e) {
        // 明确不支持 → 永久降级；相机忙(503) → 本轮无事件；其余上抛计连败
        if (e.code == 404 || e.code == 405 || e.code == 501) {
          _eventPollingOk = false;
        } else if (e.code == 503) {
          return const [];
        } else {
          rethrow;
        }
      }
    }
    // 兜底：全量差集（新增 + 删除），语义与 hub 的句柄轮询一致
    final before = _contents.keys.toSet();
    final handles = await listObjectHandles();
    final after = handles.toSet();
    return [
      for (final h in handles)
        if (!before.contains(h)) PtpEvent(eventCode: PtpEvent.objectAdded, params: [h]),
      for (final h in before)
        if (!after.contains(h)) PtpEvent(eventCode: PtpEvent.objectRemoved, params: [h]),
    ];
  }

  @override
  Future<String> model() async => _model;

  @override
  Future<PtpDeviceInfo> getDeviceInfo() async =>
      PtpDeviceInfo(manufacturer: 'Canon', model: _model, deviceVersion: '');

  @override
  Future<int?> deviceBattery() => _api.batteryLevel();

  @override
  Future<int?> storageFreeBytes() => _api.storageFreeBytes();

  @override
  void markKnown(Iterable<int> handles) => _known.addAll(handles);
  @override
  bool isKnown(int handle) => _known.contains(handle);
  @override
  void forgetHandles() => _known.clear();

  @override
  Future<void> close() async {
    await _events.close();
    _api.close();
  }

  /// 目录名不带扩展名（100CANON/sd/card1），文件名都带
  static bool _looksLikeDir(String url) {
    final path = Uri.parse(url).path;
    final parts = path.split('/');
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i].isNotEmpty) return !parts[i].contains('.');
    }
    return false;
  }

  static String _filename(String url) {
    final parts = Uri.parse(url).path.split('/');
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i].isNotEmpty) return parts[i];
    }
    return url;
  }

  /// CCAPI 时间：20220911T121314+0900 / ISO8601 / HTTP 日期，尽量宽松解析
  static DateTime? _parseCcapiDate(String s) {
    var t = s.trim();
    if (t.isEmpty) return null;
    final m = RegExp(
      r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})([+-]\d{2})(\d{2})$',
    ).firstMatch(t);
    if (m != null) {
      return DateTime.tryParse(
        '${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}${m[7]}:${m[8]}',
      );
    }
    t = t.replaceFirstMapped(
      RegExp(r'([+-]\d{2})(\d{2})$'),
      (mm) => '${mm[1]}:${mm[2]}',
    );
    return DateTime.tryParse(t);
  }
}

/// 一条 CCAPI 文件条目（句柄 = URL 哈希，会话内稳定）
class _CanonContent {
  _CanonContent({required this.url, required this.name});

  final String url;
  final String name;
  int? size;
  DateTime? date;
}
