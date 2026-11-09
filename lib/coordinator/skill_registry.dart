/// 三级 Skill 系统（M2.5-T5）：注册表 + 分层加载 + system prompt 组装。
/// 规格 SSOT：architecture.md §3（三级 Skill）+ §7（JIT 二级元工具）+
/// M2.5 施工设计 §1.1。
///
/// - **分层**：Global 常驻（<300 Tokens 预算，注册时硬校验）/ App-Scoped（绑
///   Server，连接时注入）/ On-Demand（`activate_skill` 元工具按需激活，
///   会话粒度激活集——§15 会话持有语义）；
/// - **来源收敛**（三轮评审）：builtin 官方预置 + cow（goodshare CoW 同步，
///   T6 落）+ user（UI 手动编辑，M3 落）——`create_skill` 特权工具已剥离；
/// - **注入位**：system prompt 组装（AgentLoop 前导 System 消息由调用方拼，
///   本类给纯函数组装器；滑动窗口裁剪保留前导 System——context_governor T6）；
/// - **Token 口径**：复用 estimateTokens 字符级粗估（CJK 上界，T6 拍板）。
library;

import '../llm/cloud/cloud_llm.dart';
import 'context_governor.dart' show estimateTokens;

/// Global Skill 常驻预算（architecture §3：<300 Tokens，字符级粗估）。
const kGlobalSkillBudgetTokens = 300;

enum SkillScope { global, appScoped, onDemand }

enum SkillSource { builtin, cow, user }

class Skill {
  const Skill({
    required this.name,
    required this.scope,
    required this.description,
    required this.content,
    required this.source,
    this.serverId,
  }) : assert(scope == SkillScope.appScoped || serverId == null,
            '仅 appScoped 可绑 serverId');

  final String name;

  /// 注册表/激活清单展示用一句话（≠ 正文）。
  final SkillScope scope;
  final String description;
  final String content;
  final SkillSource source;
  final String? serverId;
}

class SkillRegistry {
  final Map<String, Skill> _skills = {};

  /// On-Demand 已激活集（会话粒度——registry 实例随会话建，实例废弃即焚）。
  final Set<String> activated = {};

  /// 注册。Global 超 300 Tokens 拒绝（fail-fast——常驻预算是硬约束，禁静默
  /// 裁剪；来源三分支 builtin/cow/user 都过此闸）；name 重复拒绝（覆盖语义
  /// 留给 T6 CoW 显式覆写通道，不做隐式覆盖）。
  void register(Skill skill) {
    if (_skills.containsKey(skill.name)) {
      throw ArgumentError('Skill 重名: ${skill.name}');
    }
    if (skill.scope == SkillScope.global &&
        estimateTokens(skill.content) > kGlobalSkillBudgetTokens) {
      throw ArgumentError(
          'Global Skill「${skill.name}」超预算（${estimateTokens(skill.content)} > $kGlobalSkillBudgetTokens tokens）');
    }
    _skills[skill.name] = skill;
  }

  void registerAll(Iterable<Skill> skills) {
    for (final s in skills) {
      register(s);
    }
  }

  Skill? byName(String name) => _skills[name];
  List<Skill> globals() =>
      _skills.values.where((s) => s.scope == SkillScope.global).toList();
  List<Skill> forServer(String serverId) => _skills.values
      .where((s) => s.scope == SkillScope.appScoped && s.serverId == serverId)
      .toList();

  /// 全部 appScoped Skill（跨 server 全集；与 globals()/onDemand() 同口径的
  /// 投影——记忆看板「MCP 服务 Prompt」总览列举用，注入过滤仍走
  /// composeSystemPrompt 的 publicServerIds/activePrivateSlotId 投影）。
  List<Skill> appScoped() =>
      _skills.values.where((s) => s.scope == SkillScope.appScoped).toList();
  List<Skill> onDemand() =>
      _skills.values.where((s) => s.scope == SkillScope.onDemand).toList();

  /// 激活 On-Demand Skill；未知 → false（执行器按 isError 回填，C-2 同轨）。
  /// 幂等：已激活再激活返回 true。
  bool activate(String name) {
    final s = _skills[name];
    if (s == null || s.scope != SkillScope.onDemand) return false;
    activated.add(name);
    return true;
  }

  /// activate_skill 元工具声明（§7：L1 静默 + 药丸——readOnlyHint true 走
  /// 网关建议值；宿主本地工具，不下发 server）。随 tools 列表一并下发。
  ///
  /// 工具名常量 [activateSkillToolName] 同步暴露：hybrid_assembly 的端侧
  /// 工具面判据（deviceToolPolicy）须引用同一出处（防字符串双源漂移）。
  static const String activateSkillToolName = 'activate_skill';

  CloudToolSchema activationToolSchema() => CloudToolSchema(
        name: activateSkillToolName,
        description: '按需激活一个宿主 Skill（技能指引）。激活后本会话后续轮次生效；'
            '可激活项见系统提示中的「可激活」清单。',
        parametersSchema: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': 'Skill 名（可激活清单内）'},
          },
          'required': ['name'],
        },
        annotations: {'readOnlyHint': true},
      );

  /// system prompt 组装（纯函数，prompt-mgmt Phase 1）：base 原样保留在前
  /// （前导 System 被滑动窗口裁剪保护），后接 Global 常驻 → 公共 server
  /// appScoped → 激活私有槽位 appScoped（易变度宏序，护前缀缓存）→ 已激活
  /// On-Demand，尾部列「可激活」清单。确定性铁律：段内按
  /// `'${s.serverId ?? 'global'}:${s.name}'` 字典序排序（null 归一化，
  /// 注册序/Set 迭代序不外泄）；无激活私有槽位时私有块严格空串；段间统一
  /// `\n\n` Join，空列表恒返回 base 原文，禁悬挂换行；禁嵌时间戳等动态量。
  String composeSystemPrompt(String base,
      {List<String> publicServerIds = const [],
      String? activePrivateSlotId,
      String? mountedSection}) {
    String sortKey(Skill s) => '${s.serverId ?? 'global'}:${s.name}';
    List<Skill> sorted(Iterable<Skill> skills) =>
        skills.toList()..sort((a, b) => sortKey(a).compareTo(sortKey(b)));
    final privateSlot = activePrivateSlotId == null
        ? const <Skill>[]
        : forServer(activePrivateSlotId);
    final publicSkills = [
      for (final serverId in publicServerIds) ...forServer(serverId),
    ];
    final sections = <String>[
      for (final s in sorted(globals())) '### Skill: ${s.name}\n${s.content}',
      // 易变度序（§3.1）：mountedSection/workspace 指令在公共 appScoped 之前。
      if (mountedSection != null && mountedSection.isNotEmpty) mountedSection,
      for (final s in sorted(publicSkills))
        '### Skill: ${s.name}（[${s.serverId}]）\n${s.content}',
      for (final s in sorted(privateSlot))
        '### Skill: ${s.name}（[${s.serverId}]）\n${s.content}',
      for (final name in activated.toList()..sort())
        if (_skills[name] != null)
          '### Skill: ${_skills[name]!.name}（已激活）\n${_skills[name]!.content}',
    ];
    final pending = [
      for (final s in onDemand())
        if (!activated.contains(s.name)) '- ${s.name}: ${s.description}',
    ];
    final b = StringBuffer(base);
    if (sections.isNotEmpty) {
      b.write('\n\n## 宿主 Skills\n');
      b.write(sections.join('\n\n'));
    }
    if (pending.isNotEmpty) {
      b.write('\n\n### 可激活（activate_skill）\n');
      b.write(pending.join('\n'));
    }
    return b.toString();
  }
}

/// 官方预置最小集（builtin）。内容是模型侧行为知识：$ref 传递纪律直接配合
/// T3/T4 注水机制；拾贝数据面配合 goodshare instructions（Tier 1）。

/// 供给面语义条目名（S17c 消费迁移；与 [builtinSkills] 的 `supply/` 条目
/// 单源——禁字符串双源漂移）。
const String kSupplySummarizeSkillName = 'supply/summarize';

/// 按名解析供给面语义（S17c：消费方经此取 instruction，禁再硬编码语义文本）。
///
/// **显式失败红线**：解析不到（条目缺失/被预算闸拒绝）抛 [StateError]——
/// 语义外注是唯一来源，静默回退硬编码文本 = 双源复活 + 内置调用分支残留
/// （S17c 红线），调用方（Summarizer 装配点）不得捕获吞掉。
String resolveSupplyInstruction(SkillRegistry registry, String name) {
  final s = registry.byName(name);
  if (s == null) {
    throw StateError('供给面语义条目缺失: $name（语义外注通道坏，显式失败）');
  }
  return s.content;
}

List<Skill> builtinSkills() => const [
      Skill(
        name: 'ref-pipeline',
        scope: SkillScope.global,
        description: '跨 App 大数据传递纪律：\$ref 句柄原样传递，禁复制全文。',
        source: SkillSource.builtin,
        content: '工具返回 \$ref:<server>:<id> 句柄时，把它原样传给下游工具的'
            '对应参数，宿主会在分发前注水成真实数据；禁止复制句柄指向的全文，'
            '禁止向用户展示句柄原文。',
      ),
      Skill(
        name: 'task-discipline',
        scope: SkillScope.global,
        description: '多步任务纪律：先列步骤、逐步简报、写操作等确认、失败如实呈现。',
        source: SkillSource.builtin,
        content: '多步任务先列步骤再执行；每完成一步向用户简报一句；写操作'
            '（创建/修改/删除/发送）必须等用户确认后执行；失败如实呈现，'
            '不粉饰、不静默重试。',
      ),
      // ai-capability-export 通用化（2026-11-09）：goodshare-data 内置 skill
      // 退役——数据面工具口径由来源侧 MCP 工具描述/prompts 自带（会话开场
      // 不再注入特定来源的介绍，防模型幻觉调用未挂载面）。
      Skill(
        name: 'deep-organize',
        scope: SkillScope.onDemand,
        description: '深度整理：逐条读取最近条目，输出归档建议清单（不执行写操作）。',
        source: SkillSource.builtin,
        // 通用化（2026-11-09）：内容不写死具体来源工具名（list_items/get_item
        // 是 goodshare 数据面的工具——写死即幻觉调用源），改为「当前挂载的
        // 数据面工具」通用表述，工具名以实挂 server 的 tools/list 为准。
        content: '使用当前挂载的数据面检索与读取工具，逐条读取用户最近的'
            '收集条目，输出归档建议清单：条目 id、建议（保留/归档/待办/删除）、'
            '一句理由。不执行写操作，仅输出建议。',
      ),
      // —— supply/ 语义命名空间（W3-S17 语义外注首条）——
      // 宿主供给面消费语义按 `supply/<语义名>` 落 builtin：语义住宿主 App
      // 代码（随 App 发版），**不进端侧资产**（D2=a 红线：端侧不内置任务
      // 模板中心；语义外注 = instruction 参数或本表，不新造注入通道）。
      // 内容与 OnDeviceResultSummarizer._system（context_governor.dart）同
      // 源文本——S17c 消费迁移时切换到按名解析并删除双源，迁移前此条是
      // 「语义外注通道可用性」的回归锚（真机分类指令长度实测随 S17c 场次）。
      Skill(
        name: 'supply/summarize',
        scope: SkillScope.global,
        description: '端侧供给面·工具结果摘要语义：要点压缩，保留数值/状态/结论/错误。',
        source: SkillSource.builtin,
        content: '你是工具结果摘要器。把给定工具结果压缩为要点，'
            '保留关键数值、状态、结论与错误信息，不添加解释、前言或代码块包裹。',
      ),
    ];
