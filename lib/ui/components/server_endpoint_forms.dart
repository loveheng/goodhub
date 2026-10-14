/// MCP 服务端点表单组件(P1 设置拆分自 chat_page 迁移,服务大厅节点卡复用)。
///
/// - [ServerEndpointEditForm]:内联编辑(endpoint + 令牌;令牌留空 = 不改);
/// - [ServerEndpointAddForm]:新增(id/name/endpoint/token;id 校验不含 `__`)。
/// 表单自持 controller(避免父级重建丢输入);字体/色一律走 console tokens。
library;

import 'package:flutter/material.dart';

import '../tokens/console_tokens.dart';
import '../../mcp/server_endpoints.dart';

/// 端点内联编辑表单(持有 controller,避免 StatefulBuilder 重建丢输入)。
class ServerEndpointEditForm extends StatefulWidget {
  const ServerEndpointEditForm({
    super.key,
    required this.ep,
    required this.storedKey,
    required this.onSave,
    required this.onCancel,
  });

  final ServerEndpoint ep;
  final String? storedKey;
  final void Function(ServerEndpoint updated, String token) onSave;
  final VoidCallback onCancel;

  @override
  State<ServerEndpointEditForm> createState() => _ServerEndpointEditFormState();
}

class _ServerEndpointEditFormState extends State<ServerEndpointEditForm> {
  late final _epCtrl = TextEditingController(text: widget.ep.endpoint);
  late final _keyCtrl = TextEditingController(text: widget.storedKey ?? '');

  @override
  void dispose() {
    _epCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final mono = TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.body);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 4, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _epCtrl,
            decoration: const InputDecoration(
              labelText: 'MCP Endpoint（须含 /mcp）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: mono,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _keyCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'X-Api-Key（可留空）',
              border: const OutlineInputBorder(),
              isDense: true,
              hintText: widget.storedKey?.isNotEmpty == true
                  ? '已存令牌（留空不改）'
                  : null,
            ),
            style: mono,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: widget.onCancel, child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => widget.onSave(
                  widget.ep.copyWith(endpoint: _epCtrl.text.trim()),
                  _keyCtrl.text.trim(),
                ),
                child: const Text('保存'),
              ),
            ],
          ),
          if (widget.storedKey?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '该服务已存令牌（安全存储）。留空密钥框 = 不改；填新值 = 覆盖。',
                style: TextStyle(fontSize: Fsz.micro, color: t.terminalMuted),
              ),
            ),
        ],
      ),
    );
  }
}

/// 新增端点表单(id/name/endpoint/token;id 校验不含 `__`)。
class ServerEndpointAddForm extends StatefulWidget {
  const ServerEndpointAddForm({
    super.key,
    required this.onAdd,
    required this.onCancel,
  });

  final void Function(String id, String name, String endpoint, String token)
  onAdd;
  final VoidCallback onCancel;

  @override
  State<ServerEndpointAddForm> createState() => _ServerEndpointAddFormState();
}

class _ServerEndpointAddFormState extends State<ServerEndpointAddForm> {
  final _idCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _epCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  var _err = '';

  @override
  void dispose() {
    _idCtrl.dispose();
    _nameCtrl.dispose();
    _epCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final id = _idCtrl.text.trim();
    if (id.isEmpty) {
      setState(() => _err = '服务标识不能为空');
      return;
    }
    if (id.contains('__')) {
      setState(() => _err = '服务标识不能含 "__"（工具名前缀分隔符）');
      return;
    }
    widget.onAdd(
      id,
      _nameCtrl.text.trim(),
      _epCtrl.text.trim(),
      _keyCtrl.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final mono = TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.body);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _idCtrl,
            decoration: const InputDecoration(
              labelText: '服务标识（如 shuguang，不含 __）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: mono,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '展示名（可空，默认同标识）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _epCtrl,
            decoration: const InputDecoration(
              labelText: 'MCP Endpoint（须含 /mcp）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: mono,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _keyCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'X-Api-Key（可留空）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: mono,
          ),
          if (_err.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _err,
                style: TextStyle(fontSize: Fsz.telemetry, color: t.dangerDeep),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: widget.onCancel, child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _submit, child: const Text('添加')),
            ],
          ),
        ],
      ),
    );
  }
}
