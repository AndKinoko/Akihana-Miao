import 'package:flutter/material.dart';

import '../cameras/camera_hub.dart';
import 'camera_page.dart';
import 'settings_page.dart';
import 'transfer_page.dart';
import 'widgets.dart';

/// 主页 tab 切换（相机页入口卡片跳传输页等跨页导航用）
final ValueNotifier<int> homeTabIndex = ValueNotifier<int>(0);

/// 主页：相机 / 传输 / 设置 三标签。
/// 大标题在顶栏与主题切换按钮同排；相机标题右侧带连接状态点。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: homeTabIndex,
      builder: (context, tab, _) => Scaffold(
        appBar: AppBar(
          // 相机页标题右侧显示连接状态（绿点脉冲 = 已连接）
          title: tab == 0
              ? AnimatedBuilder(
                  animation: CameraHub.instance,
                  builder: (context, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('相机'),
                      const SizedBox(width: 8),
                      StatusDot(on: CameraHub.instance.connected),
                    ],
                  ),
                )
              : Text(const ['传输', '设置'][tab - 1]),
          actions: const [ThemeToggleButton(), SizedBox(width: 12)],
        ),
        body: Stack(
          children: [
            // 三页常驻（Offstage 保活不丢状态），切 tab 时新页淡入，
            // 避免硬切导致「点击动画还在播、内容已瞬间跳走」的脱节感
            for (var i = 0; i < 3; i++)
              Offstage(
                offstage: i != tab,
                child: AnimatedOpacity(
                  opacity: i == tab ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: const [CameraPage(), TransferPage(), SettingsPage()][i],
                ),
              ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => homeTabIndex.value = i,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.photo_camera_outlined),
              label: '相机',
            ),
            NavigationDestination(icon: Icon(Icons.import_export), label: '传输'),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
}
