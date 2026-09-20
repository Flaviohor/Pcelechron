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

// macOS 使用 Data Protection Keychain（useDataProtectionKeyChain: true），
// item 存储在 app 自己的 sandbox keychain container 中，不触发系统授权弹框。
// 旧版 login keychain（useDataProtectionKeyChain: false）在 sandbox 下每次启动
// 都会弹「PCelechron 想要访问你的钥匙串中的密钥 'flutter_secure_storage_service'」。
const secureStorageMacOsOptions = kDebugMode
    ? MacOsOptions(
        accountName: 'Celechron',
        useDataProtectionKeyChain: true,
      )
    : MacOsOptions(
        accountName: 'Celechron',
        useDataProtectionKeyChain: true,
      );
