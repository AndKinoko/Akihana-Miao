import 'package:flutter_test/flutter_test.dart';

import 'package:akihana_miao/main.dart';

void main() {
  testWidgets('App 启动直达相机页（网盘为独立服务，在设置页配置）', (tester) async {
    await tester.pumpWidget(const AkihanaApp());
    // 相机优先：默认展示相机页
    expect(find.text('USB 连接'), findsOneWidget);
    expect(find.text('WiFi 连接'), findsOneWidget);
  });
}
