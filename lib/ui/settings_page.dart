import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/keep_alive.dart';
import '../pan/api_client.dart';
import '../pan/upload_queue.dart';
import 'widgets.dart';

/// 设置页：分组列表 + 四个二级子页
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final cfg = AppConfig.instance;
    final cs = Theme.of(context).colorScheme;
    final modeText = switch (cfg.uploadMode) {
      AppConfig.modeLocalOnly => '保存到本地',
      AppConfig.modeWifi => 'WiFi 环境上传',
      _ => '立即上传',
    };
    final loggedIn = cfg.isLoggedIn;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24, top: 4),
      children: [
        const SizedBox(height: 2),
        const SectionHeader('连接与拉取'),
        GroupList(
          rows: [
            ListRow(
              icon: Icons.download,
              title: '自动拉取',
              subtitle: '拍照后经 ObjectAdded 事件即时拉到手机相册',
              trailing: IosSwitch(
                value: cfg.autoPull,
                onChanged: (v) async {
                  setState(() => AppConfig.instance.autoPull = v);
                  await AppConfig.instance.save();
                },
              ),
            ),
            ListRow(
              icon: Icons.sync_lock,
              title: '后台运行',
              subtitle: '通知栏常驻提醒，锁屏也能自动拉取和上传',
              trailing: IosSwitch(
                value: cfg.backgroundRun,
                onChanged: (v) async {
                  setState(() => AppConfig.instance.backgroundRun = v);
                  await AppConfig.instance.save();
                  KeepAliveSync.onSettingChanged();
                },
              ),
            ),
            ListRow(
              icon: Icons.tune,
              title: '拉取策略',
              subtitle:
                  '类型：${cfg.pullTypes.join(' / ')}'
                  ' · 充电保护：${cfg.chargeOnly ? '开' : '关'}',
              trailing: Icon(
                Icons.arrow_forward,
                size: 16,
                color: cs.onSurfaceVariant,
              ),
              onTap: () => _push(const PullStrategyPage()),
            ),
          ],
        ),
        const SectionHeader('上传与保存'),
        GroupList(
          rows: [
            ListRow(
              icon: Icons.upload,
              title: '上传策略',
              subtitle: modeText,
              trailing: Icon(
                Icons.arrow_forward,
                size: 16,
                color: cs.onSurfaceVariant,
              ),
              onTap: () => _push(const UploadStrategyPage()),
            ),
            ListRow(
              icon: Icons.photo_library_outlined,
              title: '相册与存储',
              subtitle:
                  '相册「AkihanaMiao」· 日期分文件夹：'
                  '${cfg.dateFolders ? '开' : '关'} · 上传后删除：'
                  '${cfg.deleteAfterUpload ? '开' : '关'}',
              trailing: Icon(
                Icons.arrow_forward,
                size: 16,
                color: cs.onSurfaceVariant,
              ),
              onTap: () => _push(const AlbumStoragePage()),
            ),
          ],
        ),
        const SectionHeader('网盘服务'),
        AppCard(
          onTap: () => _push(const PanServicePage()),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.cloud_outlined,
                  size: 19,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '私有网盘',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      cfg.baseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              PulsePill(text: loggedIn ? '已登录' : '未登录', off: !loggedIn),
              const SizedBox(width: 6),
              Icon(Icons.arrow_forward, size: 16, color: cs.onSurfaceVariant),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'Akihana Miao',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    setState(() {}); // 返回时刷新摘要
  }
}

/// 二级：上传策略（三档单选）
class UploadStrategyPage extends StatefulWidget {
  const UploadStrategyPage({super.key});

  @override
  State<UploadStrategyPage> createState() => _UploadStrategyPageState();
}

class _UploadStrategyPageState extends State<UploadStrategyPage> {
  Future<void> _setMode(int mode) async {
    setState(() => AppConfig.instance.uploadMode = mode);
    await AppConfig.instance.save();
    UploadQueue.instance.kick();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = AppConfig.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('上传策略')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          Text(
            '文件拉取到相册后，按所选策略上传网盘',
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          IosRadioRow(
            title: '保存到本地',
            subtitle: '留在相册，不占用上传带宽',
            selected: cfg.uploadMode == AppConfig.modeLocalOnly,
            onTap: () => _setMode(AppConfig.modeLocalOnly),
          ),
          IosRadioRow(
            title: 'WiFi 环境上传',
            subtitle: '连接可上网的 WiFi 后自动上传',
            selected: cfg.uploadMode == AppConfig.modeWifi,
            onTap: () => _setMode(AppConfig.modeWifi),
          ),
          IosRadioRow(
            title: '立即上传',
            subtitle: '马上上传，可能消耗移动流量',
            selected: cfg.uploadMode == AppConfig.modeImmediate,
            onTap: () => _setMode(AppConfig.modeImmediate),
          ),
        ],
      ),
    );
  }
}

/// 二级：拉取策略（自动拉取开关在上级；类型多选 + 条件保护）
class PullStrategyPage extends StatefulWidget {
  const PullStrategyPage({super.key});

  @override
  State<PullStrategyPage> createState() => _PullStrategyPageState();
}

class _PullStrategyPageState extends State<PullStrategyPage> {
  @override
  Widget build(BuildContext context) {
    final cfg = AppConfig.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('拉取策略')),
      body: ListView(
        children: [
          const SectionHeader('自动拉取的文件类型'),
          GroupList(
            rows: [
              for (final t in const [
                ('JPEG', '约 10 MB/张'),
                ('NEF（RAW）', '约 25 MB/张'),
                ('MOV', '视频'),
                ('MP4', '视频'),
              ])
                IosCheckRow(
                  title: t.$1,
                  trailing: t.$2,
                  checked: cfg.pullTypes.contains(
                    t.$1.contains('（')
                        ? t.$1.substring(0, t.$1.indexOf('（'))
                        : t.$1,
                  ),
                  onToggle: () async {
                    final key = t.$1.contains('（')
                        ? t.$1.substring(0, t.$1.indexOf('（'))
                        : t.$1;
                    setState(() {
                      cfg.pullTypes.contains(key)
                          ? cfg.pullTypes.remove(key)
                          : cfg.pullTypes.add(key);
                    });
                    await AppConfig.instance.save();
                  },
                ),
            ],
          ),
          const SectionHeader('条件保护'),
          GroupList(
            rows: [
              ListRow(
                title: '仅充电时上传',
                subtitle: '接通电源才允许上传，防止耗电',
                trailing: IosSwitch(
                  value: cfg.chargeOnly,
                  onChanged: (v) async {
                    setState(() => AppConfig.instance.chargeOnly = v);
                    await AppConfig.instance.save();
                    UploadQueue.instance.kick();
                  },
                ),
              ),
              ListRow(
                title: '电量低于 ${AppConfig.batteryThreshold}% 暂停上传',
                subtitle: '恢复充电后自动继续',
                trailing: IosSwitch(
                  value: cfg.lowBatteryPause,
                  onChanged: (v) async {
                    setState(() => AppConfig.instance.lowBatteryPause = v);
                    await AppConfig.instance.save();
                    UploadQueue.instance.kick();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 二级：相册与存储（日期分文件夹 + RAW/视频独立目录 + 上传后删除）
class AlbumStoragePage extends StatefulWidget {
  const AlbumStoragePage({super.key});

  @override
  State<AlbumStoragePage> createState() => _AlbumStoragePageState();
}

class _AlbumStoragePageState extends State<AlbumStoragePage> {
  @override
  Widget build(BuildContext context) {
    final cfg = AppConfig.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('相册与存储')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          AppCard(
            flat: true,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.photo_album_outlined, size: 19),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '系统相册「AkihanaMiao」',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          GroupList(
            rows: [
              ListRow(
                title: '按拍摄日期分文件夹',
                subtitle: '相册内按 2026-09-11 这样的日子分组',
                trailing: IosSwitch(
                  value: cfg.dateFolders,
                  onChanged: (v) async {
                    setState(() => AppConfig.instance.dateFolders = v);
                    await AppConfig.instance.save();
                  },
                ),
              ),
              ListRow(
                title: 'RAW / 视频存独立目录',
                subtitle: 'RAW→Download、视频→Movies，不进相册时间线（固定行为）',
                trailing: Text(
                  '始终开启',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ListRow(
                title: '上传后删除本地副本',
                subtitle: '释放空间，已拉取列表同步移除',
                trailing: IosSwitch(
                  value: cfg.deleteAfterUpload,
                  onChanged: (v) async {
                    // 二次确认：涉及删除行为
                    if (v) {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('开启上传后删除'),
                          content: const Text(
                            '上传成功后将删除手机里的本地副本，'
                            '已拉取列表随之移除；'
                            '失败的任务一律保留。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('开启'),
                            ),
                          ],
                        ),
                      );
                      if (ok != true) return;
                    }
                    setState(() => AppConfig.instance.deleteAfterUpload = v);
                    await AppConfig.instance.save();
                  },
                ),
              ),
              ListRow(
                title: '保存到系统相册',
                subtitle: '关闭后只存应用缓存，相册不可见',
                trailing: IosSwitch(
                  value: cfg.saveToGallery,
                  onChanged: (v) async {
                    setState(() => AppConfig.instance.saveToGallery = v);
                    await AppConfig.instance.save();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 二级：网盘服务（URL / 账号 / 密码，登录后显示状态）
class PanServicePage extends StatefulWidget {
  const PanServicePage({super.key});

  @override
  State<PanServicePage> createState() => _PanServicePageState();
}

class _PanServicePageState extends State<PanServicePage> {
  late final TextEditingController _url;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  bool _busy = false;
  String? _message;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    final cfg = AppConfig.instance;
    _url = TextEditingController(text: cfg.baseUrl);
    _user = TextEditingController(text: cfg.username);
    _pass = TextEditingController(text: cfg.password);
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      AppConfig.instance
        ..baseUrl = _url.text.trim()
        ..username = _user.text.trim()
        ..password = _pass.text;
      await PanClient.instance.login();
      if (!mounted) return;
      setState(() {
        _ok = true;
        _message = '登录成功，已连接网盘';
      });
      UploadQueue.instance.kick();
    } catch (e) {
      setState(() {
        _ok = false;
        _message = '登录失败：$e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    await AppConfig.instance.setToken(null);
    setState(() {
      _ok = false;
      _message = '已退出登录';
    });
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = AppConfig.instance.isLoggedIn;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('网盘服务')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          Text(
            '登录后按上传策略自动上传到私有网盘',
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (loggedIn) ...[
            AppCard(
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF30D158,
                          ).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.check,
                          size: 19,
                          color: Color(0xFF30D158),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '已登录 · ${AppConfig.instance.username}',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              AppConfig.instance.baseUrl,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _logout,
                style: OutlinedButton.styleFrom(foregroundColor: cs.error),
                child: const Text('退出登录'),
              ),
            ),
          ] else ...[
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '服务器地址（URL）',
                hintText: 'http://localhost:100（真机请填 PC 局域网 IP）',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: '账号'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _login,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存并登录'),
              ),
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(
              _message!,
              style: TextStyle(
                fontSize: 13,
                color: _ok ? const Color(0xFF30D158) : cs.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
