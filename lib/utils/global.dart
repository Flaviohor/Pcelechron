import 'package:flutter/material.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

final class GlobalStatus {
  static bool isFirstScreenReq = false;
}

/// 应用显示版本（如 "PC-1.3.4"）。
///
/// main 启动时从 PackageInfo（平台版本资源，随 pubspec.yaml 的 version
/// 自动更新）加载，避免 Fuse 里再出现硬编码版本号。仅在平台通道异常时
/// 回退到 [kAppVersionFallback]——发版改 pubspec 版本时顺手改这里。
const String kAppVersionFallback = '1.3.4';
String appDisplayVersion = 'PC-$kAppVersionFallback';
