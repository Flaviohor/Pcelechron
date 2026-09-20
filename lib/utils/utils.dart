import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

DateTime dateOnly(DateTime date, {int? hour, int? minute}) {
  return DateTime(date.year, date.month, date.day, hour ?? 0, minute ?? 0);
}

String durationToString(Duration duration) {
  String str = '';
  if (duration.inHours != 0) {
    str = '${duration.inHours} 小时';
  }
  if (duration.inMinutes % 60 != 0 || duration.inHours == 0) {
    if (str != '') str = '$str ';
    str = '$str${duration.inMinutes % 60} 分钟';
  }
  return str;
}

String toStringHumanReadable(DateTime dateTime) {
  String str =
      dateTime.toLocal().toIso8601String().replaceFirst(RegExp(r'T'), ' ');
  str = str.substring(0, str.length - 7);
  return str;
}

const secureStorageIOSOptions = kDebugMode
    ? IOSOptions(
        accessibility: KeychainAccessibility.first_unlock,
        accountName: 'Celechron',
        groupId: 'group.top.celechron.celechron.debug')
    : IOSOptions(
        accessibility: KeychainAccessibility.first_unlock,
        accountName: 'Celechron',
        groupId: 'group.top.celechron.celechron');

// macOS 必须显式传 groupId，Swift 端的 FlutterSecureStorage.swift 会把它写到
// kSecAttrAccessGroup；少了它，item 落到 login keychain（不是 app 自己的 group），
// macOS 每次启动都弹「PCelechron 想要访问你的钥匙串中的密钥 'flutter_secure_storage_service'」
// 框要求用户输入登录密码。debug 后缀与 iOS 保持一致便于识别。
// 注意：必须与 macos/Runner/Release.entitlements 的 keychain-access-groups 字符串
// 一致（`group.top.celechron.celechron`），且对应 entitlement 必须存在，
// 否则 SecItemAdd 返回 errSecMissingEntitlement。
const secureStorageMacOsOptions = kDebugMode
    ? MacOsOptions(
        groupId: 'group.top.celechron.celechron.debug',
        accountName: 'Celechron',
        useDataProtectionKeyChain: false,
      )
    : MacOsOptions(
        groupId: 'group.top.celechron.celechron',
        accountName: 'Celechron',
        useDataProtectionKeyChain: false,
      );
