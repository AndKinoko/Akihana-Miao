import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/config.dart';

/// 网盘 API 客户端（契约见 BUILD_SPEC.md §3）
/// - 统一信封 { success, data, error }
/// - 401 自动用已存账号密码重登一次再重试
/// - 上传为流式 multipart（对齐网盘后端恒定内存约束）
class PanClient {
  PanClient._();
  static final PanClient instance = PanClient._();

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

  /// GET /api/files?folder_id={id}
  Future<List<Map<String, dynamic>>> listFiles({int? folderId}) async {
    final resp = await _http.get(
      AppConfig.instance.api(
        '/api/files',
        folderId == null ? null : {'folder_id': '$folderId'},
      ),
      headers: _authHeaders(),
    );
    final data = await _unwrapOrReauth(
      resp,
      () => listFiles(folderId: folderId),
    );
    return (data as List? ?? const []).cast<Map<String, dynamic>>();
  }

  /// POST /api/files/upload，流式 multipart。
  /// folderId 传 null 表示根目录（禁止传 0 → 孤儿数据，见避坑清单 #8）。
  /// 401 时自动重登一次并重试（上传流已消费，需重建请求）。
  Future<void> uploadFile(
    String filePath, {
    required String fileName,
    int? folderId,
    void Function(int sent, int total)? onProgress,
  }) async {
    try {
      await _uploadOnce(filePath, fileName, folderId, onProgress);
    } on ApiException catch (e) {
      if (e.status == 401 && AppConfig.instance.password.isNotEmpty) {
        await login();
        await _uploadOnce(filePath, fileName, folderId, onProgress);
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
  ) async {
    final file = File(filePath);
    final total = await file.length();
    var sent = 0;
    final counting = file.openRead().map((chunk) {
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
