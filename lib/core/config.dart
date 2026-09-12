import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 应用配置：网盘地址 + 账号 + 密码，持久化到本地。
/// lockhost 测试环境用默认 URL，随时可在设置页切到生产环境。
class AppConfig {
  AppConfig._();
  static final AppConfig instance = AppConfig._();

  static const _kBaseUrl = 'pan.baseUrl';
  static const _kUsername = 'pan.username';
  static const _kPassword = 'pan.password';
  static const _kToken = 'pan.token';
  static const _kUploadMode = 'pan.uploadMode';
  static const _kSaveToGallery = 'pan.saveToGallery';
  static const _kDeleteAfterUpload = 'pan.deleteAfterUpload';
  static const _kAutoPull = 'camera.autoPull';
  static const _kPullTypes = 'camera.pullTypes';
  static const _kDateFolders = 'save.dateFolders';
  static const _kChargeOnly = 'save.chargeOnly';
  static const _kLowBatteryPause = 'save.lowBatteryPause';
  static const _kBackgroundRun = 'camera.backgroundRun';
  static const _kBrandPreference = 'camera.brandPreference';

  /// 默认指向本机测试网盘（真机调试时改为 PC 局域网 IP）
  static const defaultBaseUrl = 'http://localhost:100';

  String baseUrl = defaultBaseUrl;
  String username = '';
  String password = '';

  /// 上传策略：0 仅保存到本地 / 1 WiFi 环境上传 / 2 立即上传
  int uploadMode = 1;

  /// 拉图是否同时保存到系统相册（本地优先，默认开）
  bool saveToGallery = true;

  /// 上传成功后删除本地文件（已拉取列表也不再显示）
  bool deleteAfterUpload = false;

  /// 自动拉取（ObjectAdded 事件驱动，默认开）
  bool autoPull = true;

  /// 自动拉取的文件类型（JPEG/NEF/MOV/MP4，可多选）
  Set<String> pullTypes = {'JPEG', 'NEF'};

  /// 相册按拍摄日期分文件夹（Pictures/AkihanaMiao/yyyy-MM-dd）
  bool dateFolders = true;

  /// 条件保护：仅充电时上传
  bool chargeOnly = false;

  /// 条件保护：电量低于阈值暂停上传
  bool lowBatteryPause = true;
  static const batteryThreshold = 20;

  /// 后台运行：前台服务保活，锁屏/退后台也能自动拉取和上传（默认开）
  bool backgroundRun = true;

  /// 相机品牌偏好：auto=自动探测 / nikon / sony（连接时过滤驱动）
  String brandPreference = 'auto';
  static const brandAuto = 'auto';
  static const brandNikon = 'nikon';
  static const brandSony = 'sony';

  static const allPullTypes = ['JPEG', 'NEF', 'MOV', 'MP4'];

  /// 扩展名 → 拉取类型
  static String extToPullType(String ext) {
    switch (ext.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'JPEG';
      case 'nef':
        return 'NEF';
      case 'mov':
        return 'MOV';
      case 'mp4':
        return 'MP4';
      default:
        return ext.toUpperCase();
    }
  }

  static const modeLocalOnly = 0;
  static const modeWifi = 1;
  static const modeImmediate = 2;

  /// 登录成功后的 JWT；每次修改密钥/重新登录会失效
  String? _token;
  String? get token => _token;
  bool get isLoggedIn => _token != null && _token!.isNotEmpty;

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    baseUrl = sp.getString(_kBaseUrl) ?? defaultBaseUrl;
    username = sp.getString(_kUsername) ?? '';
    password = sp.getString(_kPassword) ?? '';
    _token = sp.getString(_kToken);
    uploadMode = sp.getInt(_kUploadMode) ?? modeWifi;
    saveToGallery = sp.getBool(_kSaveToGallery) ?? true;
    deleteAfterUpload = sp.getBool(_kDeleteAfterUpload) ?? false;
    autoPull = sp.getBool(_kAutoPull) ?? true;
    pullTypes = sp.getStringList(_kPullTypes)?.toSet() ?? {'JPEG', 'NEF'};
    dateFolders = sp.getBool(_kDateFolders) ?? true;
    chargeOnly = sp.getBool(_kChargeOnly) ?? false;
    lowBatteryPause = sp.getBool(_kLowBatteryPause) ?? true;
    backgroundRun = sp.getBool(_kBackgroundRun) ?? true;
    brandPreference = sp.getString(_kBrandPreference) ?? brandAuto;
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kBaseUrl, baseUrl);
    await sp.setString(_kUsername, username);
    await sp.setString(_kPassword, password);
    await sp.setInt(_kUploadMode, uploadMode);
    await sp.setBool(_kSaveToGallery, saveToGallery);
    await sp.setBool(_kDeleteAfterUpload, deleteAfterUpload);
    await sp.setBool(_kAutoPull, autoPull);
    await sp.setStringList(_kPullTypes, pullTypes.toList());
    await sp.setBool(_kDateFolders, dateFolders);
    await sp.setBool(_kChargeOnly, chargeOnly);
    await sp.setBool(_kLowBatteryPause, lowBatteryPause);
    await sp.setBool(_kBackgroundRun, backgroundRun);
    await sp.setString(_kBrandPreference, brandPreference);
    if (_token != null) {
      await sp.setString(_kToken, _token!);
    }
  }

  /// 登录成功后保存 token；401 时清除
  Future<void> setToken(String? token) async {
    _token = token;
    final sp = await SharedPreferences.getInstance();
    if (token == null || token.isEmpty) {
      await sp.remove(_kToken);
    } else {
      await sp.setString(_kToken, token);
    }
  }

  /// 用当前 base url 拼接 API 路径
  Uri api(String path, [Map<String, String>? query]) {
    final u = Uri.parse(
      baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl,
    );
    return u
        .resolve(path)
        .replace(
          queryParameters: (query == null || query.isEmpty) ? null : query,
        );
  }

  Map<String, String> jsonHeaders({String? token}) => {
    'Content-Type': 'application/json; charset=utf-8',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  /// 统一信封解包：{ success, data, error }（兼容普通/流式响应）
  static Future<dynamic> unwrapEnvelope(http.BaseResponse resp) async {
    String body;
    if (resp is http.Response) {
      body = resp.body;
    } else if (resp is http.StreamedResponse) {
      body = await resp.stream.bytesToString();
    } else {
      body = '';
    }
    dynamic json;
    try {
      json = body.isEmpty ? null : jsonDecode(body);
    } catch (_) {
      json = null;
    }
    if (json is Map && json['success'] == true) {
      return json['data'];
    }
    final msg =
        (json is Map ? json['error'] : null) ?? '请求失败 (${resp.statusCode})';
    throw ApiException(msg.toString(), status: resp.statusCode);
  }
}

class ApiException implements Exception {
  final String message;
  final int? status;
  const ApiException(this.message, {this.status});

  @override
  String toString() => message;
}
