import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 应用配置：网盘地址 + 账号 + 密码，持久化到本地。
/// lockhost 测试环境用默认 URL，随时可在设置页切到生产环境。
///
/// 密码是唯一的敏感字段，单独存进 flutter_secure_storage（Android 侧为
/// Keystore 加密的 EncryptedSharedPreferences）；其余配置仍走普通
/// SharedPreferences——它们丢了重新填一次即可，不值得为加密付出性能代价。
class AppConfig extends ChangeNotifier {
  AppConfig._();
  static final AppConfig instance = AppConfig._();

  static const _secure = FlutterSecureStorage();
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

  String _baseUrl = defaultBaseUrl;
  String _username = '';
  String _password = '';

  /// 配置字段一律走私有存储 + notifying setter：设置页改动会广播到
  /// 所有监听方（相机页策略摘要、传输页模式文案），不再依赖跨页 setState
  String get baseUrl => _baseUrl;
  set baseUrl(String v) {
    if (_baseUrl == v) return;
    _baseUrl = v;
    notifyListeners();
  }

  String get username => _username;
  set username(String v) {
    if (_username == v) return;
    _username = v;
    notifyListeners();
  }

  String get password => _password;
  set password(String v) {
    if (_password == v) return;
    _password = v;
    notifyListeners();
  }

  /// 上传策略：0 仅保存到本地 / 1 WiFi 环境上传 / 2 立即上传
  int _uploadMode = 1;
  int get uploadMode => _uploadMode;
  set uploadMode(int v) {
    if (_uploadMode == v) return;
    _uploadMode = v;
    notifyListeners();
  }

  /// 拉图是否同时保存到系统相册（本地优先，默认开）。
  /// 关闭后文件改落 Download/AkihanaMiao——仍在「已拉取」面板可见，
  /// 只是不进系统相册时间线
  bool _saveToGallery = true;
  bool get saveToGallery => _saveToGallery;
  set saveToGallery(bool v) {
    if (_saveToGallery == v) return;
    _saveToGallery = v;
    notifyListeners();
  }

  /// 上传成功后删除本地文件（已拉取列表也不再显示）
  bool _deleteAfterUpload = false;
  bool get deleteAfterUpload => _deleteAfterUpload;
  set deleteAfterUpload(bool v) {
    if (_deleteAfterUpload == v) return;
    _deleteAfterUpload = v;
    notifyListeners();
  }

  /// 自动拉取（ObjectAdded 事件驱动，默认开）
  bool _autoPull = true;
  bool get autoPull => _autoPull;
  set autoPull(bool v) {
    if (_autoPull == v) return;
    _autoPull = v;
    notifyListeners();
  }

  /// 自动拉取的文件类型（JPEG/NEF/MOV/MP4，可多选）
  Set<String> _pullTypes = {'JPEG', 'NEF'};
  Set<String> get pullTypes => _pullTypes;
  set pullTypes(Set<String> v) {
    if (setEquals(_pullTypes, v)) return;
    _pullTypes = v;
    notifyListeners();
  }

  /// 相册按拍摄日期分文件夹（Pictures/AkihanaMiao/yyyy-MM-dd）
  bool _dateFolders = true;
  bool get dateFolders => _dateFolders;
  set dateFolders(bool v) {
    if (_dateFolders == v) return;
    _dateFolders = v;
    notifyListeners();
  }

  /// 条件保护：仅充电时上传
  bool _chargeOnly = false;
  bool get chargeOnly => _chargeOnly;
  set chargeOnly(bool v) {
    if (_chargeOnly == v) return;
    _chargeOnly = v;
    notifyListeners();
  }

  /// 条件保护：电量低于阈值暂停上传
  bool _lowBatteryPause = true;
  bool get lowBatteryPause => _lowBatteryPause;
  set lowBatteryPause(bool v) {
    if (_lowBatteryPause == v) return;
    _lowBatteryPause = v;
    notifyListeners();
  }

  static const batteryThreshold = 20;

  /// 后台运行：前台服务保活，锁屏/退后台也能自动拉取和上传（默认开）
  bool _backgroundRun = true;
  bool get backgroundRun => _backgroundRun;
  set backgroundRun(bool v) {
    if (_backgroundRun == v) return;
    _backgroundRun = v;
    notifyListeners();
  }

  /// 相机品牌偏好：auto=自动探测 / nikon / sony / canon（连接时过滤驱动）
  String _brandPreference = 'auto';
  String get brandPreference => _brandPreference;
  set brandPreference(String v) {
    if (_brandPreference == v) return;
    _brandPreference = v;
    notifyListeners();
  }

  static const brandAuto = 'auto';
  static const brandNikon = 'nikon';
  static const brandSony = 'sony';
  static const brandCanon = 'canon';

  static const allPullTypes = ['JPEG', 'NEF', 'CR3', 'CR2', 'MOV', 'MP4'];

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

  /// 登录成功后的 JWT；每次修改密钥/重新登录会失效。
  /// 与密码同级敏感，一并走加密存储
  String? _token;
  String? get token => _token;
  bool get isLoggedIn => _token != null && _token!.isNotEmpty;

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    _baseUrl = sp.getString(_kBaseUrl) ?? defaultBaseUrl;
    _username = sp.getString(_kUsername) ?? '';
    _uploadMode = sp.getInt(_kUploadMode) ?? modeWifi;
    _saveToGallery = sp.getBool(_kSaveToGallery) ?? true;
    _deleteAfterUpload = sp.getBool(_kDeleteAfterUpload) ?? false;
    _autoPull = sp.getBool(_kAutoPull) ?? true;
    _pullTypes = sp.getStringList(_kPullTypes)?.toSet() ?? {'JPEG', 'NEF'};
    _dateFolders = sp.getBool(_kDateFolders) ?? true;
    _chargeOnly = sp.getBool(_kChargeOnly) ?? false;
    _lowBatteryPause = sp.getBool(_kLowBatteryPause) ?? true;
    _backgroundRun = sp.getBool(_kBackgroundRun) ?? true;
    _brandPreference = sp.getString(_kBrandPreference) ?? brandAuto;
    // 密码/token 走加密存储；读失败（Keystore 异常、旧版本残留）时按未登录处理，
    // 用户在设置页重新输一次即可，不因此卡住启动
    try {
      _password = await _secure.read(key: _kPassword) ?? '';
      _token = await _secure.read(key: _kToken);
    } catch (e) {
      debugPrint('读取加密配置失败（按未登录处理）: $e');
      _password = '';
      _token = null;
    }
    // 旧版本把密码/token 明文存在 SharedPreferences：搬进加密存储后立刻抹掉，
    // 否则升级用户的凭据仍以明文留在磁盘上
    await _migrateLegacySecrets(sp);
    notifyListeners();
  }

  /// 明文 → 加密存储的一次性迁移（幂等：搬完即删旧键）
  Future<void> _migrateLegacySecrets(SharedPreferences sp) async {
    final legacyPassword = sp.getString(_kPassword);
    final legacyToken = sp.getString(_kToken);
    if (legacyPassword == null && legacyToken == null) return;
    try {
      if (legacyPassword != null && _password.isEmpty) {
        await _secure.write(key: _kPassword, value: legacyPassword);
        _password = legacyPassword;
      }
      if (legacyToken != null && _token == null) {
        await _secure.write(key: _kToken, value: legacyToken);
        _token = legacyToken;
      }
      await sp.remove(_kPassword);
      await sp.remove(_kToken);
      debugPrint('已把明文凭据迁移到加密存储');
    } catch (e) {
      debugPrint('迁移明文凭据失败: $e');
    }
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kBaseUrl, _baseUrl);
    await sp.setString(_kUsername, _username);
    await sp.setInt(_kUploadMode, _uploadMode);
    await sp.setBool(_kSaveToGallery, _saveToGallery);
    await sp.setBool(_kDeleteAfterUpload, _deleteAfterUpload);
    await sp.setBool(_kAutoPull, _autoPull);
    await sp.setStringList(_kPullTypes, _pullTypes.toList());
    await sp.setBool(_kDateFolders, _dateFolders);
    await sp.setBool(_kChargeOnly, _chargeOnly);
    await sp.setBool(_kLowBatteryPause, _lowBatteryPause);
    await sp.setBool(_kBackgroundRun, _backgroundRun);
    await sp.setString(_kBrandPreference, _brandPreference);
    try {
      await _secure.write(key: _kPassword, value: _password);
    } catch (e) {
      debugPrint('写入加密密码失败: $e');
    }
    notifyListeners();
  }

  /// 登录成功后保存 token；401 时清除
  Future<void> setToken(String? token) async {
    _token = token;
    notifyListeners();
    try {
      if (token == null || token.isEmpty) {
        await _secure.delete(key: _kToken);
      } else {
        await _secure.write(key: _kToken, value: token);
      }
    } catch (e) {
      debugPrint('写入加密 token 失败: $e');
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
