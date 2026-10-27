import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 门店配置服务 —— 分层配置 + 容错读写
///
/// ## 分层设计
///
/// 门店机上会同时存在两类配置，来源与生命周期完全不同：
///
/// | 层 | 文件 | 位置 | 写入者 | 生命周期 |
/// |---|---|---|---|---|
/// | 出厂配置 | `store_config.json` | 安装目录（exe 同级） | 安装包 | 随安装包分发，只读 |
/// | 用户配置 | `store_user_config.json` | `%APPDATA%\RustDesk\config\` | 客户端 | 用户填写，持久保存 |
///
/// 出厂配置随安装包分发到安装目录，用户无需手工拷贝；
/// 用户配置写在用户目录，**安装目录没有写权限时程序依然能正常保存**。
///
/// ## 读取优先级
///
/// 用户配置 > 出厂配置 > 内置默认值。
/// 用户配置里缺失的字段会回落到出厂配置（例如出厂配置带 adminToken，
/// 用户配置只填了门店名，则令牌仍来自出厂配置）。
///
/// ## 兼容性
///
/// 旧版本的 `store_sync.json`（仅含 apiServer/adminToken/addressBookUserId/
/// addressBookCollectionId）仍会被读取，避免升级后配置丢失。
class StoreConfigService {
  /// 出厂配置文件名（随安装包分发到安装目录）
  static const String kFactoryFileName = 'store_config.json';

  /// 用户配置文件名（写在用户配置目录）
  static const String kUserFileName = 'store_user_config.json';

  /// 旧版配置文件名（仅含同步所需字段），保留读取以兼容升级
  static const String kLegacyFileName = 'store_sync.json';

  static const String kKeyApiServer = 'apiServer';
  static const String kKeyAdminToken = 'adminToken';
  static const String kKeyAddressBookUserId = 'addressBookUserId';
  static const String kKeyAddressBookCollectionId = 'addressBookCollectionId';
  static const String kKeyStoreName = 'storeName';
  static const String kKeyConfigured = 'configured';

  /// 内置默认配置（编译进程序，作为最后兜底）
  static const Map<String, dynamic> kDefaults = <String, dynamic>{
    kKeyApiServer: 'http://192.168.100.190:21114',
    kKeyAdminToken: '',
    kKeyAddressBookUserId: 1,
    kKeyAddressBookCollectionId: 1,
    kKeyStoreName: '',
  };

  /// 单例，便于 UI 侧直接取用
  static final StoreConfigService instance = StoreConfigService._();
  StoreConfigService._();

  // ---------------------------------------------------------------------------
  // 路径解析
  // ---------------------------------------------------------------------------

  /// 程序（exe）所在目录 —— 出厂配置应被安装到此处
  static String get exeDir {
    try {
      return File(Platform.resolvedExecutable).parent.path;
    } catch (e) {
      debugPrint('[store_config] 解析 exe 目录失败: $e');
      return '';
    }
  }

  /// 用户配置目录 —— 与 RustDesk 自身的配置文件同级
  ///
  /// Rust 侧 `Config::path()` 在 Windows 上经 directories_next 落到
  /// `%APPDATA%\RustDesk\config\`（内部标识 APP_NAME 恒为 ASCII 的 "RustDesk"，
  /// 品牌显示名不参与路径），`RustDesk2.toml` 等配置文件都在这一层。
  /// 这里按同样的规则推导，保证与 RustDesk 配置同处一地、卸载时一并清理。
  ///
  /// 该目录属于当前登录用户，**永远可写** —— 这正是安装目录无写权限时
  /// 用户配置依然能保存下来的原因。
  static String? _userConfigDir;

  static Future<String> userConfigDir() async {
    if (_userConfigDir != null && _userConfigDir!.isNotEmpty) {
      return _userConfigDir!;
    }
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      _userConfigDir = '$appData\\RustDesk\\config';
      return _userConfigDir!;
    }
    // 非 Windows 或环境异常时的兜底：退到 exe 目录
    _userConfigDir = exeDir.isEmpty ? '.' : exeDir;
    return _userConfigDir!;
  }

  /// 出厂配置候选路径（按优先级）
  static List<String> factoryConfigPaths() {
    final dir = exeDir;
    if (dir.isEmpty) return const [];
    return <String>[
      '$dir\\$kFactoryFileName',   // 新版：出厂配置
      '$dir\\$kLegacyFileName',    // 旧版：同步配置（兼容）
    ];
  }

  /// 用户配置文件路径（首选位置）
  static Future<String> userConfigPath() async {
    final dir = await userConfigDir();
    return '$dir\\$kUserFileName';
  }

  /// 用户配置实际落地的位置（用于界面提示）。
  ///
  /// 优先返回已存在文件的路径；都不存在时返回首选位置。
  static Future<String> actualUserConfigPath() async {
    final candidates = <String>[];
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      candidates.add('$appData\\RustDesk\\config\\$kUserFileName');
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      candidates.add('$localAppData\\RustDesk\\config\\$kUserFileName');
    }
    final dir0 = exeDir;
    if (dir0.isNotEmpty) {
      candidates.add('$dir0\\$kUserFileName');
    }
    for (final p in candidates) {
      if (await File(p).exists()) return p;
    }
    return candidates.isEmpty ? '' : candidates.first;
  }

  // ---------------------------------------------------------------------------
  // 读写
  // ---------------------------------------------------------------------------

  /// 从某个 JSON 文件读取配置（UTF-8）。
  /// 返回 null 表示文件不存在或格式非法。
  static Future<Map<String, dynamic>?> _readJsonFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      // 显式按 UTF-8 读，避免 Windows 上按 GBK 解析导致中文乱码
      final bytes = await file.readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: false);
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('[store_config] 读取配置失败 $path: $e');
    }
    return null;
  }

  /// 读取出厂配置（只读，忽略用户配置）
  static Future<Map<String, dynamic>> loadFactoryConfig() async {
    final result = Map<String, dynamic>.from(kDefaults);
    for (final path in factoryConfigPaths()) {
      final cfg = await _readJsonFile(path);
      if (cfg != null) {
        result.addAll(cfg);
        debugPrint('[store_config] 出厂配置来自 $path');
        break;
      }
    }
    return result;
  }

  /// 读取用户配置（不存在则返回空表）
  static Future<Map<String, dynamic>> loadUserConfig() async {
    final path = await userConfigPath();
    return await _readJsonFile(path) ?? <String, dynamic>{};
  }

  /// 读取合并后的生效配置：用户配置覆盖出厂配置
  static Future<Map<String, dynamic>> loadEffectiveConfig() async {
    final merged = await loadFactoryConfig();
    final user = await loadUserConfig();
    merged.addAll(user);
    return merged;
  }

  /// 保存用户配置。
  ///
  /// 按优先级尝试多个**用户可写**的位置，全部失败才返回错误信息：
  /// 1. %APPDATA%\RustDesk\config\   —— 与 RustDesk 自身配置同级（首选）
  /// 2. %LOCALAPPDATA%\RustDesk\config\ —— %APPDATA% 不可用时的退路
  /// 3. exe 同目录                   —— 仅当该目录可写时（例如便携模式）
  ///
  /// **绝不写安装目录**（Program Files）：那里普通用户无写权限，
  /// 写了会失败并让用户配置丢失。
  ///
  /// 返回 null 表示成功；返回字符串表示失败原因（用于界面提示）。
  static Future<String?> saveUserConfig(Map<String, dynamic> config) async {
    final dirs = <String>[];
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      dirs.add('$appData\\RustDesk\\config');
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      dirs.add('$localAppData\\RustDesk\\config');
    }
    final dir0 = exeDir;
    if (dir0.isNotEmpty) {
      dirs.add(dir0);
    }

    final text = const JsonEncoder.withIndent('  ').convert(config);
    final bytes = utf8.encode(text);
    final errors = <String>[];

    for (final dir in dirs) {
      try {
        final file = File('$dir\\$kUserFileName');
        if (!await file.parent.exists()) {
          await file.parent.create(recursive: true);
        }
        // UTF-8 写出，不带 BOM
        await file.writeAsBytes(bytes, flush: true);
        return null;
      } catch (e) {
        errors.add('$dir: $e');
      }
    }
    debugPrint('[store_config] 保存用户配置失败: ${errors.join(' | ')}');
    return '保存失败：无可写目录（${errors.join('；')}）';
  }

  /// 读取门店名称（可能为空串）
  static Future<String> loadStoreName() async {
    final cfg = await loadEffectiveConfig();
    return (cfg[kKeyStoreName] ?? '').toString().trim();
  }

  /// 保存门店名称到用户配置
  static Future<String?> saveStoreName(String name) async {
    final user = await loadUserConfig();
    user[kKeyStoreName] = name.trim();
    user[kKeyConfigured] = true;
    return await saveUserConfig(user);
  }

  /// 是否已经配置过门店名（用于判断是否需要弹首次配置窗口）
  ///
  /// 判定依据：
  /// - 用户配置里 `configured == true`，或用户配置里已有门店名 —— 用户填过，不再打扰
  /// - 出厂配置里带了门店名 —— 安装包已预置，同样视为已配置
  ///
  /// 注意：**不能**把「出厂配置文件不存在」当作需要弹窗的理由，
  /// 否则安装包分发不完整时会每次启动都弹窗，无法正常使用。
  static Future<bool> isConfigured() async {
    final user = await loadUserConfig();
    if (user[kKeyConfigured] == true) return true;
    final name = (user[kKeyStoreName] ?? '').toString().trim();
    if (name.isNotEmpty) return true;
    // 出厂配置预置了门店名也算已配置
    final factory = await loadFactoryConfig();
    final factoryName = (factory[kKeyStoreName] ?? '').toString().trim();
    return factoryName.isNotEmpty;
  }

  /// 出厂配置是否可用（是否随包分发到位）
  static Future<bool> hasFactoryConfig() async {
    for (final path in factoryConfigPaths()) {
      final file = File(path);
      if (await file.exists()) return true;
    }
    return false;
  }

  /// 出厂配置是否包含令牌（决定门店名能否同步到服务器）
  static Future<bool> hasAdminToken() async {
    final cfg = await loadFactoryConfig();
    return (cfg[kKeyAdminToken] ?? '').toString().trim().isNotEmpty;
  }
}
