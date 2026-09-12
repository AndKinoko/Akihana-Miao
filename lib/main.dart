import 'package:flutter/material.dart';

import 'core/config.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.instance.load();
  await ThemeController.instance.load();
  runApp(const AkihanaApp());
}

class AkihanaApp extends StatelessWidget {
  const AkihanaApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 相机功能优先；网盘是独立服务，在设置页配置（未登录时上传自动挂起）
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance.mode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Akihana Miao',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: mode,
        home: const HomePage(),
      ),
    );
  }
}
