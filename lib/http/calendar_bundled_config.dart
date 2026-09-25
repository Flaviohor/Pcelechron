import 'package:flutter/services.dart' show rootBundle;

/// 随包内置的校历配置（做法取自 Elychron）。
///
/// ## 为什么要有它
///
/// 校历来自上游 Celechron 的第三方静态站 `http://calendar.celechron.top/`：
/// 明文 HTTP、8 秒超时、域名和服务器都不在我们手里，连不上时只能退到
/// 「本地缓存」，而缓存为空时只能「本地推算」（节假日/调休全空、考试周不准）。
/// 把 JSON 直接打进包里：离线可用、首次安装就有、全新机器不再裸奔。
///
/// ## 更新方式
///
/// 远程每 7 天才尝试一次（见 TimeConfigService 的节流），连上后按新的覆盖缓存；
/// 随包版本跟着 App 版本走，发版前把 `assets/calendar/<学年学期>.json`
/// 换成官方站最新那份即可。
///
/// ## 数据是什么
///
/// 只含公开校历信息（开学/结束日期、节次时间表、节假日、调休），
/// 不含任何用户数据，格式与远程接口一致（见 calendar_config_parser.dart）。
class BundledCalendarConfig {
  BundledCalendarConfig._();

  /// 读过一次就记住（一个学期内校历不会变，没必要反复读盘）。
  static final Map<String, String?> _cache = <String, String?>{};

  /// 读取内置校历；没有内置就返回 null
  /// （更早的学期、或还没发布的未来学期，都属正常）。
  static Future<String?> load(String semesterId) async {
    if (_cache.containsKey(semesterId)) return _cache[semesterId];
    String? text;
    try {
      text = await rootBundle.loadString('assets/calendar/$semesterId.json');
    } on Object {
      // 没有这个文件不是错误：调用方继续往下一级兜底（本地推算）。
      text = null;
    }
    _cache[semesterId] = text;
    return text;
  }

  /// 当前随包带了哪几个学期，供资源自查与测试用。
  ///
  /// 加/删 `assets/calendar/` 里的文件时要同步更新这里。
  static const List<String> bundledSemesters = <String>[
    '2025-2026-1',
    '2025-2026-2',
    '2026-2027-1',
  ];
}
