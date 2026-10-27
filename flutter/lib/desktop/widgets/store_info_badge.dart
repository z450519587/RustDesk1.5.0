import 'package:flutter/material.dart';
import 'package:flutter_hbb/store_config_service.dart';

/// 门店信息徽标
///
/// 显示在主界面右侧面板顶部、远程 ID 输入框右侧的空白区域。
/// 样式沿用该区域既有的卡片外观（圆角 + 同色描边），不遮挡任何原有内容。
///
/// 内容：
/// - 门店名称（大字）
/// - 本机 ID 与同步状态（小字，灰色）
class StoreInfoBadge extends StatefulWidget {
  const StoreInfoBadge({Key? key}) : super(key: key);

  @override
  State<StoreInfoBadge> createState() => _StoreInfoBadgeState();
}

class _StoreInfoBadgeState extends State<StoreInfoBadge> {
  String _storeName = '';
  String _status = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final name = await StoreConfigService.loadStoreName();
    final hasToken = await StoreConfigService.hasAdminToken();
    if (!mounted) return;
    setState(() {
      _storeName = name;
      _status = name.isEmpty
          ? (hasToken ? '尚未填写门店名称' : '未检测到出厂配置')
          : (hasToken ? '已同步至公司服务器' : '未检测到出厂配置，仅本地保存');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_storeName.isEmpty) {
      // 未配置时不占用空间，避免干扰主界面
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(left: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 260),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(13)),
        border: Border.all(color: Theme.of(context).colorScheme.background),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.store_outlined,
                  size: 16, color: Theme.of(context).textTheme.titleLarge?.color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  _storeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
