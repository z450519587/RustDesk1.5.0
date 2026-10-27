import 'package:flutter/material.dart';
import 'package:flutter_hbb/store_config_service.dart';
import 'package:flutter_hbb/store_sync_service.dart';

/// 首次启动配置窗口
///
/// 触发时机：用户尚未配置过门店名（首次运行 / 用户配置丢失）时弹出。
///
/// 弹窗内**只有一个字段**：门店名称。
/// - API 服务器与管理员令牌来自随安装包分发的出厂配置
///   （`store_config.json`），不在此处暴露，避免门店误改导致同步失效。
/// - 门店名称为**必填**：为空时「保存」按钮禁用，提交时也再做一次非空校验。
/// - **不允许延后填写**：没有「稍后再说」按钮，弹窗也不可点击遮罩关闭
///   （`barrierDismissible: false`），必须填写后才能继续。
///
/// 保存失败（例如所有目录都无写权限）时**不关闭弹窗**，直接给出明确提示，
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

  bool _loading = true;
  bool _saving = false;
  String _error = '';
  String _hint = '';

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(_onTextChanged);
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_onTextChanged);
    _nameCtrl.dispose();
    super.dispose();
  }

  /// 输入内容变化时刷新「保存」按钮的可用状态（空值不允许提交）。
  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  /// 门店名称是否已填写（去掉首尾空白后非空）。
  bool get _nameValid => _nameCtrl.text.trim().isNotEmpty;

  Future<void> _load() async {
    final effective = await StoreConfigService.loadEffectiveConfig();
    final hasFactory = await StoreConfigService.hasFactoryConfig();
    final hasToken = await StoreConfigService.hasAdminToken();

    _nameCtrl.text = (effective[StoreConfigService.kKeyStoreName] ?? '')
        .toString()
        .trim();

    if (!hasFactory) {
      _hint = '未检测到出厂配置（store_config.json），可能是安装包未完整分发。'
          '门店名称仍可保存到本机，但无法同步到公司服务器，请联系管理员补齐。';
    } else if (!hasToken) {
      _hint = '已读取出厂配置，但其中不含管理员令牌，门店名称将仅保存在本机。';
    } else {
      _hint = '保存后将自动同步到公司服务器的「设备管理」与「共享通讯簿」，'
          '远程技术员即可看到店名。';
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    // 提交时的非空校验（按钮禁用只是第一道防线，这里是第二道）
    if (name.isEmpty) {
      setState(() => _error = '请填写门店名称');
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });

    // 只保存门店名。API 地址与令牌始终来自出厂配置，不写入用户配置，
    // 避免门店误改导致同步失效。saveStoreName 内部会清除旧版本残留的
    // API/令牌字段，统一以出厂配置为准。
    final err = await StoreConfigService.saveStoreName(name);
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
                      '请填写本门店名称（必填）。',
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    _label('门店名称'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _nameCtrl,
                      autofocus: true,
                      onSubmitted: (_) {
                        if (_nameValid) _save();
                      },
                      decoration: const InputDecoration(
                        hintText: '例如：仁和堂沂蒙路店',
                        border: OutlineInputBorder(),
                        isDense: true,
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
        // 只保留「保存并同步」：门店名必填，不允许延后填写。
        ElevatedButton(
          onPressed: (_saving || _loading || !_nameValid) ? null : _save,
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
