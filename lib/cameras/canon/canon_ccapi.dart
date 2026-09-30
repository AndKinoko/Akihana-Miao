import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../ptp/ptp_link.dart' show PtpException;

/// Canon CCAPI（Camera Control API）HTTP 客户端。
///
/// 官方 REST 接口（相机菜单「Camera Control API」连接后启用），默认 HTTP
/// 端口 8080，响应为裸 JSON（无统一信封）。端点来自官方函数表 + 社区实测
/// （Canomate / canon-r7-ccapi）：
/// - GET /ccapi                            能力清单（探测用）
/// - GET /ccapi/ver100/deviceinformation   机型/固件
/// - GET /ccapi/ver100/devicestatus/battery
/// - GET /ccapi/ver110/devicestatus/storage
/// - GET /ccapi/ver{110,100}/contents      存储卡 URL 列表
/// - GET <存储 URL>                        目录 URL 列表
/// - GET <目录 URL>?kind=number            页数（每页 100 条）
/// - GET <目录 URL>?page=N                 文件 URL 列表
/// - GET <文件 URL>?kind=info              大小/修改时间
/// - GET <文件 URL>                        原图（流式）
/// - GET <文件 URL>?kind=thumbnail         缩略图
/// - GET /ccapi/ver100/event/polling?continue=off  新文件事件（addedcontents）
class CanonCcapi {
  CanonCcapi(this.host, {this.port = defaultPort});

  static const defaultPort = 8080;

  final String host;
  final int port;
  final http.Client _client = http.Client();
  String? _model;

  String get origin => 'http://$host:$port';

  Uri _uri(String pathOrUrl, [Map<String, String>? query]) {
    final raw = pathOrUrl.startsWith('http')
        ? pathOrUrl
        : '$origin${pathOrUrl.startsWith('/') ? '' : '/'}$pathOrUrl';
    var u = Uri.parse(raw);
    if (query != null && query.isNotEmpty) {
      u = u.replace(queryParameters: {...u.queryParameters, ...query});
    }
    return u;
  }

  Future<dynamic> _getJson(
    String pathOrUrl, {
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final resp = await _client.get(_uri(pathOrUrl, query)).timeout(timeout);
    if (resp.statusCode != 200) {
      throw PtpException('CCAPI 请求失败 (${resp.statusCode})', code: resp.statusCode);
    }
    if (resp.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(resp.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  /// 能力探测：GET /ccapi 返回 200 即本机为 CCAPI 相机
  static Future<bool> probe(
    String host, {
    int port = defaultPort,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final client = http.Client();
    try {
      final resp = await client
          .get(Uri.parse('http://$host:$port/ccapi'))
          .timeout(timeout);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// 机型名（deviceinformation）；读不到返回空串
  Future<String> model() async {
    if (_model != null) return _model!;
    try {
      final data = await _getJson('/ccapi/ver100/deviceinformation');
      if (data is Map) {
        final m =
            data['productname'] ?? data['modelname'] ?? data['model'] ?? data['nickname'];
        if (m is String && m.trim().isNotEmpty) {
          _model = m.trim();
          return _model!;
        }
      }
    } catch (_) {}
    return '';
  }

  /// 电池电量 0~100；不可读返回 null
  Future<int?> batteryLevel() async {
    try {
      final data = await _getJson('/ccapi/ver100/devicestatus/battery');
      final map = data is List ? (data.isEmpty ? null : data.first) : data;
      if (map is Map) {
        final v = map['level'];
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v);
      }
    } catch (_) {}
    return null;
  }

  /// 存储卡剩余空间（字节）：ver110/ver100 的 storage 列表求和
  Future<int?> storageFreeBytes() async {
    for (final path in const [
      '/ccapi/ver110/devicestatus/storage',
      '/ccapi/ver100/devicestatus/storage',
    ]) {
      try {
        final data = await _getJson(path);
        final list = _storageList(data);
        if (list.isEmpty) continue;
        var sum = 0;
        var found = false;
        for (final s in list) {
          final v = s['spacesize'] ?? s['freespace'] ?? s['space'];
          if (v is num) {
            sum += v.toInt();
            found = true;
          } else if (v is String) {
            final n = int.tryParse(v);
            if (n != null) {
              sum += n;
              found = true;
            }
          }
        }
        if (found) return sum;
      } catch (_) {}
    }
    return null;
  }

  List<Map<String, dynamic>> _storageList(dynamic data) {
    dynamic raw = data;
    if (data is Map) {
      raw = data['storagelist'] ?? data['storage'] ?? data['storages'];
    }
    if (raw is List) {
      return [
        for (final e in raw)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    }
    return const [];
  }

  /// 存储卡 URL 列表（ver110 优先，ver100 兜底）
  Future<List<String>> listStorages() async {
    PtpException? last;
    for (final ver in const ['ver110', 'ver100']) {
      try {
        final data = await _getJson('/ccapi/$ver/contents');
        final paths = extractPaths(data);
        if (paths.isNotEmpty) return paths;
      } on PtpException catch (e) {
        last = e;
      }
    }
    if (last != null) throw last;
    return const [];
  }

  /// 目录下的子项 URL 列表（目录或文件，由调用方按路径扩展名区分）
  Future<List<String>> listChildren(String url) async {
    final data = await _getJson(url);
    return extractPaths(data);
  }

  /// 目录页数（?kind=number）；不支持返回 null
  Future<int?> pageCount(String dirUrl) async {
    try {
      final data = await _getJson(dirUrl, query: const {'kind': 'number'});
      if (data is Map) {
        final v = data['pagenumber'] ?? data['pagenum'] ?? data['page'];
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v);
      }
    } catch (_) {}
    return null;
  }

  /// 目录第 [page] 页的文件 URL 列表（每页最多 100 条）
  Future<List<String>> listPage(String dirUrl, int page) async {
    final data = await _getJson(dirUrl, query: {'page': '$page'});
    return extractPaths(data);
  }

  /// 文件信息（?kind=info）：filesize / lastmodifieddate
  Future<Map<String, dynamic>?> fileInfo(String fileUrl) async {
    try {
      final data = await _getJson(
        fileUrl,
        query: const {'kind': 'info'},
        timeout: const Duration(seconds: 8),
      );
      if (data is Map) return Map<String, dynamic>.from(data);
      if (data is List && data.isNotEmpty && data.first is Map) {
        return Map<String, dynamic>.from(data.first as Map);
      }
    } catch (_) {}
    return null;
  }

  /// 内容变更事件（短轮询，continue=off）：addedcontents / removedcontents
  /// 为文件 URL（单个或数组）
  Future<({List<String> added, List<String> removed})> pollContentChanges() async {
    final data = await _getJson(
      '/ccapi/ver100/event/polling',
      query: const {'continue': 'off'},
      timeout: const Duration(seconds: 8),
    );
    List<String> pick(String key) {
      if (data is Map) {
        final v = data[key];
        if (v is String && v.isNotEmpty) return [v];
        if (v is List) {
          return [
            for (final e in v)
              if (e is String && e.isNotEmpty) e,
          ];
        }
      }
      return const [];
    }

    return (added: pick('addedcontents'), removed: pick('removedcontents'));
  }

  /// 流式 GET（原图下载；超时只约束响应头）
  Future<http.StreamedResponse> streamGet(
    String pathOrUrl, {
    Map<String, String>? query,
  }) => _client.send(http.Request('GET', _uri(pathOrUrl, query)));

  /// 小文件 GET（缩略图）
  Future<Uint8List?> bytes(
    String url, {
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final resp = await _client.get(_uri(url, query)).timeout(timeout);
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// 从 CCAPI 响应提取路径列表：
  /// ver110+ 为 {"path":[...]}；部分机型为 {"files":[{"url":...}]}；少数直接数组
  static List<String> extractPaths(dynamic data) {
    if (data is List) {
      return [
        for (final e in data)
          if (e is String)
            e
          else if (e is Map && e['url'] is String)
            e['url'] as String
          else if (e is Map && e['path'] is String)
            e['path'] as String,
      ];
    }
    if (data is Map) {
      for (final key in const ['path', 'files', 'contents']) {
        final v = data[key];
        if (v is List) {
          final out = <String>[
            for (final e in v)
              if (e is String)
                e
              else if (e is Map && e['url'] is String)
                e['url'] as String
              else if (e is Map && e['path'] is String)
                e['path'] as String,
          ];
          if (out.isNotEmpty) return out;
        }
      }
    }
    return const [];
  }

  void close() => _client.close();
}
