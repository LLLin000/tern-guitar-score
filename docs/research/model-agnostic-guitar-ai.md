# 多模型吉他 AI 接入可行性调研

## 结论

**可行，但不是把知识“写进”任意模型。** 可移植的做法是给 Agent 提供短上下文、可调用的领域工具，以及需要时接入专用音频/图像引擎。模型仍须支持其宿主提供的上下文和工具调用；封闭、不支持工具的模型不能被插件强行扩展。

对这个项目，最短路径是先接入 Tern Carly 的窗口插件导出；只有在需要让 Tern 以外的多个 Agent/模型也调用同一能力时，再把同一领域工具服务封装为 MCP 或逐家适配工具调用 API。

> **Current status:** This is a historical feasibility report. Its Carly-first/MCP-later recommendation was not adopted. The implementation now uses OMP custom tools, the local file protocol, and a Tern-native `gscore.lesson.v2` slice; see the P4-B section of the README for live acceptance and remaining limits.

## 当前插件实际具备什么

- `host.luau` 导出 `music_context_v1` 选段快照：小节、时间范围、速度、拍号、调弦、音符/节奏事件及技巧标记；这属于**符号谱面上下文**，不是录音音频。
- `window.luau` 消费带 request ID 的草稿请求；`tools/generate_draft.py` 目前只生成 alternate picking、arpeggio、slow drill 三种确定性模板。
- `plugin.toml` 的 score block 只列出乐谱扩展名；检查过的 Lua/Python/renderer/audio-backend 路径没有 `tern.carly.export`、`tern.carly.context` 注册或模型 provider API 调用。现有文件通道不会自动把选段塞进任意模型的提示词。
- 因此，现有实现能为模型提供结构化输入的基础，但五项 AI 教学/转录能力都不是现成的 LLM 集成。

## 模型无关接入边界

### Tern 内：Carly 插件导出

Tern 官方 SDK 允许**本地桌面窗口插件**用 `tern.carly.export(name, {sig, doc}, fn)` 注册 Carly 可调用的函数，并用 `tern.carly.context(fn)` 给每次请求附加短上下文；这些是 Luau 函数导出，不是原生 JSON-Schema 工具。Carly 默认发现已加载本地窗口插件的导出。见 [Extending Carly](https://docs.stencil.so/tern/guides/carly.html) 和 [Window API](https://docs.stencil.so/tern/reference/api-window.html#carly-exports-and-request-context)。

约束：每插件最多 16 个导出；上下文每插件最多 400 字符、总计 1600 字符，provider 预算 4 ms；函数 handler 预算 50 ms，慢任务要异步执行。Carly 集成仅在桌面窗口插件可用；host-only、远程插件、Web 和 iOS 不能提供此接口。见上述 Tern 文档。

**含义：**上下文钩子只放“当前有选段、曲名/小节范围/调弦”等短摘要。完整 note list、曲谱、教学资料应由按需调用的只读工具返回，不能塞进 prompt。Tern 文档没有承诺所有 Carly 模型/provider 都有相同能力，故“模型无关”应限定为“同一工具面向 Carly 当前支持的模型”，不能写成“所有模型都支持”。

### Tern 外：MCP 或各家工具调用适配

MCP 规定客户端可发现工具并调用 `tools/list` / `tools/call`；模型通过宿主应用选择工具，服务器负责执行。见 [MCP Tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)。OpenAI 文档提供 function calling 和远程 MCP；Anthropic 提供自定义 client tools；Gemini API 提供 function calling。见 [OpenAI tools](https://developers.openai.com/api/docs/guides/tools)、[OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling)、[Claude tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview)、[Gemini function calling](https://ai.google.dev/gemini-api/docs/function-calling)。

这三类 API 的逻辑相似，但字段/调用循环并非完全相同。可以共用领域层的参数/返回 JSON Schema，再由 MCP 客户端或 provider adapter 转换；MCP 也不是每个模型应用都支持。结构化输出能约束格式，不能证明和弦、音高或可演奏性正确；仍需本地校验。参见 [OpenAI Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs) 和 [Gemini structured output](https://ai.google.dev/gemini-api/docs/structured-output)。

## 五项能力的可行性
> 可行性是工程判断，不是模型准确率基准；真实表现需要用目标曲风、录音和调弦样本验收。

| 能力 | 可行性 | 当前状态 | 可行实现与主要限制 |
|---|---|---|---|
| 写谱 / 生成短练习谱与局部变奏 | **高；完整长篇作品需另行评测** | 只有三种规则模板，无 LLM 写作 | 给模型选段符号数据，要求输出受限的 ScorePlan（音符、时值、弦品、技巧），由本地序列化为 MusicXML，再检查小节容量、音高=调弦+品位、弦品范围和可演奏性。MusicXML 4.0 有明确的 guitar string/fret/tuning 表达，也支持和弦符号与指板图；见 [tablature](https://www.w3.org/2021/06/musicxml40/tutorial/tablature/) 与 [chord symbols/diagrams](https://www.w3.org/2021/06/musicxml40/tutorial/chord-symbols-and-diagrams/)。现有生成器不能直接接受任意模型作品，需加结构化 ScorePlan→MusicXML 的生成/校验步骤。 |
| 扒和弦 | **符号谱：高；录音：中低** | 可导出音符/时间，但没有和弦分析器 | 对 MusicXML/GP 选段，可按同时发声音高和节拍生成和弦候选；转位、缺音、调性拼写可能多解，应返回候选而非假装唯一。录音可用专用和声特征流程；[Essentia ChordsDetection](https://essentia.upf.edu/reference/std_ChordsDetection.html) 从 HPCP 估计每帧和弦，但目前文档描述的是 major/minor triad，且标为 experimental。它不是完整吉他和弦扒谱保证；需要节拍分段、置信度和人工修正。Basic Pitch 输出音符/MIDI，不等同于和弦标签。 |
| 和弦教学 | **高（以符号为输入）** | 无模型教学工具 | 输入和弦符号或选段后，由确定性指板/和弦指法计算器先生成可验证的 voicing、弦品、指法/横按候选；模型解释构成音、转位、替代和练习步骤。MusicXML 可表示 chord symbol 和 guitar chord diagram，便于直接生成可打开的教学谱例。 |
| 吉他乐理教学 | **高（需知识校验）** | 无模型教学工具 | 模型可按用户水平解释音程、调式、和弦功能、节奏，并结合当前选段生成练习题。不要把整本教材塞入上下文钩子；用经授权的参考资料检索，加上本地音程/调式计算工具，为答案给出处或关联小节。 |

## 推荐的最小方案

1. **先做 Tern Carly 原生接口，不做多供应商 API 客户端。** 在 `window.luau` 加一个短 `tern.carly.context`，提示当前是否有选段；注册 2–3 个窄工具：`get_selection`（只读、可分页）、`analyze_harmony`（符号谱和弦候选）、`propose_draft`（接收受限 ScorePlan，校验后创建草稿请求）。当前插件已是本地窗口插件，符合 Tern 的接入位置；当前没有这些注册。
2. **写入必须走草稿，不接受模型任意路径/命令。** 输出先经过 MusicXML/音乐语义校验、生成独立 draft 并让用户预览/接受；不要把 `tern.process` 或任意文件读写直接暴露给模型。Tern 文档明确插件是本地受信代码，Carly 没有独立的逐轮访问审批层；见 [Carly plugin trust/capabilities](https://docs.stencil.so/tern/guides/carly.html)。
3. **音频能力以后做成显式本地引擎命令。** 先限定“单吉他录音→MIDI 候选”，再考虑和弦识别；展示置信度并允许用户修正。印刷谱 OMR 放在后续，先验证吉他谱/TAB样本。需要云端多模态时，单独提示用户上传/发送音频或图片。
4. **只有确实要被多个非 Tern 客户端调用时，再抽 MCP 服务。** Carly exports 和 MCP 不要第一天并建；二者最终可复用同一领域函数/Schema。

## 主要风险

- 有效 JSON/XML 不等于正确音乐；约束输出只解决格式，不能取代拍号容量、调弦/弦品一致性、听音和可演奏性检查。
- 音频转录、和弦识别和印刷谱 OMR 都要用真实吉他/噪声/特殊调弦样本评估，结果应标记不确定度。
- 云模型收到原始录音/乐谱涉及隐私、版权和成本；默认本地转录，只发送必要的符号片段。
- Tern 工具应最小权限：模型读取当前选择、生成草稿，不给任意 shell、任意文件路径或自动覆盖原谱的能力。

## 一手来源

- [Tern: Extending Carly](https://docs.stencil.so/tern/guides/carly.html)；[Window API](https://docs.stencil.so/tern/reference/api-window.html#carly-exports-and-request-context)
- [Model Context Protocol: Tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)
- [OpenAI: Using tools](https://developers.openai.com/api/docs/guides/tools)；[Function calling](https://developers.openai.com/api/docs/guides/function-calling)；[Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)
- [Anthropic: Tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview)
- [Google: Gemini function calling](https://ai.google.dev/gemini-api/docs/function-calling)；[Structured output](https://ai.google.dev/gemini-api/docs/structured-output)；[Audio understanding](https://ai.google.dev/gemini-api/docs/audio)
- [Spotify Basic Pitch](https://github.com/spotify/basic-pitch)
- [Essentia ChordsDetection](https://essentia.upf.edu/reference/std_ChordsDetection.html)；[chord-estimation tutorial](https://essentia.upf.edu/tutorial_tonal_chords.html)
- [Audiveris Handbook](https://audiveris.github.io/audiveris/_pages/handbook/)
- [MusicXML 4.0 report](https://www.w3.org/2021/06/musicxml40/)；[tablature](https://www.w3.org/2021/06/musicxml40/tutorial/tablature/)；[chord symbols and diagrams](https://www.w3.org/2021/06/musicxml40/tutorial/chord-symbols-and-diagrams/)
