import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/config.dart';

/// 用户取消上传（流式分片间检测，抛出即中止在途请求）
class UploadCancelled implements Exception {
  const UploadCancelled();
}

/// 网盘 API 客户端（契约见 BUILD_SPEC.md §3）
/// - 统一信封 { success, data, error }
/// - 401 自动用已存账号密码重登一次再重试
/// - 上传为流式 multipart（对齐网盘后端恒定内存约束）
class PanClient {
  PanClient._();
  static final PanClient instance = PanClient._();

  /// 单页条数（服务端默认 100、上限 500；这里取默认档）
  static const _listPageLimit = 100;

  /// 翻页上限防御：5 万条封顶，对应 500 页
  static const _maxListPages = 500;

  final http.Client _http = http.Client();

  Map<String, String> _authHeaders() {
    final t = AppConfig.instance.token;
    return t == null ? const {} : {'Authorization': 'Bearer $t'};
  }

  /// POST /api/auth/login → data.token
  Future<void> login() async {
    final cfg = AppConfig.instance;
    // jsonEncode 保证密码含引号/反斜杠等特殊字符时不破坏 JSON
    final body = jsonEncode({
      'username': cfg.username,
      'password': cfg.password,
    });
    final resp = await _http
        .post(
          cfg.api('/api/auth/login'),
          headers: cfg.jsonHeaders(),
          body: body,
        )
        .timeout(const Duration(seconds: 15));
    final data = await AppConfig.unwrapEnvelope(resp);
    final token = data is Map ? data['token'] : null;
    if (token is! String || token.isEmpty) {
      throw const ApiException('登录响应缺少 token');
    }
    await cfg.setToken(token);
    await cfg.save();
  }

  /// GET /api/folders?parent_id={id}（省略 = 根目录）
  Future<List<Map<String, dynamic>>> listFolders({int? parentId}) async {
    final resp = await _http.get(
      AppConfig.instance.api(
        '/api/folders',
        parentId == null ? null : {'parent_id': '$parentId'},
      ),
      headers: _authHeaders(),
    );
    final data = await _unwrapOrReauth(
      resp,
      () => listFolders(parentId: parentId),
    );
    final folders = (data as Map)['folders'] as List? ?? const [];
    return folders.cast<Map<String, dynamic>>();
  }

  /// POST /api/folders { name, parent_id }（parent_id 省略 = 根目录）
  Future<int> createFolder(String name, {int? parentId}) async {
    final body = parentId == null
        ? '{"name":"$name"}'
        : '{"name":"$name","parent_id":$parentId}';
    final resp = await _http.post(
      AppConfig.instance.api('/api/folders'),
      headers: AppConfig.instance.jsonHeaders(token: AppConfig.instance.token),
      body: body,
    );
    final data = await _unwrapOrReauth(
      resp,
      () => createFolder(name, parentId: parentId),
    );
    return (data as Map)['id'] as int;
  }

  /// 确保根目录下存在 yyyy-MM-dd 日期文件夹，返回其 id
  Future<int> ensureDateFolder(DateTime date) async {
    final name =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final folders = await listFolders();
    for (final f in folders) {
      if (f['name'] == name) return f['id'] as int;
    }
    return createFolder(name);
  }

  /// GET /api/files?folder_id={id} —— **游标分页**，单页上限 100（最多 500）
  ///
  /// 服务端 `data` 是对象 `{files, total, has_more, next_cursor, limit}`，
  /// 不是裸数组（早前按 `data as List` 解析，一旦调用必崩）。
  /// [allPages] 为 true 时自动翻完所有页——调用方要的是完整列表而非某一页。
  Future<List<Map<String, dynamic>>> listFiles({
    int? folderId,
    bool allPages = true,
  }) async {
    final out = <Map<String, dynamic>>[];
    String? cursor;
    // 翻页上限防御：服务端 has_more 依赖客户端正确回传 next_cursor，
    // 一旦服务端异常返回恒 true，这里不能无限循环
    for (var page = 0; page < _maxListPages; page++) {
      final pageData = await _listFilesPage(
        folderId: folderId,
        limit: _listPageLimit,
        cursor: cursor,
      );
      out.addAll(pageData.files);
      if (!pageData.hasMore) break;
      final next = pageData.nextCursor;
      // 游标没推进说明服务端状态异常，停在已取到的数据上而不是空转
      if (next == null || next.isEmpty || next == cursor) break;
      cursor = next;
    }
    return out;
  }

  /// 单页拉取（保留原始分页字段，供 listFiles 翻页与调试用）
  Future<({List<Map<String, dynamic>> files, bool hasMore, String? nextCursor})>
  listFilesPage({int? folderId, int? limit, String? cursor}) async {
    final data = await _listFilesPage(
      folderId: folderId,
      limit: limit,
      cursor: cursor,
    );
    return data;
  }

  Future<({List<Map<String, dynamic>> files, bool hasMore, String? nextCursor})>
  _listFilesPage({int? folderId, int? limit, String? cursor}) async {
    final query = <String, String>{
      if (folderId != null) 'folder_id': '$folderId',
      if (limit != null) 'limit': '$limit',
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    };
    final resp = await _http.get(
      AppConfig.instance.api('/api/files', query.isEmpty ? null : query),
      headers: _authHeaders(),
    );
    final data = await _unwrapOrReauth(
      resp,
      () => _listFilesPage(folderId: folderId, limit: limit, cursor: cursor),
    );
    // 服务端 data = {files:[...], total, has_more, next_cursor, limit}
    final map = data is Map ? data : const {};
    final raw = map['files'];
    final files = raw is List
        ? raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
        : const <Map<String, dynamic>>[];
    return (
      files: files,
      hasMore: map['has_more'] == true,
      nextCursor: map['next_cursor'] as String?,
    );
  }

  /// POST /api/files/upload，流式 multipart。
  /// folderId 传 null 表示根目录（禁止传 0 → 孤儿数据，见避坑清单 #8）。
  /// 401 时自动重登一次并重试（上传流已消费，需重建请求）。
  Future<void> uploadFile(
    String filePath, {
    required String fileName,
    int? folderId,
    void Function(int sent, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    try {
      await _uploadOnce(filePath, fileName, folderId, onProgress, isCancelled);
    } on ApiException catch (e) {
      if (e.status == 401 && AppConfig.instance.password.isNotEmpty) {
        await login();
        await _uploadOnce(
          filePath,
          fileName,
          folderId,
          onProgress,
          isCancelled,
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> _uploadOnce(
    String filePath,
    String fileName,
    int? folderId,
    void Function(int, int)? onProgress,
    bool Function()? isCancelled,
  ) async {
    final file = File(filePath);
    final total = await file.length();
    var sent = 0;
    // 流式分片间检查取消标志：抛出后 http 请求随流错误一并中止
    final counting = file.openRead().map((chunk) {
      if (isCancelled?.call() == true) throw const UploadCancelled();
      sent += chunk.length;
      onProgress?.call(sent, total);
      return chunk;
    });

    final req =
        http.MultipartRequest(
            'POST',
            AppConfig.instance.api('/api/files/upload'),
          )
          ..headers.addAll(_authHeaders())
          ..files.add(
            http.MultipartFile('file', counting, total, filename: fileName),
          );
    if (folderId != null) {
      req.fields['folder_id'] = '$folderId';
    }

    final resp = await _http.send(req).timeout(const Duration(hours: 2));
    final data = await AppConfig.unwrapEnvelope(resp);
    // 成功即可；data 内含文件信息，M0 暂不使用
    assert(data != null);
  }

  /// 解包；若 401 则重登一次并重试请求
  Future<dynamic> _unwrapOrReauth(
    http.Response resp,
    Future<dynamic> Function() retry,
  ) async {
    if (resp.statusCode == 401 && AppConfig.instance.password.isNotEmpty) {
      try {
        await login();
        final r2 = await retry();
        return r2;
      } on ApiException catch (e) {
        if (e.status == 401) {
          await AppConfig.instance.setToken(null);
          throw const ApiException('登录已过期，请重新登录');
        }
        rethrow;
      }
    }
    return AppConfig.unwrapEnvelope(resp);
  }
}
