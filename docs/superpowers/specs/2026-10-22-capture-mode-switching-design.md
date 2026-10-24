# 覆盖层交互优化 —— 设计文档

日期：2026-10-22
状态：阶段一与阶段二均已实现（2026-10-22），实机多屏验收待完成
关联：ADR 0011（可移动模式选择器）、ADR 0047（macOS 全屏 Space 父面板）、
ADR 0110（快捷键设置与可见工具键）、ADR 0111（快捷键支持范围与确认）

## 1. 问题

用户提出三组体验问题，按性质分为两块：

**A. 模式选择需要长距离移动鼠标。**
按下捕获快捷键后，模式选择器固定在屏幕顶部居中
（`.kiri-mode-select` 的 `left: 50%; top: 44px`，`src/styles/design-system.css:673`）。
想切到录屏或 OCR，必须先把鼠标移到屏幕上方点一次，才能开始框选。

**B. 只能在一个显示器上工作，且缺少光标反馈。**

1. 一次捕获只冻结指针所在的那一个显示器。按下快捷键后把鼠标移到另一块屏幕无法框选，
   因为那块屏幕上既没有覆盖层也没有冻结图。
2. 选区建立后，把鼠标移到边缘或角上时始终是十字光标，用户无法判断可以缩放；
   选区内部拖动也没有移动光标。

## 2. 目标与非目标

目标：

1. 按下快捷键后，无需移动鼠标即可选择截图 / 录屏 / OCR。
2. 重复使用同一模式时，连模式选择这一步也可以省掉。
3. 每一块显示器都能直接开始框选，不必先把鼠标移过去再按快捷键。
4. 光标在空白处、选区内、八个缩放手柄、移动中分别给出正确反馈。

非目标：

- 不做"一次框选跨越两块屏幕"的矩形（跨屏矩形需要统一坐标空间与跨 WebView 手势连续性，
  另立技术预研；本次明确不支持）。
- 不改变"覆盖层初始提供三种模式"的产品契约（ADR 0011 仍然成立）。
- 不反转"先选模式、后框选"的流程。
- 不新增用户可见的设置开关（按 YAGNI 处理）。
- Wayland 仍只支持单显示器（既有限制，ADR 0051/0075 不变）。

## 3. 现状事实（已核对代码）

- `switchMode(next)` 已处理"已有选区切到录屏 → 进入录制选项"、"已有选区切到 OCR → 复用该裁剪一次"，
  键盘与滚轮只需调用它。
- 覆盖层键盘处理集中在 `onKeyDown`（`OverlayWindow.tsx:657` 起），已有守卫：
  IME 组合、`defaultPrevented`、焦点在 `input/textarea/select/contenteditable`、完成锁。
- 工具快捷键映射（`v/p/r/l/a/t/b/n/m/w`，第 723-742 行）在 `phase !== "mode-select"` 时生效，
  字母 `R/L/A/T/M` 已被占用，不能用作模式键。
- 右键语义已固定：标注阶段退回选区，其余阶段取消捕获（第 1032-1047 行，Spec §1.6）。
- 覆盖层当前没有任何滚轮处理。
- 根元素光标是静态三目表达式（第 1000-1005 行）：`selecting` 与 `record-options` 恒为 `crosshair`。
- `SelectionHandles`（第 1493-1528 行）的 8 个手柄是 `pointerEvents: "none"`，本身不带光标；
  命中由根节点的 `hitTestHandle(p, selection, 10)` 完成。
- 标注画布命中缩放手柄时设置的是 `crosshair`（`AnnotationCanvas.tsx:1295-1320`），同样缺少方向反馈。
- 显示器选择：macOS `active_screen()` 用 `NSEvent::mouseLocation()`（`capture/macos.rs:204`），
  Windows 用 `GetCursorPos`（`capture/windows.rs:135`），二者都只返回一个显示器。
- `CaptureSession` 只有单个 `display: CapturedDisplay`；`overlay_labels` 已是 `Vec` 但只 push 一个 label。
- `ProtocolStore` 只保存一张冻结图（`protocol.rs:20-29`、`set_frozen_png`、`clear_frozen_png_for_capture`）。
- 覆盖层从 URL 的 `captureToken` 取冻结图，并通过 `api.startCapture()` 拿上下文（`OverlayWindow.tsx:222-280`）。

## 4. 设计

### 4.1 键盘直选模式

- `1` = 截图，`2` = 录屏，`3` = OCR。
- 生效阶段：`mode-select`、`selecting`、`record-options`。
- 不生效：`annotating`、`ocr-result`、`qr-result`、`ocr-consent`、完成锁持有期间。
- 附加守卫：`meta/ctrl/alt` 任一按下时不响应；焦点在可编辑控件内不响应；IME 组合中不响应。
- 行为：调用 `switchMode(mode)` 并 `preventDefault()`。

### 4.2 滚轮原地循环模式

- 在 `mode-select`、`selecting`、`record-options` 阶段的空白画布上监听 `wheel`。
- 方向：`deltaY > 0` 向后循环（截图 → 录屏 → OCR → 截图），`deltaY < 0` 向前循环。
- 阈值：累计绝对值达到 60 像素触发一次；触发后清零并进入 350ms 冷却。
- 不生效：其它阶段、可编辑控件内、指针位于模式选择器 / 工具条 / 录制选项面板 / 提示条上
  （`event.target.closest(...)` 判定）。
- `preventDefault()`，避免滚动传给页面。

### 4.3 记住上次模式

- 新文件：`app_config_dir()/capture-mode.json`，内容 `{"mode":"screenshot"}`。
- 读取时机：通用入口（`start_capture` 命令、`--capture`、托盘截图项）在启动会话前读取，
  再用解析结果调用 `start_capture_with_mode`。
- 显式入口保持强制：`schedule_capture_mode`、`--record`、`--ocr` 绕过偏好。
- 写入时机（前端唯一写入方）：`switchMode` 成功后 300ms 防抖写入；
  覆盖层卸载时再写一次当前模式。
- 非法或缺失值回退 `screenshot`；写盘失败只记录 `log::warn`。

### 4.4 发现性

- 三个模式按钮内各加小号数字角标 `1/2/3`，不改变按钮尺寸与布局。
- 选区提示文案追加"按 1 / 2 / 3 切换模式"。
- 设置 → 快捷键页面不新增可录入项（这三键只在覆盖层内生效）。

### 4.5 光标反馈

统一由 `src/annotation/cursors.js` 提供纯函数，覆盖层与标注画布共用：

| 位置 | 光标 |
| --- | --- |
| 空白画布 | `crosshair` |
| 角手柄 `topLeft` / `bottomRight` | `nwse-resize` |
| 角手柄 `topRight` / `bottomLeft` | `nesw-resize` |
| 边手柄 `top` / `bottom` | `ns-resize` |
| 边手柄 `left` / `right` | `ew-resize` |
| 选区内部（非手柄） | `move` |
| 正在移动选区或标注对象 | `move` / `grabbing` |
| 正在缩放 | 保持对应方向光标，不回落到 `crosshair` |
| 录制选项面板、工具条、提示条、结果面板 | `default` |
| OCR / 二维码结果中的文本区 | 文本光标（原生） |
| 标注阶段线/箭头端点 | `crosshair`；其它手柄按方向光标 |

实现要点：

- 覆盖层在 `onPointerMove` 中计算 `hoverCursor`（已有指针处理与 `hitTestHandle`，不新增事件体系），
  仅在 `selecting` / `record-options` / `annotating` 阶段覆盖根元素光标。
- 手柄命中半径由 10 提高到 12，视觉尺寸不变；命中范围与光标提示保持一致。
- 标注画布改用同一个手柄→光标映射，替换现有的 `crosshair` 分支。
- 拖动过程中光标保持，不因指针离开手柄命中圈而抖动。

### 4.6 多显示器覆盖层（任选一屏框选）

原则：**每块显示器拥有独立的冻结帧与覆盖层，选区仍留在单块显示器的局部坐标内**，
不做跨屏矩形，也不引入全局坐标空间。

数据模型：

```
struct CaptureSession {
    displays: Vec<CapturedDisplay>,      // index 0 = 按下快捷键时指针所在屏
    overlays: Vec<OverlayBinding>,       // { label, display_index, token }
    ...
}
```

- `CapturedDisplay` 结构不变（各自持有 png、screen_frame、backing_scale、window_rects、
  display_identity）。
- `CaptureContextDto` 形状不变，但按覆盖层所属显示器解析。
- 冻结图的协议存储从"单个"改为"按 token 的 Map"，会话结束时整体清理。

冻结顺序与失败策略：

1. 先冻结指针所在显示器并立即创建该覆盖层，保持现有首屏延迟不变。
2. 其余显示器在后台按顺序冻结，每完成一块创建一块覆盖层。
3. 次要显示器失败只记录日志并跳过，不得取消或阻塞主屏捕获；
   主屏失败仍走现有取消路径。
4. Linux Wayland 仍只冻结单屏，行为与现在一致。

IPC 与窗口归属：

- `start_capture` 增加窗口参数：重入时按覆盖层 label 解析对应显示器，
  返回该显示器的上下文；没有绑定则回退到 index 0。
- `prepare_capture_annotation`、`confirm_capture`、`start_recording_flow`、
  滚动截图入口都按 owner label 选显示器，其余逻辑不变。
- 取消命令仍然一次拆除全部覆盖层。

交互规则：

- 每块覆盖层都是独立可交互的单显示器表面；在任意一块上按下并拖动即开始该屏的框选。
- 指针所在屏的覆盖层在启动时获得焦点；点击其它屏的覆盖层使其获得焦点并可继续操作。
- `Esc` 在任意覆盖层上取消整个会话；`Return` 只确认当前聚焦覆盖层的选区。
- 完成卡片、置顶窗、录制控制条都按"确认覆盖层所属显示器"定位。
- 多指针同时在不同屏上操作属于可接受限制：确认或取消会结束整个会话，
  因此不会产生两个相互覆盖的选区。

## 5. 数据与接口

新增 Tauri 命令（只增不改）：

- `set_capture_mode(mode: string) -> Result<(), String>`

不新增读取命令：前端通过 `CaptureContextDto.initialMode` 拿到后端已解析的模式。

内部结构变更（不改变前端 DTO 形状）：

- `CaptureSession.display` → `displays` + `overlays`；
- `ProtocolStore` 冻结图改为 `HashMap<token, FrozenCapture>`；
- `start_capture` 增加窗口参数以解析所属显示器。

## 6. 代码落点

| 位置 | 改动 |
| --- | --- |
| `src/annotation/mode-switching.js` + `.d.ts`（新增） | 数字键映射、滚轮阈值/冷却/循环的纯函数 |
| `src/annotation/cursors.js` + `.d.ts`（新增） | 手柄→光标映射、选区光标判定 |
| `src/windows/OverlayWindow.tsx` | 键盘与滚轮接入、光标状态、数字角标、提示文案、模式写入 |
| `src/annotation/AnnotationCanvas.tsx` | 改用共享光标映射 |
| `src/i18n/*.json`（7 份） | 新增提示文案键 |
| `src-tauri/src/state.rs` | `capture-mode.json` 读写；`CaptureSession` 多显示器结构 |
| `src-tauri/src/commands.rs` | `set_capture_mode`；按 label 解析显示器；多覆盖层创建与拆除 |
| `src-tauri/src/protocol.rs` | 冻结图按 token 存储与批量清理 |
| `src-tauri/src/capture/{macos,windows,linux}.rs` | 枚举并逐屏冻结；次要屏失败可跳过 |
| `src-tauri/src/lib.rs` | 注册新命令 |
| `docs/adr/0116-*.md`（新增） | 覆盖层模式快捷键、滚轮与光标反馈 |
| `docs/adr/0117-*.md`（新增） | 多显示器独立覆盖层与单屏选区边界 |
| `docs/architecture.md` | 捕获流程与窗口模型段落更新 |

## 7. 分阶段

**阶段一（低风险）**：4.1 键盘、4.2 滚轮、4.3 模式记忆、4.4 发现性、4.5 光标。
不改数据模型与协议，可独立验收与回滚。

**阶段二（结构性）**：4.6 多显示器。涉及会话结构、协议存储、三平台采集与覆盖层生命周期，
需要新增 ADR 并做真实多屏验收。

## 8. 错误处理

- 偏好文件损坏 / 未知值：回退 `screenshot`，不阻塞捕获。
- 偏好写入失败：`log::warn`，不影响当前会话。
- 次要显示器冻结失败：跳过该屏并在日志记录原因，主屏捕获继续。
- 覆盖层创建失败（单屏）：沿用现有失败路径；主屏失败则取消整个会话。
- 滚轮误触：阈值 + 冷却双重限制，切换结果在选择器上立即可见且可一键切回。

## 9. 测试与验收

自动化：

- Node：
  - 数字键 → 模式映射、`annotating` 阶段不生效；
  - 滚轮阈值、冷却、双向循环顺序；
  - 模式写入防抖只产生一次调用；
  - 手柄 → 光标映射、选区内部/外部的光标判定。
- Rust：
  - `capture-mode.json` 合法性回退；
  - 显式模式与偏好的优先级；
  - 按覆盖层 label 解析显示器的绑定；
  - 冻结图 Map 的 token 校验与会话结束后清理；
  - 次要显示器失败不取消主屏会话。
- `cargo test --manifest-path src-tauri/Cargo.toml`
- `cargo check --manifest-path src-tauri/Cargo.toml`
- `pnpm build`
- `git diff --check`

人工验收：

- 单屏：`⇧⌘A` 后按 `2` 直接进入录屏；滚轮循环不误触；IME 与标注阶段不受影响；
  光标在八个手柄、选区内部、空白处分别正确；右键语义不变；重启后停在上次模式；
  显式录屏快捷键仍强制录屏。
- 双屏（macOS Retina + 1x 外接、Windows 100%/150%、Linux X11 双屏）：
  两块屏同时出现覆盖层；在任一屏直接框选成功；
  主屏立即可用、次要屏稍后出现；次要屏断开时不阻塞主屏；
  完成卡片出现在确认的那块屏；`Esc` 在任意屏都能取消。

## 10. 风险

- 触控板惯性滚动可能触发多次切换：以 350ms 冷却与 60px 阈值缓解；
  若实测仍误触，降级为"按住修饰键才响应滚轮"。
- 多显示器同时冻结会增加后台解码与内存占用：每屏仅一份 PNG，随会话结束释放；
  次要屏采用后台串行冻结，避免与主屏抢占。
- 多覆盖层与 macOS 全屏 Space 父面板（ADR 0047）的复用方式需要逐屏验证；
  若父面板无法安全复用，则每屏各自持有一个父面板，并在销毁时统一释放。
- 混合 DPI 下每屏仍使用自己的 `backing_scale`，选区与导出坐标保持在单屏逻辑坐标内，
  不引入跨屏缩放换算。

## 11. 回滚

阶段一的四块改动彼此独立（键盘、滚轮、记忆、光标），可单独回退。
阶段二以"会话结构 + 协议存储 + 采集枚举"为单位回退，回退后即恢复单屏行为，不影响阶段一。
