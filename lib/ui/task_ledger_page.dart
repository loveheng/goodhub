/// 任务对账页（M4-2 对账能力，2026-10-18 从设置页段迁出）。
///
/// 入口 = 会话侧边栏底部横排工具带（高频可达：用户在 goodshare 点完 AI 任务
/// 后，拉侧边栏即可确认「被处理了没有」）。内容复用 [TaskLedgerSection]（与
/// 设置页段同一 widget，账本经注入位传入——视图不持领域单例）。
library;

import 'package:flutter/material.dart';

import '../app/task_consume_bootstrap.dart';
import 'sections/task_ledger_section.dart';

class TaskLedgerPage extends StatelessWidget {
  const TaskLedgerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('任务对账')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TaskLedgerSection(ledger: taskConsumeBootstrap.ledger),
        ],
      ),
    );
  }
}
