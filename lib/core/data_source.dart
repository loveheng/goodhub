/// 首个数据面生态成员常量（P2 字面量单源，ai-capability-export 通用化
/// 2026-11-09）。
///
/// **语义**：goodshare 是宿主的**首个**数据面/任务来源生态成员——这些常量
/// 只承载「首个成员是谁」这一装配事实（历史演进产物：默认参数/对账分组键/
/// 测试设施的既有值），**不是框架对 goodshare 的功能依赖**。框架逻辑
/// （消费循环/受理链/档案）全部来源无关；新来源接入即注册即用。
///
/// **纪律**：`lib/` 内 'goodshare' 字面量禁复活（除本文件单点）——
/// drift-registry 词条防漂移；新代码需要「默认数据面」语义时引用本常量，
/// 并评估该语义是否应改为显式注入（装配决策不进框架层）。
library;

/// 首个数据面生态成员的 serverId（对账账本分组键的既有值；框架类默认参数
/// 引用本常量——字面量单点，改名/换成员只动此处）。
const String kPrimaryDataSourceServerId = 'goodshare';

/// 首个数据面生态成员的包名（K17 身份键同源族：Binder callerKey / 唤醒
/// Intent；同 ai-app-split.md §3.12.3 跨仓常量族）。
const String kPrimaryDataSourcePackage = 'com.zzh.goodshare'; // drift:keep（单源定义点）
