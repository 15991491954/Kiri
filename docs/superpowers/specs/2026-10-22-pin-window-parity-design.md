# 贴图（Pin）能力设计 —— Windows 优先

日期：2026-10-22
状态：已确认，待实现（P0 Windows 先行）
对照对象：Snipaste 2.11.3 x64（Qt 6，闭源）
关联：`docs/adr/0118-pin-windows-and-clipboard-pins.md`、
`docs/superpowers/plans/2026-10-22-pin-window-parity-plan.md`、
`docs/adr/0003-manual-region-selection.md`、`docs/adr/0111-configurable-action-shortcuts.md`

## 1. 目标

把 Kiri 的贴图从"库里的图片另开一个只读窗口"提升为与截图同一条工作流的一等能力：

1. 截图（默认快捷键或用户自选的 F1）完成后，工具栏 📌 直接把当前结果贴到原位置。
2. 复制任意图片、图片文件或文字后，按一次 F3 生成贴图；文字排版成位图。
3. 贴图无边框、不抢焦点、不占任务栏、不出现在 Kiri 自己的截图里。
4. 贴图始终处于系统置顶层：切换、点击其他应用窗口都不会遮挡贴图；多张贴图同时置顶，
   点击其中一张只在置顶层内提升它，不会把其他贴图压到普通窗口后面。
5. 鼠标停在任意贴图上按 Esc，关闭那一张；不需要贴图窗口有键盘焦点。
6. 同一张图可以贴多次，多张贴图同时存在；关闭即释放。
7. 以 Windows 为唯一验收平台，其余平台只保证编译与降级，不纳入本次验收。
8. 指针直接操作图像：按住图片即可拖动贴图；滚轮以鼠标所在点为锚点放大/缩小该贴图，
   滚动期间显示当前缩放比例。

非目标：贴图内标注、贴图组、跨应用拖放源、旋转/翻转、透明度、鼠标穿透、
macOS/Linux 的全局 Esc。

## 2. 已确认的产品决策

| # | 决策 | 含义 |
| --- | --- | --- |
| 1 | 剪贴板贴图**不写入库** | 只存在内存与贴图窗口生命周期内；库中不出现新资产 |
| 2 | 文字与图片共用 **F3** | 一个动作读取剪贴板：图片优先，其次图片文件，最后文字；不再区分 Shift+F3 |
| 3 | Esc 关闭**鼠标选中的那一张** | 用光标位置命中贴图，关闭最上层的那一张；未命中不拦截按键 |
| 4 | 贴图**全程置顶** | 进入 `WS_EX_TOPMOST` 带并在每次创建、复用、置顶切换和桌面激活后校验；多张贴图同带共存，点击只在带内提升 |
| 5 | 按推荐流程实施，P2 做持久化 | P0 功能对齐，P1 体验，P2 才做重启恢复与恢复逻辑 |

补充：截图快捷键保持现有可配置模型。默认仍是 `⇧⌘A` / `Shift+Ctrl+A`；需要 F1 时在设置中绑定为 `F1` 即可，贴图入口不依赖具体热键。

## 3. 参考实现分析（Snipaste 2.11.3）

闭源，无法阅读源码。以下结论来自二进制符号、导入表、Qt 翻译包、内嵌 CLI 文档与可观察行为，
可信度分级沿用原分析。

### 3.1 贴图是独立对象，不是截图窗口的一种状态

符号表保留了 `SP::Paster`、`PasterController`、`PasterOptions`、`requestNewPaster`、
`destroyPaster`、`onPasterRemoved`、`pasterNumChanged`。每个贴图是一个独立顶层窗口 +
图像 + 状态，控制器用集合持有它们。这解释了为什么同一张图能贴多次、Esc 能按位置关闭
其中一张。

### 3.2 无边框、不抢焦点、可整体隐藏

- 贴图窗口去掉系统边框，内容区就是图像本身；阴影是可选项而不是默认装饰。
- `activate_on_pasted` 是显式开关，默认**不**抢键盘焦点。
- 存在 `showHidePasters`、`ao_hidePastersOnFileDialog`，说明贴图有一等公民级的
  "全部显示/隐藏"生命周期，而不是靠逐个窗口操作。

### 3.3 Esc 来自低层键盘钩子

导入表包含 `SetWindowsHookExW`、`GetAsyncKeyState`；配合 `GetCursorPos` 与
`WindowFromPoint` 做位置命中。钩子只在存在贴图时安装，只有命中贴图才吞掉 Esc。
这正是"鼠标下的贴图可被 Esc 关闭，光标在空白处时别人的 Esc 不受影响"的实现方式。

### 3.4 剪贴板优先级与文字位图化

- `Clipboard` / `WindowsClipboard` 抽象按 `Image > Files > Html > Text` 解析。
- 文字与 HTML 先经 `pasteText` / `pasteHtml` **排版渲染成位图**再贴，因此贴图尺寸固定。
- 文件列表走 `pasteFiles`：图片文件逐个贴；路径文本可选转成文字贴图。
- 触发面：全局粘贴键、截图时快捷键、托盘、命令行 `Snipaste.exe paste ...`。

### 3.5 持久化是后台节流写入

符号表有 `savePasters`、`savePasters_async`、`savePasters_intervaled`、
`savePasters_timeout`。说明它在贴图状态变化后做去抖/定时落盘，而不是每次移动都同步写。
这是 P2 的参考模型。

### 3.6 可借鉴与不可照搬

借鉴：对象模型、低层 Esc、剪贴板优先级、文字位图化、可见性整体控制、节流持久化。

不照搬：Qt 每贴图一个原生 widget 的内存模型无法直接搬到 Tauri；Kiri 需要
"Windows 原生窗口 + 跨平台编译回退"的组合（见 5.2）。

## 4. Kiri 现状与差距

| 能力 | 现状 | 证据 | 差距 |
| --- | --- | --- | --- |
| 截图 → 贴图 | 工具栏已有 📌，确认时 `pin_on_top` 保存后按原选区打开贴图 | `OverlayWindow.tsx:1531`、`commands.rs:3315` | 流程可用；但贴图窗口带永久黑边、会抢焦点 |
| 贴图来源 | 仅库卡片、完成提示 | `commands.rs:557` 白名单 `library`/`toast` | 编辑器、查看器、剪贴板都不能贴 |
| 同一张多次贴 | label 固定为 `pin-<asset_id>`，已存在则复用 | `commands.rs:578` | 需要实例级 label |
| 外观 | 永久 2px 黑边 + 内白环 + 8px 圆角 | `pin-window.css:2` | 与"图片直接浮在屏幕上"冲突 |
| 任务栏 / Alt+Tab | 未设 `skip_taskbar` | 创建器 `commands.rs:604` | 贴图占任务栏 |
| 焦点 | 创建后 `set_focus()` | `commands.rs:635` | 打断原应用输入 |
| Esc | 仅窗口内 keydown | `PinWindow.tsx:84` | 无焦点即失效 |
| 剪贴板 | 只有库窗口的"粘贴图片"，落到库里成资产 | `commands.rs:1493` | 无全局快捷键、不直接贴图、无文字 |
| 文字/文件 | 无 | — | 需新增解析与排版 |
| 性能 | 每个贴图一个完整 WebView，加载主 bundle（约 536 KB JS） | `dist/assets/index-*.js`、`src/main.tsx` | 多贴图时内存成倍增长 |

## 5. 方案

### 5.1 对象模型

新增 `src-tauri/src/pin/mod.rs`（与平台无关）：

```rust
pub struct PinId(pub u64);                 // 进程内单调递增，实例级
pub enum PinSource {
    Asset { id: uuid::Uuid, path: PathBuf },   // 库里的图：surface 只读一次并缓存
    Memory { token: String, image: PinImage }, // 剪贴板图片/文字：只在内存
}
pub struct PinImage { width: u32, height: u32, bgra: Arc<[u8]> } // 预乘 BGRA
pub struct PinSpec { source: PinSource, physical: Rect, scale: f64 }
pub struct PinRecord { id: PinId, label: String, hwnd: isize, rect: Rect, z: u64, source_kind }
```

`PinRegistry` 挂在 `AppState`：`Mutex<Vec<PinRecord>>`，提供 `insert / remove_by_label /
label_at(point) / raise / snapshot`。约束：

- 上限 16 个同时存在；超限返回可读错误并提示"先关闭一张贴图"。
- 解码后源图总量上限 256 MB；展示 DIB 单独计入 256 MB 预算。16 张 4K 源图约
  531 MB，必然超出，因此以字节预算而不是数量作为真正的内存闸门。注册表在创建和
  缩放前累计校验，超限时拒绝创建或夹取缩放倍率，避免一次剪贴板操作把进程撑爆。
- 单张贴图的展示缓冲上限 32 MP（约 128 MB）；触顶后继续滚轮不报错、不移动窗口。
- label 固定为 `pin-<instance>`（不再依赖 asset id），窗口销毁事件里按 label 清理。
- `label_at` 对物理坐标做命中，倒序 + `WindowFromPoint` 校准，二者结果不一致时以
  原生窗口为准，避免透明区域误判。

### 5.2 渲染层：Windows 原生分层窗口（推荐）

"占用低"是硬要求。现有方案每个贴图一个 WebView2，典型常驻约 20–40 MB/窗口
（P0-7 实测确认）；8 张就会让一个截图工具常驻数百 MB。Windows 专用场景下改用原生分层窗口：

- 独立线程 `kiri-pin-surface` + 自有消息循环，集中持有所有贴图 HWND，不占用 Tauri
  主线程，也不参与 WebView 生命周期。
- 窗口样式：`WS_POPUP`，扩展样式 `WS_EX_LAYERED | WS_EX_TOOLWINDOW |
  WS_EX_TOPMOST`，并在系统开启"悬停时滚动非活动窗口"时附加
  `WS_EX_NOACTIVATE`。实测（Windows 10 21H2）：只返回 `MA_NOACTIVATE`
  不够——点击未激活的置顶分层窗口时，系统仍会先取消原前台窗口，结果是桌面变成
  "没有前台窗口"，用户正在使用的应用反而失去焦点。加 `WS_EX_NOACTIVATE`
  后点击完全不影响前台窗口，悬停滚轮缩放仍然正常。仅当系统关闭悬停滚动时去掉
  该样式并返回 `MA_ACTIVATE`，让用户"点一下再滚"；该样式会随
  `WM_SETTINGCHANGE` 在已有贴图上同步切换，不再只按创建时的设置决定。
- 用 `UpdateLayeredWindow` 提交 32 位 DIB：无闪烁、逐像素 alpha、透明处不接收鼠标。
- 内存模型：每个贴图只保留一份**预乘 BGRA** 源图（解码后立即丢弃直通 RGBA）；
  100% 且窗口等于源图尺寸时直接把源 DIB 交给 `UpdateLayeredWindow`，不复制、不重采样；
  低于 100% 用 box 滤波缩小，高于 100% 才分配一张与窗口同尺寸的展示 DIB，
  回到 100% 后释放。重采样**不用 GDI `HALFTONE`**：实测 4K 源图到 1080p / 4K / 8K
  目标分别是 30.6 / 29.9 / 208.6 ms，无法支撑连续滚轮；改用自己写的分带、按行并行
  双线性（单线程 38.6 / 84.3 / 206.0 ms，4 线程约为四分之一），`COLORONCOLOR`（最近
  邻）只作为 hook 失败或内存紧张时的降级选项。
  解码、文件读取、文字栅格化和重采样都在 worker 线程完成，完成后把缓冲区所有权交给
  surface 线程；surface 线程只做几何提交与 `UpdateLayeredWindow`，不在消息循环里
  解码、读盘或重采样。
- 资产贴图是**快照**：编辑库里的原图不会改写已打开的贴图；重新贴一次才取新像素。
  这比文件监听少一条 I/O 与失效链路，也避免缩放过程中源图被替换。
- `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`：贴图不出现在 Kiri 的截图/录制中
  （复用 `platform::set_window_capture_excluded` 的同一 API）。
- 不建任务栏条目，不进 Alt+Tab；`skip_taskbar` 等价能力由 `WS_EX_TOOLWINDOW` 提供。
- 置顶保障（硬要求）：`WS_EX_TOPMOST` 只负责"进入置顶带"，不能当成一次性的创建参数。
  每次创建、显示、复用和"置顶"切换都同步执行
  `SetWindowPos(HWND_TOPMOST, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE)`，再用
  `GetWindowLongPtrW(GWL_EXSTYLE)` 校验 `WS_EX_TOPMOST` 真的存在；未进带时重试一次，
  仍失败则记录 warning 并交给自愈钩子。用户显式"取消置顶"则同步移出置顶带并校验，
  之后不再被自愈修复，直到重新置顶。
- 置顶自愈：独立线程 `kiri-pin-topmost` 安装 `SetWinEventHook(EVENT_SYSTEM_FOREGROUND,
  WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS)`，只在存在贴图时运行；桌面切到其他应用后，
  逐张检查仍在 `PinRegistry` 中且未被用户取消置顶的贴图，只有掉出置顶带的才重新入带。
  没有贴图就卸载，不轮询、不常驻定时器。
- 多张贴图：全部同时位于置顶带；点击某张只做带内提升（`SetWindowPos` + `SWP_NOACTIVATE`），
  不激活窗口、不改变键盘焦点，因此不会把其他贴图压回普通窗口层。
- 退出条件：最后一个贴图销毁时卸载钩子；若销毁与新贴图创建并发，释放前后都重新检查剩余贴图，
  避免新贴图失去自愈。钩子安装失败只降级自愈，贴图本身仍然置顶且可验证。
- 右键菜单（原生 `TrackPopupMenu`）：置顶切换、复制图像、另存为、在编辑器中打开、
  关闭、关闭全部。P0 先给"置顶切换 / 关闭 / 关闭全部"。
- 缩放与移动：拖动直接作用于图像本身，`WM_LBUTTONDOWN` 记录起点，`WM_MOUSEMOVE`
  里 `SetWindowPos(..., SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER)`；不重绘。
  位移必须用 `GetCursorPos` 的**屏幕物理坐标**减去按下时的起点，不能用
  客户区坐标：窗口自己在移动，客户区坐标会把窗口位移反馈进增量，产生抖动和漂移。
  **不要调用 `SetCapture`**：贴图不激活、永远不是前台窗口，实测系统会立刻收回捕获
  并送来 `WM_CAPTURECHANGED`，如果按原设计用它结束拖动，每次拖动都会在第一次移动前
  被取消。只用 `WM_MOUSEMOVE` 时，分步的 40 像素移动位移精确为 (160, 100)、漂移 0，
  但一次 420 像素的快速甩动收不到任何移动事件（实测），拖动会中断。因此拖动期间在
  钩子线程临时安装 `WH_MOUSE_LL`：回调只 `GetCursorPos` + `PostMessage` 给贴图线程，
  并按 4 ms 节流（高回报率鼠标不会把贴图线程淹掉），按键抬起（包括在贴图外面抬起）
  结束拖动并卸载钩子；没在拖动时钩子不存在。
  另外用 `GetAsyncKeyState(VK_LBUTTON)` 做兜底，避免丢失抬起事件后卡在拖动状态。
  拖动过程中同步更新注册表矩形（Esc 命中用），松手后再去抖持久化（P2）。
  不做逻辑像素二次换算，混合 DPI 下保持 1:1 物理像素。
  尺寸调整保留 8 个命中区域，默认锁比例，按住 `Shift` 自由比例。
- 滚轮缩放（zoom）：`WM_MOUSEWHEEL` 读取 `GET_WHEEL_DELTA_WPARAM`，以光标在窗口内的
  归一化位置为锚点，一次 `SetWindowPos` 同时提交位置与尺寸（`SWP_NOZORDER`，不改变
  置顶带与同带顺序），尺寸强制保持图像宽高比；`100%` = 1 图像像素 : 1 物理像素。
  相邻滚轮事件在贴图线程的消息循环里合并为一次几何提交（累积目标倍率，未提交的只
  保留最新值），边界为"关闭控件最小尺寸"、"单张展示上限 32 MP"与"单边 8000 物理像素"。
  缩放百分比不画在贴图自己的像素里：用一张共享的 96×36 分层小窗
  （`WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_TRANSPARENT`）跟随指针所在的象限，
  用 `DrawTextW` 渲染**桌面实际应用后**的百分比，最后一次滚轮后 900 ms 由一个
  `SetTimer` 隐藏。这样 100% 时不存在展示 DIB，也不需要备份/恢复贴图像素。
  每次合并后的提交是：一次分带并行双线性（或 100% 时零次）+ 一次
  `UpdateLayeredWindow` + 一次小窗刷新。实测帧预算：1080p 约 10 ms、4K 约 28 ms、
  8K 约 60 ms（4 线程重采样 + 分层窗口上传 1.5 / 7.7 / 26.7 ms），因此典型 1–2 MP
  贴图跟手，4K 贴图滚动期间约 30–50 fps，8K 明显变慢但可用。
  滚轮路由：Windows 默认开启"当我悬停在非活动窗口上时滚动它们"，系统把滚轮消息直接
  送给光标下的窗口，贴图不需要点击或焦点（实测：未激活的分层贴图收到
  `WM_MOUSEWHEEL`，delta 120，前台窗口不变）。关闭该选项时，`WM_MOUSEWHEEL` 只到
  前台窗口；由于贴图默认不激活，此时点击贴图后也拿不到滚轮（旧方案在这里写错了）。
  修正为：系统开启悬停滚动时，贴图使用 `WS_EX_NOACTIVATE` 并返回
  `MA_NOACTIVATE`，点击既不让贴图成为前台窗口，也不会清空原前台窗口；系统关闭
  悬停滚动时（`SPI_GETMOUSEWHEELROUTING` 为 0），去掉 `WS_EX_NOACTIVATE` 并对
  点击返回 `MA_ACTIVATE`，让用户"先点一下再滚"。两种状态在启动和
  `WM_SETTINGCHANGE` 时刷新，切换设置后已有贴图同样生效。除了拖动期间那个
  `WH_MOUSE_LL`，不常驻全局鼠标钩子。

平台回退：非 Windows 继续使用现有 `PinWindow.tsx`（WebView）。命令层按
`cfg!(windows)` 选择 surface；两套实现共享 `pin` 模块、协议 token、快捷键和设置。
这样不会破坏 macOS/Linux 的编译与现有行为。

### 5.3 截图 → 贴图（与截图整合）

现有 `pin_on_top` 链路已经是正确形状，保留并收紧：

1. 截图/标注完成，点工具栏 📌：`confirm_capture(pin_on_top=true)`。
2. 仍只写一次库（截图完成本来就要落盘），贴图**引用 asset id**，不复制文件。
3. 所有 overlay 销毁后 `open_pinned_screenshot` 用 `capture_pin_placements`
   记录的原始选区物理矩形打开贴图，落到原位置。
4. 新贴图不 `set_focus`，只 `SetWindowPos(SWP_NOACTIVATE)` 显示；Esc 由全局钩子接管。
5. 来源白名单扩到 `editor-*`、`viewer-*`（编辑器有未保存标注时禁用按钮）。

`F1`：截图动作本身可配置。若用户把 Capture 绑定为 `F1`，流程完全一致；本方案不改默认值。

### 5.4 剪贴板 → 贴图（单一 F3 动作）

新增命令 `paste_as_pin`：

1. 后台线程读剪贴板（`arboard`，Windows 上已在本项目用于图片导入）：
   `get_image` → `get().file_list()` → `get_text`。
2. 图片：`arboard::ImageData` 的 RGBA 直接转预乘 BGRA；尺寸超过当前显示器工作区
   80% 时按比例缩小到 80%，其余保持 1:1。复制前先按 `w * h * 4` 计入预算。
3. 图片文件：仅接受 `png/jpg/jpeg/webp/gif/bmp`，上限 16 个文件、单张 40 MP；
   先用 `image::image_dimensions` 读尺寸并校验预算，再解码，避免为了一张超限图
   先把内存撑大。`image` crate 需要补上 `bmp` feature。不写库。
4. 文字：Windows 上直接用 GDI `DrawTextW` 排版并画进 32 位 DIB，不新增
   `cosmic-text` / `tiny-skia`：
   - 先用 `DrawTextW(DT_CALCRECT | DT_WORDBREAK | DT_EDITCONTROL)` 量出高度，
     最大宽度 480 逻辑像素 × 目标显示器 scale，内边距 12，字号 14；
     行距用字体自身的行高（GDI 计算），不强行指定 1.45，避免为了行距改成逐行绘制。
   - 卡片是不透明的，所以整张卡片 alpha = 255，文字抗锯齿直接与卡片底色混合；
     圆角只在卡片外侧把 alpha 置 0。GDI 不写 alpha 通道的问题因此不会出现。
   - 背景为不透明圆角卡片（浅色 `#ffffff`、深色 `#1f1f1f`，跟随系统主题），
     正文 `#1f1f1f` / `#f5f5f5`，保证任何桌面背景上都可读；
   - CJK 按字断行，超长 URL 先插入软断点再断词；最多 20 000 字符、最大高度
     1200 逻辑像素，超出截断并以省略号结束；
   - 空文本、全是空白字符 → 明确错误提示，不创建空贴图。
   - 这条路径只做 Windows；macOS/Linux 的 P0 不提供文字贴图，图片与图片文件仍可
     走 `ProtocolStore` 临时 token 的 WebView 回退。这样不需要把字体数据库常驻进内存。
5. 承载：Windows 原生 surface 直接持有预乘 BGRA，不经过 `kiri://`、不写库、不落盘；
   非 Windows 回退才使用 `ProtocolStore` 的临时 token 与 WebView。P2 恢复时才另存
   PNG 到应用缓存目录。
6. 放置：光标所在显示器，以光标为中心，夹到工作区；多张按 `24px` 级联。
7. 触发器：`ShortcutAction::PastePin`（默认 `F3`，功能键无需确认，符合 ADR 0111）、
   托盘菜单"粘贴为贴图"、命令行 `kiri --paste-pin`。

F3 是全局热键，会抢走其他应用的 F3（Snipaste 同样如此）。设置页允许改成任意组合或关闭。

### 5.5 Esc 关闭鼠标下的贴图（Windows）

新增 `platform/windows.rs::PinEscapeMonitor`：

- 只在 `PinRegistry` 非空时安装 `WH_KEYBOARD_LL`，最后一个贴图关闭即卸载；
  复用现有 `MessageLoopWorker` 的安装/退出模式。
- 回调只处理 `WM_KEYDOWN/WM_SYSKEYDOWN` + `VK_ESCAPE`，忽略自动重复
  （`lparam & 0x4000_0000`）。
- `GetCursorPos` → `WindowFromPoint` → `GetAncestor(GA_ROOT)`；命中注册表则向贴图线程
  `PostMessage(WM_APP_CLOSE_PIN)` 并返回 `LRESULT(1)` 吞掉按键，否则 `CallNextHookEx`。
  不在 hook 回调里切到 Tauri 主线程，也不在回调里长时间持有注册表锁。
- 关闭统一由贴图线程执行：销毁 HWND、`PinRegistry::remove_by_label`、释放源图与
  展示缓冲、更新钩子状态。
- 窗口自身的 `WM_KEYDOWN` 仍保留 Esc / Ctrl+W，作为悬停滚动关闭时贴图获得焦点的兜底。

副作用控制：无贴图时钩子根本不存在；有贴图但光标不在贴图上时不吞键；
不改注册表、不要求额外权限、不轮询 `GetAsyncKeyState`。

### 5.6 视觉与交互

- 默认零装饰：无外框、无内白环、无圆角裁切；图片像素直接显示。
- 悬停不显示常驻描边；右键菜单承担全部操作，避免"为了两个按钮在每个贴图上画 UI"。
- `PinWindow.tsx` 的 CSS 同步去掉常驻描边，供非 Windows 回退使用。
- 拖动跟手；缩放 8 方向；点击贴图只提升层级，不夺焦点；`Esc` 关闭；右键菜单可置顶切换。
  唯一例外是系统关闭了"悬停滚动非活动窗口"：此时点击贴图会按 5.2 的规则取得焦点，
  否则滚轮无法到达贴图；创建贴图仍然不抢焦点。
- 拖动图片即可移动：没有标题栏，也没有拖动把手；原生 surface 用
  `GetCursorPos` 的屏幕物理坐标计算一次位移，WebView 回退用 `screenX/screenY`
  乘一次 `scaleFactor`，Retina/混合缩放屏都不会因窗口自身移动而漂移。
  贴图不激活，所以 Windows 会立刻收回 `SetCapture`；拖动期间临时装
  `WH_MOUSE_LL` 保证快速甩动也不丢手势，抬手即卸载。
- 滚轮缩放：鼠标停在哪张贴图，就只滚哪一张；以鼠标点为锚点等比放大/缩小，
  光标下的图像内容保持不动；一次性提交位置与尺寸，不改变置顶带与同带顺序。
  `100%` 表示 1 图像像素对应 1 物理像素；向上滚 = 放大，默认每格 10%
  （`1.1^(delta/120)`），触控板的小增量按指数连续生效。拖动或按住角缩放期间
  滚轮不改变尺寸，松手后才恢复。
- 缩放比例提示：滚动期间在指针所在的那一角显示 `110%` 这样的胶囊提示，显示的是
  **桌面实际应用后的尺寸**对应的百分比（不是请求倍率），最后一次滚动后约 900 ms
  消失；提示是一张共享的分层小窗，只渲染文字，不接收指针事件，不参与贴图的重采样，
  也不改变窗口焦点。跟随指针所在的角，是因为以指针为锚点放大时，窗口对角可能被推出
  屏幕，固定角落会让提示消失。
- 缩放边界：最小为关闭控件可用的 80×60 DIP；最大同时受"单边 8000 物理像素"和
  "单张展示 32 MP"约束。触顶后继续滚动不报错、不移动窗口；回到 100% 后释放展示 DIB，
  工作集回落到"源图 + 元数据"。
- 贴图窗口不参与截图：原生 surface 设置 `WDA_EXCLUDEFROMCAPTURE`。

### 5.7 性能预算与实现约束

| 指标 | 目标 | 做法 |
| --- | --- | --- |
| 单张贴图常驻内存 | 源图字节 + 展示 DIB（仅非 100% 缩放）+ < 1 MB 元数据 | 原生 layered window，无 WebView；典型区域截图 1–4 MB，全屏 4K 约 33 MB |
| 全部贴图常驻 | 源图 ≤ 256 MB，展示缓冲 ≤ 256 MB | 16 张上限 + 两个全局字节预算；单张展示 ≤ 32 MP。按字节算 4K 贴图约 7 张触顶，数量上限只是兜底 |
| 按键/鼠标钩子空闲开销 | 0 | 无贴图不装键盘钩子；没在拖动不装鼠标钩子；回调只比较 VK_ESCAPE / 读一次 `GetCursorPos` |
| 拖动 | 无 IPC、无重绘、无重采样 | 拖动只 `SetWindowPos`；指针用屏幕物理坐标；钩子回调只投递一条消息 |
| 滚轮缩放 | 每次合并后的提交 ≤ 1 次重采样 + 1 次 `UpdateLayeredWindow` | 1080p 约 10 ms、4K 约 28 ms、8K 约 60 ms；消息循环里合并未提交的倍率；100% 时不重采样 |
| 滚轮空闲 | 0 | 900 ms 后隐藏比例小窗并停表，无常驻定时器、无轮询 |
| 剪贴板 → 贴图 | 图片 ≤ 300 ms（4K PNG），文字 ≤ 100 ms | worker 线程解码 / GDI 排版；不落盘、不加载字体数据库 |
| 截图 → 贴图 | 不重复解码 | 截图路径直接把内存里的预乘 BGRA 交给 surface，不再读回 PNG |
| 启动 | 不增加 | 不预创建窗口、不启动定时器 |
| 关闭 | 立即释放 | 销毁 HWND + 丢弃源图与展示缓冲 |

不支持的能力（P0 明确不做）：透明度、旋转/翻转、鼠标穿透、贴图组、贴图内标注。
这些进入 P1/P2，避免一次性把交互面铺得过大。

### 5.8 设置与文案

- 快捷键新增一行"粘贴为贴图"，默认 `F3`，沿用事务式替换（失败保留旧绑定）。
- 贴图设置区：`Esc 关闭鼠标下的贴图`（本次固定开启，无开关）、"关闭全部贴图"菜单项说明。
- P2 增加：重启后恢复贴图、清理贴图缓存。
- 七个语言字典同步新增文案；英文原文作为 key。

## 6. P2 持久化与恢复设计

P0/P1 不落盘。P2 的目标是"重启后贴图还在"，但仍不写入图库。

### 6.1 存储布局

```
%APPDATA%\kiri\pins.json          # 会话清单（原子写）
%APPDATA%\kiri\pins\<id>.png      # 仅内存来源贴图的字节快照
```

`pins.json`：

```json
{
  "version": 1,
  "savedAt": "2026-10-22T10:00:00Z",
  "pins": [
    { "id": 1, "source": { "kind": "asset", "assetId": "..." },
      "x": 120, "y": 240, "width": 680, "height": 260, "scale": 1.5,
      "z": 3, "opacity": 1.0, "rotation": 0 },
    { "id": 2, "source": { "kind": "file", "file": "pins/2.png" },
      "x": 0, "y": 0, "width": 420, "height": 300, "scale": 1.0, "z": 4 }
  ]
}
```

### 6.2 写入

- 任何创建、移动、缩放、关闭、置顶变化后标记为 dirty，500 ms 去抖写一次；
  应用退出时同步 flush 一次。
- 临时文件 + 原子替换（沿用 `shortcut_settings` 的 `NamedTempFile::persist` 模式）。
- 缓存目录总量上限 200 MB，按最后访问时间 LRU 淘汰；单张 > 64 MB 拒绝恢复。

### 6.3 恢复逻辑

启动顺序：库打开成功 → 枚举显示器 → 读取 `pins.json` → 逐条校验 → 创建窗口。

校验与降级：

1. `version` 不支持：重命名为 `pins.json.bak`，以空清单启动，不删除缓存文件。
2. JSON 损坏：同上，记录一条 warning，不阻塞启动。
3. asset 贴图：资产被删/进回收站/文件缺失 → 丢弃该条（不报错弹窗）。
4. file 贴图：缓存 PNG 缺失或解码失败 → 丢弃该条并删除孤立文件。
5. 矩形完全落在所有显示器之外（拔掉副屏）→ 按比例夹回主显示器工作区左上角，
   保留尺寸；尺寸超出工作区则等比缩小到 90%。
6. 超过 16 条：按 `savedAt` 保留最新 16 条，其余连同缓存文件清理。
7. 恢复的窗口不抢焦点、不进任务栏，创建顺序按 `z` 升序。

### 6.4 设置

- "退出后保留贴图"（默认开）。
- "清理贴图缓存"（立即删除 `pins/` 与清单，二次确认）。
- 恢复失败只在设置页显示一行摘要（N 张已恢复 / M 张已丢弃），不打断启动。

## 7. 风险与边界

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 全局 F3 抢占其他应用按键 | 用户按 F3 找不到"下一个" | 可在设置中改键或关闭；默认值与 Snipaste 一致 |
| 低层键盘钩子被杀软误判 | 安装失败 | 仅在有贴图时安装；失败只记录并在设置提示，贴图仍可用 |
| 原生分层窗口合成差异 | 某些远程桌面/旧显卡闪烁 | `UpdateLayeredWindow` 失败时退回普通 `WS_POPUP` + `SetLayeredWindowAttributes` |
| 剪贴板被其他程序占用 | 读取失败 | 3 次、每次 50 ms 重试；失败提示"剪贴板暂时不可用" |
| 超大图片/长文本 | 内存峰值 | 图片 40 MP、文本 20 000 字符、窗口 16 个上限 |
| 截图时贴图入镜 | 自截图被污染 | `WDA_EXCLUDEFROMCAPTURE`；失败时截图前隐藏全部贴图 |
| 多显示器/DPI | 位置错乱 | 全流程使用物理坐标；创建后 `SetWindowPos` 校正 |
| 滚轮缩放大图 | CPU 重采样，极端倍率掉帧（实测 4K 约 28 ms/帧、8K 约 60 ms/帧） | 未完成步进合并为一次提交；100% 完全不重采样；单张展示上限 32 MP、单边 8000 物理像素；重采样线程数封顶，避免抢前台应用的 CPU |
| 拖动时指针快速甩出贴图 | 非前台窗口拿不到 `SetCapture`，一次大位移就会丢掉后续移动 | 拖动期间临时安装 `WH_MOUSE_LL`，抬手即卸载；用 `GetAsyncKeyState(VK_LBUTTON)` 兜底结束拖动 |
| 系统关闭"悬停滚动非活动窗口" | 未激活的贴图收不到滚轮 | 读取 `SPI_GETMOUSEWHEELROUTING`；关闭时点击贴图按 `MA_ACTIVATE` 取得焦点，之后滚轮可用。默认配置下创建仍不抢焦点（实测未激活贴图能收到 `WM_MOUSEWHEEL`），且只有拖动期间才装鼠标钩子 |
| 缩放到极限 | 窗口超出屏幕、关闭按钮不可见 | 锚点跟随光标，光标处内容始终可见；继续反向滚动立即恢复；`Esc`/Ctrl+W 仍可关闭 |

回滚：P0 各步独立；原生 surface 可用 `KIRI_PIN_BACKEND=webview` 临时切回现有
WebView 实现（仅用于排障，不写入用户设置）。

## 8. 验证

### 8.1 自动检查

```bash
node --test scripts/pin-window.test.mjs scripts/shortcut-settings.test.mjs scripts/i18n.test.mjs
cargo test --manifest-path src-tauri/Cargo.toml
cargo check --manifest-path src-tauri/Cargo.toml
pnpm build
git diff --check
```

新增 Rust 单测：

- `pin::registry`：上限、label 唯一、`label_at` 重叠取最上层、删除后释放。
- `pin::text_image`：纯中文、纯英文、中英混排、空串、超长单行、CJK 断行、
  超长 URL 软断点、最大高度截断；断言宽高有界、非空、不 panic。
- `pin::clipboard_source`：只有文字 / 图片+文字 / 只有文件 / 非图片文件 / 空剪贴板。
- `pin::budget`：源图 256 MB 上限、展示 256 MB 上限、单张 32 MP 上限；超限时
  创建被拒绝或缩放倍率被夹取，且状态不变。
- `platform::windows` 钩子状态机：空集合不安装、非空安装一次、回到空卸载。
- `pin::wheel_routing`：`SPI_GETMOUSEWHEELROUTING` 为 0/非 0 时点击返回
  `MA_ACTIVATE`/`MA_NOACTIVATE`，以及设置变化后缓存刷新。
- `platform::zoomed_pin_frame`：指针锚点（中心/四角不动）、宽高比强制、最小尺寸、
  8000 单边上限、32 MP 展示上限、非有限因子不移动窗口；`scripts/pin-window.test.mjs`
  覆盖滚轮合并、锚点归一化、百分比提示与"拖动/改尺寸期间不缩放"。
- `pin::drag`：屏幕坐标位移在混合 DPI 下只换算一次；窗口自身移动不反馈进增量。
- `pin::resample`：整数权重与浮点参考的误差上界、分带接缝处与一次性重采样一致、
  预乘 alpha 不被破坏、1:1 时直接返回源而不分配。
- `platform::windows` 拖动钩子：按下时安装、抬起（含贴图外抬起）时卸载、
  安装失败退回纯 `WM_MOUSEMOVE` 且不卡在拖动状态。
- `pin::persistence`（P2）：损坏文件、越界矩形、丢失资产、缓存缺失、LRU。

### 8.2 Windows 实机验收

| # | 操作 | 期望 |
| --- | --- | --- |
| 1 | 截图快捷键（含绑定为 F1 时）→ 拖选 → 点 📌 | 工具栏按钮可用；贴图出现在原选区，大小一致 |
| 2 | 新贴图出现时 | 当前应用输入焦点不变，贴图不在任务栏/Alt+Tab |
| 3 | 鼠标停在贴图上按 Esc | 只关闭鼠标下最上层那张；光标在空白处按 Esc 不影响其他应用 |
| 4 | 同一张图贴两次 | 两个独立贴图，可分别移动/关闭 |
| 5 | 拖动与 8 方向缩放 | 跟手、方向正确；Shift 可自由比例；按住快速甩动一次性越过贴图边界后仍跟手，不中断 |
| 6 | 复制图片按 F3 | 光标处出现贴图，库中无新资产 |
| 7 | 复制文字按 F3 | 得到可读的文字位图；CJK/英文换行正确 |
| 8 | 资源管理器复制 2 张图片按 F3 | 两张级联出现 |
| 9 | 截图时屏幕上有贴图 | 贴图不出现在截取结果中 |
| 10 | 贴图上限 | 第 17 张给出明确提示，不创建 |
| 11 | 关闭贴图 | 进程内存回落；无残留 HWND |
| 12 | 多显示器 100%/150% | 贴图落在光标所在屏，尺寸与位置正确 |
| 13 | 快捷键冲突 | 保存失败保留旧绑定 |
| 14 | 七语言 | 新增文案无英文回退 |
| 15 | 贴图存在时依次点击浏览器、资源管理器、桌面 | 贴图始终完整可见，不被任何普通窗口遮挡；任务栏与 Alt+Tab 不出现贴图 |
| 16 | 同时存在 2–4 张贴图，交替点击各张，再点击其他应用 | 所有贴图互相重叠时点击的那张在最上；切换到其他应用后全部贴图仍在最上层 |
| 17 | 用第三方工具清除 `WS_EX_TOPMOST` 后再切换一次前台窗口（或代码注入同等状态） | 自愈钩子把贴图重新放回置顶带，日志出现一次 restore 记录 |
| 18 | 鼠标停在贴图上向上/向下滚动滚轮（未点击过该贴图，另一张贴图在别处） | 只有光标下的那张放大/缩小；光标下的图像内容不漂移；指针所在角显示比例，停止滚动后消失 |
| 19 | 连续快速滚动 20 格后立即反向滚动 | 不卡顿、不跳位；到达最小/最大边界后继续滚动无反应且不报错 |
| 20 | 缩放到 100% 后与原图像素对照 | 1:1 清晰、无重采样模糊；窗口始终按图像宽高比缩放，不出现留白 |
| 21 | 按住图片拖动的同时滚动滚轮 | 拖动跟手且不被滚轮打断；释放后再滚动才改变尺寸 |
| 22 | 关闭系统"悬停滚动非活动窗口"后重启 Kiri，不点击直接滚，再点击后滚 | 未点击时滚轮不生效且不报错；点击后该贴图缩放；创建贴图时原应用焦点不变 |
| 23 | 4K 源图连续放大到 32 MP 上限，再回到 100% | 触顶后继续滚不报错、不移动窗口；回到 100% 后展示缓冲释放，进程工作集回落 |
| 24 | 100%/150%/混合 DPI 下拖动同一张贴图 | 指针与图像内容不漂移；拖动中滚轮不改变尺寸；松手后位置稳定 |

性能实测：任务管理器记录 0/1/4/8/16 张贴图的工作集；同时记录源图字节与展示缓冲字节，
验证两个 256 MB 预算确实生效；空闲 10 秒 CPU 占用应为 0%；GDI/USER 对象数在
创建/关闭 16 次后稳定；创建第 1 张贴图的耗时取 10 次中位数。

### 8.3 平台边界

本设计只对 Windows 做验收。macOS/Linux 走 WebView 回退，功能维持现状；
Wayland 的全局 Esc 明确不支持，设置页文案如实说明。

## 9. 技术复核（2026-10-22）

### 9.1 结论

原生分层窗口方案可行，且是当前约束下占用最低的可行选择：一个贴图只占一张源图
的字节数，没有 WebView 渲染进程；拖动只改窗口位置、不重绘；滚轮缩放只在合并后的
消息里做一次重采样。需要保留的既有代码（`zoomed_pin_frame` 的锚点/宽高比数学、
窗口内 Esc、WebView 回退）已经存在并被 `scripts/pin-window.test.mjs` 覆盖。

这不是"零风险"结论：决定交互能否成立的三项 Windows 行为已用一次性原型（
`kiri-pin-spike`，不进产品代码）实测，结果见 9.3；其中"拖动用 `SetCapture`"这一条
不成立，已按实测改方案。

### 9.2 API 可用性（本仓库已锁定的 `windows` 0.62）

逐项确认以下符号已存在，不需要引入新的 Win32 包装 crate：

`UpdateLayeredWindow`、`CreateDIBSection`、`BLENDFUNCTION` / `AC_SRC_ALPHA`、
`SetWindowDisplayAffinity` / `WDA_EXCLUDEFROMCAPTURE`、`SetWindowsHookExW` /
`WH_MOUSE_LL`、`WM_MOUSEACTIVATE` / `MA_NOACTIVATE`、`SetTimer`、`CreatePopupMenu` /
`TrackPopupMenu`、`SystemParametersInfoW` / `SPI_GETMOUSEWHEELROUTING`。

需要补的 Cargo feature：`Win32_UI_HiDpi`（`GetDpiForWindow`）。`image` crate 需要补
`bmp` feature 才能兑现"接受 bmp 文件"的承诺。两者都不增加运行时组件。

### 9.3 P0-0 实测结果（2026-10-22，Windows 10 21H2，20 逻辑核）

| 假设 | 实测 | 结论 |
| --- | --- | --- |
| 默认设置下，未激活的分层贴图能收到悬停滚轮 | 收到 `WM_MOUSEWHEEL`，delta 120，前台窗口不变 | 成立，滚轮方案可用 |
| 点击不夺焦点（`MA_NOACTIVATE`） | 点击后贴图没有成为前台窗口，但原前台窗口也被取消，`GetForegroundWindow()` 返回 0 | 仅返回 `MA_NOACTIVATE` **不成立**；需配合 `WS_EX_NOACTIVATE`，实测后前台窗口保持 |
| `SetCapture` + `GetCursorPos` 拖动 | 捕获在第一次移动前就被收回并送来 `WM_CAPTURECHANGED` | **不成立**，改用拖动期间临时 `WH_MOUSE_LL` |
| 只靠 `WM_MOUSEMOVE` 拖动 | 4 步 × 40 px 位移精确 (160, 100)、漂移 0；单次 420 px 位移收不到任何移动 | 分步可用，快速甩动会断，必须加钩子 |
| `StretchDIBits(HALFTONE)` | 4K 源图 → 1080p / 4K / 8K：30.6 / 29.9 / 208.6 ms | 不可用于缩放，改用自写重采样 |
| `StretchDIBits(COLORONCOLOR)` | 同上：3.4 / 8.2 / 21.0 ms | 只作最近邻降级 |
| 自写分带双线性（单线程） | 4K 源图 → 1080p / 4K / 8K：38.6 / 84.3 / 206.0 ms | 4 线程约四分之一，可接受 |
| `UpdateLayeredWindow` | 1080p / 4K / 8K 表面：1.5 / 7.7 / 26.7 ms；每张 7 / 31 / 126 MB | 与预期一致，4K 帧预算约 28 ms |
| 预乘转换 | 4K 不透明源图 3.5 ms | 可放在 worker 线程，启动无感 |

原型同时确认：`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` 能让贴图不出现在
Kiri 自己的 WGC 截图/录制里；`UpdateLayeredWindow` 失败时整窗 alpha 回退仍能显示
不透明截图。

### 9.4 本轮修正

| # | 原设计 | 修正 | 原因 |
| --- | --- | --- | --- |
| 1 | 创建带 `WS_EX_NOACTIVATE` | 改为随悬停滚轮设置动态附加：开启时附加并返回 `MA_NOACTIVATE`，关闭时去掉并返回 `MA_ACTIVATE` | 实测只返回 `MA_NOACTIVATE` 仍会让原前台窗口被取消；而永久带 `WS_EX_NOACTIVATE` 又会让"关闭悬停滚动后点击即可滚轮"不成立 |
| 2 | 滚轮提示固定左上角 | 跟随指针所在角，并显示桌面实际应用后的百分比 | 以指针为锚点放大时对角可能被推出屏幕 |
| 3 | 单边 8000 像素是唯一上限 | 增加"单张展示 32 MP"和两个 256 MB 预算 | 8000×4500 的 BGRA 约 137 MB，16 张会失控；像素预算才是有意义的闸门 |
| 4 | 源图按 RGBA 缓存，展示时再复制 | 解码后只保留预乘 BGRA；展示 DIB 只在非 100% 缩放时存在 | 去掉常驻的第二份全图，典型占用回到"图像大小 + 少量元数据" |
| 5 | 文字用 `cosmic-text` + `tiny-skia` | Windows 用 GDI `DrawTextW` 画进不透明卡片；非 Windows 暂不提供文字贴图 | 不新增依赖、不把字体数据库常驻内存，首次文字贴图从数百毫秒降到几十毫秒 |
| 6 | 拖动"指针位移按物理坐标换算一次"（未说明来源） | 明确用 `GetCursorPos` 屏幕坐标减按下起点；`WM_CAPTURECHANGED` 结束拖动 | 客户区坐标会因窗口自身移动而反馈成漂移 |
| 7 | 拖动用 `SetCapture`，`WM_CAPTURECHANGED` 结束 | 不调用 `SetCapture`；拖动期间临时 `WH_MOUSE_LL`，抬手即卸载 | 实测非前台贴图的捕获在第一次移动前就被收回，`WM_CAPTURECHANGED` 会直接结束拖动；而且一次大位移收不到移动事件 |
| 8 | 每次缩放提交一次 `StretchDIBits(HALFTONE)` | 自写分带并行双线性；`COLORONCOLOR` 只作降级；100% 直接提交源 DIB | 实测 `HALFTONE` 到 1080p 就要 30.6 ms、到 8K 要 208.6 ms，无法支撑连续滚轮 |
| 9 | 比例提示画进贴图的展示 DIB（备份/恢复矩形） | 独立共享 96×36 分层小窗 | 100% 时不再需要展示 DIB，也不用为徽标复制和恢复贴图像素 |
| 10 | 主张"16 张贴图各占一张图，内存可预期" | 以字节预算为准：4K 贴图约 7 张就触顶 | 16 × 33 MB ≈ 530 MB，已超过 256 MB 源图预算，数量上限只是兜底 |

另外两处实现层修正：原生贴图不是 Tauri 窗口，清理要由 surface 线程的 `WM_DESTROY`
驱动（不能依赖 `WindowEvent::Destroyed`）；Esc 钩子向贴图线程 `PostMessage`，
不切 Tauri 主线程。
