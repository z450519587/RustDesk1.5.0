import 'package:flutter/material.dart';
import 'package:flutter_hbb/store_config_service.dart';
import 'package:flutter_hbb/store_sync_service.dart';

/// 首次启动配置窗口
///
/// 触发时机（任一满足即弹）：
/// - 用户配置不存在（首次运行 / 配置被清掉）
/// - 门店名称为空
/// - 出厂配置缺失（安装包没带上 store_config.json）
///
/// 弹窗内的字段：
/// - 门店名称：必填，保存到用户配置目录
/// - API 服务器：可选，出厂配置已有则默认带出
/// - 管理员令牌：可选，出厂配置已有则默认带出并置灰（避免门店误改）
///
/// 保存失败（例如目录无写权限）时**不关闭弹窗**，直接给出明确提示，
/// 保证程序在异常环境下仍可继续使用。
class StoreSetupDialog extends StatefulWidget {
  const StoreSetupDialog({Key? key}) : super(key: key);

  /// 弹出配置窗口。
  ///
  /// 返回 true 表示用户已成功保存配置。
  static Future<bool> show(BuildContext context, {bool barrierDismissible = false}) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (_) => const StoreSetupDialog(),
    );
    return result == true;
  }

  @override
  State<StoreSetupDialog> createState() => _StoreSetupDialogState();
}

class _StoreSetupDialogState extends State<StoreSetupDialog> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _apiCtrl = TextEditingController();
  final TextEditingController _tokenCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _tokenFromFactory = false;
  String _error = '';
  String _hint = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _apiCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final factory = await StoreConfigService.loadFactoryConfig();
    final user = await StoreConfigService.loadUserConfig();
    final effective = await StoreConfigService.loadEffectiveConfig();
    final hasFactory = await StoreConfigService.hasFactoryConfig();

    _nameCtrl.text = (user[StoreConfigService.kKeyStoreName] ??
            effective[StoreConfigService.kKeyStoreName] ??
            '')
        .toString();
    _apiCtrl.text = (effective[StoreConfigService.kKeyApiServer] ?? '').toString();
    _tokenCtrl.text = (effective[StoreConfigService.kKeyAdminToken] ?? '').toString();
    _tokenFromFactory =
        (factory[StoreConfigService.kKeyAdminToken] ?? '').toString().trim().isNotEmpty;

    if (!hasFactory) {
      _hint = '未检测到出厂配置（store_config.json），可能是安装包未完整分发。'
          '请联系管理员补齐，或直接在下方填写。';
    } else if (_tokenFromFactory) {
      _hint = '已读取出厂配置，可直接填写门店名称。';
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写门店名称');
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });

    // 用户配置：门店名必存；API 地址与令牌只在用户主动改动时写入，
    // 避免把出厂配置里的令牌覆盖成空。
    final user = await StoreConfigService.loadUserConfig();
    user[StoreConfigService.kKeyStoreName] = name;
    user[StoreConfigService.kKeyConfigured] = true;

    final api = _apiCtrl.text.trim();
    if (api.isNotEmpty) {
      user[StoreConfigService.kKeyApiServer] = api;
    }
    final token = _tokenCtrl.text.trim();
    if (token.isNotEmpty) {
      user[StoreConfigService.kKeyAdminToken] = token;
    }

    final err = await StoreConfigService.saveUserConfig(user);
    if (err != null) {
      // 写盘失败：留在弹窗里给出明确提示，不静默失败
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$err\n请检查目录写权限，或联系管理员处理。';
        });
      }
      return;
    }

    // 尝试同步到服务器（失败不阻塞配置保存，只提示）
    var syncMsg = '';
    try {
      final r = await StoreSyncService.syncStoreName(name);
      if (r['success'] != true) {
        syncMsg = '（已保存到本机，但未能同步到服务器：${r['error'] ?? '未知原因'}）';
      }
    } catch (e) {
      syncMsg = '（已保存到本机，但同步失败：$e）';
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
    // 同步结果用 SnackBar 轻提示，不打断主流程
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(syncMsg.isEmpty ? '门店配置已保存' : '门店配置已保存$syncMsg'),
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('门店信息配置'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 460, maxWidth: 520),
        child: _loading
            ? const SizedBox(
                width: 460,
                height: 160,
                child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '请填写本门店名称。保存后将自动同步到公司服务器的'
                      '「设备管理」与「共享通讯簿」，远程技术员即可看到店名。',
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    _label('门店名称'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _nameCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: '例如：仁和堂沂蒙路店',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _label('API 服务器'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _apiCtrl,
                      decoration: const InputDecoration(
                        hintText: 'http://192.168.100.190:21114',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _label('管理员令牌'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _tokenCtrl,
                      obscureText: true,
                      readOnly: _tokenFromFactory,
                      decoration: InputDecoration(
                        hintText: _tokenFromFactory
                            ? '已由出厂配置提供'
                            : '用于写入服务器别名，留空则不同步',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        helperText: _tokenFromFactory
                            ? '令牌来自出厂配置，如需更换请联系管理员。'
                            : null,
                      ),
                    ),
                    if (_hint.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(_hint,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ],
                    if (_error.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(_error,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.red)),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('稍后再说'),
        ),
        ElevatedButton(
          onPressed: _saving || _loading ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('保存并同步'),
        ),
      ],
    );
  }

  Widget _label(String text) => Text(
        text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      );
}
