# Tern Guitar Score (`gscore`)

Tern 终端/工作区插件：基于 alphaTab + SoundFont + Luau 节点树的交互式吉他谱/六线谱播放与练习工具。

## 特性

- **多格式支持**：`.gp`, `.gp3`, `.gp4`, `.gp5`, `.gpx`, `.musicxml`, `.xml`, `.mxl`。
- **真实音色合成**：alphaTab 内置 Sonivox SoundFont 离线渲染采样音频，带软限幅防削波。
- **交互式游标**：按小节与拍位精准高亮跟随，自适应面板宽度无偏移。
- **循环与选段**：支持整曲播放、单小节循环、Shift 连选多小节循环。
- **系统文件选择器**：工具栏直接调起操作系统文件对话框。
- **Agent 交互通道**：通过 `open-request.json` 支持 Agent 自动排版并排练习曲面板、导出 `selection.json` 结构化选段给 Agent 改写。

## 目录结构

- `plugin.toml`：插件清单
- `host.luau`：宿主逻辑（谱面渲染、状态管理、播放控制、热区布局）
- `window.luau`：窗口管理（分屏排版、Agent 通道轮询）
- `hits.css`：坐标与浮层样式
- `renderer/index.mjs`：基于 alphaTab 的排版与 SoundFont 音频生成器
- `player.py`：低延迟音频播放引擎
- `slice.py`：WAV 选段与无缝切片器
- `pickfile.py`：系统原生文件选择对话框
