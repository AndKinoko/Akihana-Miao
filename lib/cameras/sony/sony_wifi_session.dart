import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../camera_session.dart';
import '../ptp/ptp_session.dart' show PtpDeviceInfo, PtpEvent, PtpObjectInfo;
import '../ptp/ptp_link.dart' show PtpException;

/// 索尼旧世代 WiFi 会话（PlayMemories / Imaging Edge 的「发送到智能手机」协议）。
///
/// 协议（社区逆向，参考 ImagingEdge4Linux）：
/// - 相机热点网关 192.168.122.1，HTTP 服务端口 64321
/// - GET  /DmsDescPush.xml                     服务描述（含 friendlyName 机型）
/// - POST /upnp/control/XPushList              SOAP X_TransferStart/End（推送态显示）
/// - POST /upnp/control/ContentDirectory       SOAP Browse（双重编码的 DIDL-Lite）
///     根节点 PhotoRoot = 全部照片（"在手机上选择"模式）；PushRoot = 相机勾选的
/// - 内容下载 = 直接 HTTP GET res URL（流式，带 content-length）
/// - RAW 条目只提供相机转出的 JPEG 预览（_LRG），原始 RAW 仅 USB 可得（索尼官方行为）
class SonyWifiSession extends CameraSession {
  SonyWifiSession._(this._host, this._client) : super('WiFi:$_host', 'sony');

  static const _port = 64321;
  static const _root = 'PhotoRoot'; // 全部照片

  final String _host;
  final http.Client _client;
  final Map<int, _SonyContent> _contents = {};
  final Set<int> _known = {};
  final StreamController<PtpEvent> _events = StreamController.broadcast();
  String _friendlyName = '';

  @override
  Stream<PtpEvent> get events => _events.stream;

  /// 连接：探测相机服务描述，失败抛 PtpException（连接浮层展示原因）
  static Future<SonyWifiSession> connect(String host) async {
    final client = http.Client();
    final session = SonyWifiSession._(host, client);
    try {
      final desc = await client
          .get(
            Uri.parse('http://$host:$_port/DmsDescPush.xml'),
            headers: const {'Connection': 'close'},
          )
          .timeout(const Duration(seconds: 5));
      if (desc.statusCode != 200) {
        throw PtpException('索尼服务响应异常 (${desc.statusCode})');
      }
      // friendlyName = 机型（如 ILCE-7M3）
      try {
        final doc = XmlDocument.parse(desc.body);
        session._friendlyName =
            doc.findAllElements('friendlyName').firstOrNull?.innerText.trim() ??
            '';
      } catch (_) {}
      // 进入传输态（推送模式才有效，失败不影响拉图）
      unawaited(
        session._soap(
          '/upnp/control/XPushList',
          'urn:schemas-sony-com:service:XPushList:1',
          'X_TransferStart',
          '<u:X_TransferStart xmlns:u="urn:schemas-sony-com:service:XPushList:1"></u:X_TransferStart>',
        ),
      );
      return session;
    } on TimeoutException {
      client.close();
      throw const PtpException('连接超时：请确认相机已进入「发送到智能手机」界面');
    } on PtpException {
      client.close();
      rethrow;
    } catch (e) {
      client.close();
      throw PtpException('未发现索尼相机（$host:$_port 不可达）');
    }
  }

  Future<http.Response> _soap(
    String path,
    String service,
    String action,
    String body,
  ) async {
    return _client
        .post(
          Uri.parse('http://$_host:$_port$path'),
          headers: {
            'SOAPACTION': '"urn:schemas-sony-com:service:$service#$action"',
            'Content-Type': 'text/xml; charset="utf-8"',
          },
          body:
              '<?xml version="1.0" encoding="UTF-8"?>'
              '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
              's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
              '<s:Body>$body</s:Body></s:Envelope>',
        )
        .timeout(const Duration(seconds: 20));
  }

  /// Browse 一层目录（自动翻页），返回条目列表
  Future<List<_SonyContent>> _browse(String objectId) async {
    final out = <_SonyContent>[];
    var startingIndex = 0;
    while (true) {
      final resp = await _soap(
        '/upnp/control/ContentDirectory',
        'urn:schemas-upnp-org:service:ContentDirectory:1',
        'Browse',
        '<u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
            '<ObjectID>$objectId</ObjectID>'
            '<BrowseFlag>BrowseDirectChildren</BrowseFlag>'
            '<Filter>*</Filter>'
            '<StartingIndex>$startingIndex</StartingIndex>'
            '<RequestedCount>9999</RequestedCount>'
            '<SortCriteria></SortCriteria>'
            '</u:Browse>',
      );
      if (resp.statusCode != 200) {
        throw PtpException('读取内容列表失败 (${resp.statusCode})');
      }
      final doc = XmlDocument.parse(resp.body);
      // Result 里是转义过的第二层 XML（DIDL-Lite），需二次解析
      final resultText =
          doc.findAllElements('Result').firstOrNull?.innerText ?? '';
      if (resultText.isNotEmpty) {
        final didl = XmlDocument.parse(resultText);
        // 子目录递归（按拍摄日期分文件夹）
        for (final c in didl.findAllElements('container')) {
          final id = c.getAttribute('id') ?? '';
          if (id.isNotEmpty) {
            out.addAll(await _browse(id));
          }
        }
        for (final item in didl.findAllElements('item')) {
          final content = _SonyContent.parse(item);
          if (content != null) {
            out.add(content);
          }
        }
      }
      final returned =
          int.tryParse(
            doc.findAllElements('NumberReturned').firstOrNull?.innerText ?? '0',
          ) ??
          0;
      final total =
          int.tryParse(
            doc.findAllElements('TotalMatches').firstOrNull?.innerText ?? '0',
          ) ??
          0;
      startingIndex += returned;
      if (returned <= 0 || startingIndex >= total) break;
    }
    return out;
  }

  /// 拉取并缓存全部内容清单（合成句柄 = 条目 id 的哈希，会话内稳定）
  Future<List<int>> _refreshContents() async {
    final items = await _browse(_root);
    _contents.clear();
    for (final it in items) {
      _contents[it.handle] = it;
    }
    return _contents.keys.toList();
  }

  @override
  Future<List<int>> listObjectHandles() => _refreshContents();

  @override
  Future<PtpObjectInfo> getObjectInfo(int handle) async {
    final c = _contents[handle];
    if (c == null) throw PtpException('对象不存在');
    return PtpObjectInfo(
      storageId: 0xFFFFFFFF,
      objectFormat: 0x3801, // JPEG（WiFi 模式拿到的都是相机转出的 JPEG）
      size: c.size,
      parentObject: 0,
      filename: c.filename,
      captureDate: c.captureDate,
    );
  }

  /// RAW 条目只能拿到相机转出的 JPEG 预览：落盘时改名 .JPG，避免假 RAW
  @override
  Future<String> outputName(int handle, PtpObjectInfo info) async {
    final c = _contents[handle];
    if (c == null || !c.isPreview) return info.filename;
    final dot = info.filename.lastIndexOf('.');
    final stem = dot > 0 ? info.filename.substring(0, dot) : info.filename;
    return '$stem.JPG';
  }

  @override
  Future<int> download(
    int handle,
    int size,
    void Function(List<int> chunk) sink, {
    void Function(int received, int total)? onProgress,
  }) async {
    final c = _contents[handle];
    if (c == null) throw PtpException('对象不存在');
    final req = http.Request('GET', Uri.parse(c.originalUrl));
    final resp = await _client.send(req).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw PtpException('下载失败 (${resp.statusCode})');
    }
    final total = resp.contentLength ?? (size > 0 ? size : 0);
    var received = 0;
    final completer = Completer<void>();
    resp.stream.listen(
      (chunk) {
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

  @override
  Future<Uint8List> thumb(int handle) async {
    final c = _contents[handle];
    if (c == null) throw PtpException('对象不存在');
    final resp = await _client
        .get(Uri.parse(c.thumbUrl))
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) throw PtpException('缩略图获取失败');
    return Uint8List.fromList(resp.bodyBytes);
  }

  @override
  Future<String> model() async => _friendlyName;

  @override
  Future<PtpDeviceInfo> getDeviceInfo() async {
    return PtpDeviceInfo(
      manufacturer: 'Sony',
      model: _friendlyName,
      deviceVersion: '',
    );
  }

  @override
  Future<int?> deviceBattery() async => null;

  @override
  Future<int?> storageFreeBytes() async => null;

  @override
  Future<List<int>> getStorageIds() async => const [];

  @override
  void markKnown(Iterable<int> handles) => _known.addAll(handles);
  @override
  bool isKnown(int handle) => _known.contains(handle);
  @override
  void forgetHandles() => _known.clear();

  @override
  Future<void> close() async {
    try {
      await _soap(
        '/upnp/control/XPushList',
        'urn:schemas-sony-com:service:XPushList:1',
        'X_TransferEnd',
        '<u:X_TransferEnd xmlns:u="urn:schemas-sony-com:service:XPushList:1">'
            '<ErrCode>0</ErrCode></u:X_TransferEnd>',
      );
    } catch (_) {}
    _events.close();
    _client.close();
  }
}

/// 一条内容条目（DIDL-Lite item）
class _SonyContent {
  _SonyContent({
    required this.handle,
    required this.filename,
    required this.originalUrl,
    required this.thumbUrl,
    required this.size,
    required this.isPreview,
    this.captureDate,
  });

  final int handle;
  final String filename;
  final String originalUrl;
  final String thumbUrl;
  final int size;

  /// true = 原图是 RAW 但只能拿到 JPEG 预览（落盘需改名）
  final bool isPreview;
  final DateTime? captureDate;

  static _SonyContent? parse(XmlElement item) {
    final id = item.getAttribute('id') ?? '';
    final title = item.findAllElements('dc:title').firstOrNull?.innerText;
    final resElements = item.findAllElements('res').toList();
    if (id.isEmpty || title == null || resElements.isEmpty) return null;

    // 原图：优先 size 属性最大的；RAW 等无 size 的选 _LRG；兜底最后一个
    String? original;
    var bestSize = -1;
    for (final r in resElements) {
      final s = int.tryParse(r.getAttribute('size') ?? '') ?? 0;
      if (s > bestSize) {
        bestSize = s;
        original = r.innerText;
      }
    }
    if (original == null) {
      for (final r in resElements) {
        final p = r.getAttribute('protocolInfo') ?? '';
        if (p.contains('_LRG')) {
          original = r.innerText;
          break;
        }
      }
    }
    original ??= resElements.last.innerText;

    // 缩略图：_TN 优先，其次 _SM，兜底原图
    var thumb = original;
    for (final r in resElements) {
      final p = r.getAttribute('protocolInfo') ?? '';
      if (p.contains('_TN')) {
        thumb = r.innerText;
        break;
      }
    }

    DateTime? date;
    final dateText =
        item.findAllElements('dc:date').firstOrNull?.innerText ??
        item.findAllElements('upnp:date').firstOrNull?.innerText;
    if (dateText != null && dateText.length >= 19) {
      try {
        date = DateTime.parse(dateText.substring(0, 19));
      } catch (_) {}
    }

    // 原图是 RAW 但选中的下载源是 JPEG 预览 → 预览模式（落盘改名 .JPG）
    const rawExts = {'arw', 'sr2', 'cr2', 'cr3', 'nef', 'raf', 'dng'};
    final dot = title.lastIndexOf('.');
    final ext = dot > 0 ? title.substring(dot + 1).toLowerCase() : '';
    final originalLower = original.toLowerCase();
    final isPreview =
        rawExts.contains(ext) &&
        (originalLower.endsWith('.jpg') || originalLower.endsWith('.jpeg'));

    return _SonyContent(
      handle: id.hashCode,
      filename: title,
      originalUrl: original,
      thumbUrl: thumb,
      size: bestSize > 0 ? bestSize : 0,
      isPreview: isPreview,
      captureDate: date,
    );
  }
}
