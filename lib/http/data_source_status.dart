/// 标记一次读取的真实来源，便于上层区分实时数据与可用但过期的降级结果。
enum DataSourceStatus {
  live,
  bundled,
  cache,
  fallback,
  unavailable,
}

extension DataSourceStatusLabel on DataSourceStatus {
  String get label => switch (this) {
        DataSourceStatus.live => '实时成功',
        DataSourceStatus.bundled => '随包内置',
        DataSourceStatus.cache => '使用缓存',
        DataSourceStatus.fallback => '使用默认配置',
        DataSourceStatus.unavailable => '不可用',
      };

  /// 随包内置与实时同级：它是随版本发布的经过校验的公开校历，
  /// 不代表「数据过期」，不应触发降级文案。
  bool get isDegraded =>
      this == DataSourceStatus.cache || this == DataSourceStatus.fallback;
}
