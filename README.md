# TokenUsage

`TokenUsage` 是一个 macOS 14+ 原生 SwiftUI 应用，用来查看一个或多个 Codex Home 中的本地 token-usage report v1。它只读取本机数据，既能按日绘制 Token 与价格趋势，也能构建“会话 → 主对话 → 子代理线程 → 子代理轮次”的明细树；不会发起模型请求，也不会向原 Codex 对话上下文写入内容。

表格第一列是会话/对话时间，第二列是名称。会话名称来自本地 Codex 状态库中首次用户消息的前 36 个字符，允许重名；会自动剥离 `# Files mentioned by the user:`、附件路径、`Distinguish instructions...` 和 `## My request:` 等 Codex 附件信封，只保留实际请求。没有可用标题时回退为短会话 ID。展开会话后，可以看到主对话、明确关联的子代理、按唯一时间窗口推断的子代理，以及无法安全归属时单列的“侧边 / 无法唯一归属”组。存在图片生成时，名称旁会显示“图片 N”徽标；点击可查看用户输入提示词、模型修订提示词、请求/返回尺寸和质量，以及实际输出尺寸、格式与字节数。旧报告只有次数而没有详情时会显示“未记录详情”，其余字段留空。

所有 token、Credits 和 API USD 数值均右对齐并固定显示两位小数，便于逐行比较。Token 使用 `k`、`M`、`B` 缩写，悬停可查看精确整数。表格最后一行是“当前筛选汇总”，只累加当前日期和 Token 条件下可见的顶层会话；不会再次累加展开后的子对话。输出与推理继续分别显示，其中推理 token 是输出的子集。

## 环境要求

- macOS 14 或更高
- 完整 Xcode（Swift 6 工具链；本项目已用 Xcode 26.6 验证）
- 系统 SQLite
- 只有在使用“同步当前日期范围”回填历史报告时，才需要 `/usr/bin/python3`

## 构建与测试

直接用 Swift Package：

```sh
swift test --disable-sandbox
swift run TokenUsage
```

如果 `xcode-select` 仍指向 Command Line Tools，可以显式指定完整 Xcode：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-sandbox
```

生成可双击启动、已 ad-hoc 签名的 `.app`：

```sh
./Scripts/build-app.sh
open ".build/app/Token Usage.app"
```

应用图标的 1024px+ 主图和标准 macOS `.icns` 分别保存在 `Support/AppIconMaster.png` 与 `Support/AppIcon.icns`；构建脚本会自动将图标复制到 App bundle。

也可以在 Xcode 中直接打开 `Package.swift`。

## 数据来源与隐私

默认数据目录是 `~/.codex`。工具栏的 Codex Home 菜单可以启停任意目录、继续添加其他目录，或移除非默认目录；选择结果用 security-scoped bookmark 保存。跨目录遇到相同 `root_thread_id` 时，只采用生成时间最新的报告，避免复制或迁移目录后重复计数。

- 普通刷新只读 `token-usage/reports/*.json`，并只读 `state_*.sqlite` 的 `first_user_message` 来生成短标题。
- “同步当前日期范围”会运行随 App 打包的本地解析器，为日期范围内尚无报告的用户会话生成 per-session JSON/TXT。它不会调用 Codex 模型或 OpenAI API，也不会覆盖实时的 `latest.json/latest.txt`。
- 解析器只提取计量所需白名单字段。图片生成可额外记录用户输入提示词和模型 `revised_prompt` 的空白归一化预览（各最多 240 个字符及截断标记），以及尺寸、质量、格式、像素和字节数等标量；不会写入完整 prompt、普通工具参数/输出、图片内容或图片路径。
- App 不联网、不使用 MCP，也不把 `/status` 或任何提示注入会话，因此不会增加模型 token 或影响原任务上下文。

### App Server 标准报告

TokenUsage 会把 CoWork 的专用目录作为一个普通 Codex Home 自动加入候选，但读取层与其他来源完全相同，只扫描：

```text
<CODEX_HOME>/token-usage/reports/*.json
```

CoWork 继续使用 `ephemeral: true` 的 App Server 线程，不需要开启 Codex Hook。在线程销毁前，它会把实际 `request.prompt` 和模型 `revised_prompt` 写成各最多 240 个字符的预览，并记录请求/返回尺寸与质量、实际输出尺寸、格式和字节数；不会落盘完整 prompt、回复、图片内容、图片路径、普通工具参数、认证信息或工作目录。它用 `thread/tokenUsage/updated` 中的累计 `total` 计算增量，并直接原子写出权限为 `0600` 的 report v1。后台只接收 `CODEX_HOME`，不需要识别 CoWork 或专用导入格式；其他 App Server 客户端只要生成相同 report，也能直接复用。

- 只统计升级后的 CoWork 运行。旧 SwiftData 记录只保存最后一次响应的 `last`，缺少累计量、缓存写和实际 Codex 配置，无法无损回填，因而不会伪装成完整历史。
- `image_generations` 是 report v1 的可选字段；旧报告或字段不完整的记录仍可正常读取，界面相应位置显示为空，不会报错。
- 第一版短期使用的 `token-usage/imports/cowork/v1` 会在新版 CoWork 下次启动时一次性转换为标准 report；单个旧文件只有在报告安全落盘后才会删除。
- 运行中、失败或中断的记录按“已观测下界”显示；累计计数回退、字段关系错误或无法对账时拒绝导入或抑制价格。
- 这里统计的是驱动 CoWork 工作流的 Codex 控制回合。报告虽可显示图片尺寸/质量元数据，但图片生成模型自身的 token、图片尺寸/质量价格和其他工具按次费用不包含在内。
- CoWork 能取得后端 credits 估计时，会话 Credits 优先显示该值；趋势中的分钟价格与 API USD 仍是 TokenUsage 静态公开价目下的等价估算，并非实际订阅或 API 账单。
- 当前非沙箱构建可自动读取 CoWork Codex Home；如果以后启用 App Sandbox，需要在“Codex Home”菜单中显式授权该目录，或为两个 App 配置共享容器。

App Server 的事件边界可参考 [Codex App Server 文档](https://learn.chatgpt.com/docs/app-server)。

只接受 report schema v1。无效、超大、符号链接、文件名/root ID 不一致或未知版本的报告会被隔离成读取警告，其余有效报告仍可显示。

Codex 官方说明 Hook transcript 的格式不是稳定公共接口，因此将来 Codex 升级后若内部字段变化，解析结果可能降级为下界或需要同步更新读取器；参考 [Codex Hooks 文档](https://learn.chatgpt.com/docs/hooks)。

## 趋势与筛选

- 默认范围包含今天在内的最近 30 个自然日。
- 快捷按钮：今天、最近一周（7 天）、最近一月（30 天）。
- 开始和结束支持到分钟；结束分钟完整包含在范围内，顺序填反也能正常处理。
- Token 最小值/最大值都包含边界，作用于“会话含子级总量”。支持精确整数和 `100k`、`1.5M`、`2B` 这类简写。
- 趋势页可以分别筛选模型、推理强度和速度档位（Standard、Fast、未知）。同一维度内多选为“或”，不同维度之间为“且”。
- 曲线可以合并为“全部配置”一条线，也可以按“模型 + 推理强度 + 速度”拆成多条线。
- Token 图把总量、非缓存输入、缓存读、缓存写、输出和推理六项同时画在一张图中；顶部彩色指标可逐项点击显示或隐藏，纵轴上限随当前可见曲线的最大值更新。按配置拆线时，颜色表示指标、线型表示“模型 + 推理强度 + 速度”配置。价格图可切换 Credits 与 API USD 等价。每条配置曲线下方都有整个筛选范围的分类总量、价格、定价覆盖率及近似/下界状态。

分钟趋势使用报告中的 `task.usage_samples` 作为唯一计量平面：解析器把每次正 token 增量按 UTC 分钟和配置组合归档，App 再按本机日历汇成每日点。它不会把 `task`、thread 和 turn 三套重复视图相加，也不会把跨分钟或跨午夜的段按持续时间平均摊分。旧报告没有分钟样本时仍可显示，但会按 segment 的最后用量时间近似归档并明确警告；点击“同步当前日期范围”可用新解析器重建这些历史报告。

## 展开结构与计量规则

```text
会话（task 权威总计）
├─ 主对话 1（本轮自身用量）
│  ├─ 子对话 / 代理线程（线程自身小计）
│  │  ├─ 代理轮次 1（解释线程明细）
│  │  └─ 更深层子代理……
│  └─ 其他子对话……
├─ 主对话 2……
└─ 侧边 / 无法唯一归属的对话
```

- 会话行的“含子级总计”直接使用 `report.task.usage`，这是该会话的权威值。
- `thread.usage` 已扣除 fork 时继承的父上下文前缀，是该线程自身用量，不含后代线程。
- `turn.usage` 是线程自身用量的轮次拆分；代理线程父行和它的代理轮次子行是“小计 → 明细”，不能再次相加。
- `cached_input_tokens` 和 `cache_write_input_tokens` 是 input 子集，`reasoning_output_tokens` 是 output 子集；不能把所有列直接求和。
- 显式 `turn.agent_thread_ids` 是强归属。缺少显式关系时，只在子线程与父线程恰好一个轮次时间窗口重叠时标成“估算归属”；冲突、多重归属、循环或缺时间的线程只显示一次，并进入侧边组。
- 父行的“总 Token（含子级）”用于查看子树合计；“自身 Token”用于看该节点自己的消耗。

## 价格口径

价格来自随 App 打包的带日期静态价目快照：

- `Credits` 是 Codex credits 公开费率估算；配置档位无法确认时会明确退回 Standard 等价或部分价。
- `API USD 等价` 是相同 token 按默认公共 API token 价的等价估算，不是 ChatGPT/Codex 订阅的实际美元扣款，也不包含区域加价、工具调用、图片生成等额外费用。
- 配置档位来自本地会话记录，不等于服务端确认的实际执行档位；服务端可能降级，因此所有金额均以 `≈` 标记。
- 缓存读/写、reasoning 的包含关系不会二次计价；缺公开价的模型只显示已定价部分或 `—`。
- 图片输入 token 已折入 input，但 report v1 无法从总 input 中单独拆出；图片生成详情中的尺寸/质量仅供查看，Web/File Search、图片生成、容器、存储和外部 MCP 的按次费用仍无法完整还原。

## 测试

`Tests/TokenUsageCoreTests` 使用完全合成的数据，覆盖：

- schema v1 解码、未知版本和畸形/溢出数据拒绝；
- 最近 30/7/1 天日期范围；
- `100k` / `1.5M` 和包含边界的 Token 过滤；
- direct、time-inferred、side/unattributed 归属和循环/重复保护；
- 会话、轮次、线程、子代理的汇总不重复计数；
- 历史回填不改写 `latest`；
- 分钟结束边界、跨本地午夜的每日分桶和缺失日期补零；
- 合并/按配置曲线、模型/推理强度/速度过滤；
- 缓存与非缓存 Token 拆分、Credits/API 价格和部分定价覆盖率；
- Fork 分支分钟样本去除继承前缀，以及迁移 Codex Home 后不跟随旧绝对 transcript 路径。
- 标准 report 的可选显示名与缺失内嵌价格时的通用价目回退；CoWork 生产端另行覆盖累计增量、原子落盘和旧格式迁移。

测试源码不包含真实会话 ID、真实路径或真实对话正文。
