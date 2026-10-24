# 贴图（Pin）能力对齐 —— 实施方案（Windows）

日期：2026-10-22
对应设计：`docs/superpowers/specs/2026-10-22-pin-window-parity-design.md`
决策记录：`docs/adr/0118-pin-windows-and-clipboard-pins.md`
范围：Windows 实机验收；macOS/Linux 只保证编译和现有 WebView 行为

## 0. 实施原则

- 每个阶段独立可验证、可回退，不触碰截图选区、标注、录制、OCR/QR 的既有逻辑。
- Windows 用原生分层窗口；非 Windows 继续用 `PinWindow.tsx`，命令层按平台分派。
- 剪贴板贴图不写库、不落盘（P2 才按需缓存）。
- 先测纯逻辑，再接平台 API；平台 API 不进入单元测试。

阶段顺序：

| 阶段 | 内容 | 主要产物 |
| --- | --- | --- |
| P0-0 | 原生贴图行为尖刀验证（已完成） | 临时 crate（已删除，结论见第 0 节） |
| P0-1 | 贴图对象模型与注册表 | `pin/mod.rs`、`state.rs`、单测 |
| P0-2 | Windows 原生贴图窗口 | `pin/surface_windows.rs` |
| P0-3 | 截图 → 贴图整合 | `commands.rs`、`pin/session.rs` |
| P0-4 | Esc 关闭鼠标下的贴图 | `platform/windows.rs`、`pin/hit_test.rs` |
| P0-5 | 剪贴板 → 贴图（F3） | `pin/clipboard.rs`、`pin/text_image.rs`、`commands.rs` |
| P0-6 | 快捷键、设置、文案 | `shortcut_settings.rs`、`lib.rs`、`src/i18n/*`、设置页 |
| P0-7 | 性能测量与收尾 | 内存/延迟记录、回退开关 |
| P1 | 交互补齐 | 8 方向缩放、菜单项、编辑器/查看器入口 |
| P2 | 持久化与恢复 | `pin/persistence.rs`、`pins.json`、缓存目录 |

P0-0 已完成并改变了三处实现口径（见第 0 节）：拖动必须用临时鼠标钩子而不是
`SetCapture`，缩放必须用自写重采样而不是 GDI `HALFTONE`，比例提示用独立小窗而不是
画进贴图 DIB。对象模型、注册表和命令层的形状不受影响。

---

## 0. P0-0 尖刀验证（已完成，2026-10-22）

用一次性原型（临时 crate，不进产品代码，验收后删除）确认了决定交互能否成立的行为，
以及重采样和分层窗口上传的真实耗时。环境：Windows 10 21H2、20 逻辑核。

| 项目 | 实测 | 结论 |
| --- | --- | --- |
| 悬停滚轮（默认设置） | 未激活的分层窗口收到 `WM_MOUSEWHEEL`，delta 120，前台窗口不变 | 通过 |
| 点击是否夺焦点 | `MA_NOACTIVATE` 下贴图没有成为前台窗口，但原前台窗口被取消（`GetForegroundWindow()==0`） | 需配合 `WS_EX_NOACTIVATE`（见 2.1） |
| `SetCapture` 拖动 | 捕获在第一次移动前被系统收回，并送来 `WM_CAPTURECHANGED` | **不通过**，改用拖动期间临时 `WH_MOUSE_LL` |
| 无捕获拖动（分步） | 4 × 40 px → 位移 (160, 100)，漂移 0 | 通过，但不足 |
| 无捕获拖动（单次 420 px） | 收不到任何移动事件，拖动中断 | 需要鼠标钩子 |
| `StretchDIBits(HALFTONE)` 4K 源图 → 1080p / 4K / 8K | 30.6 / 29.9 / 208.6 ms | **不通过**，不能用于连续缩放 |
| `StretchDIBits(COLORONCOLOR)` 同上 | 3.4 / 8.2 / 21.0 ms | 只作最近邻降级 |
| 自写分带双线性（单线程）同上 | 38.6 / 84.3 / 206.0 ms | 4 线程约四分之一，采用 |
| `UpdateLayeredWindow` 1080p / 4K / 8K | 1.5 / 7.7 / 26.7 ms；7 / 31 / 126 MB | 4K 帧预算约 28 ms |

据此确定三条实现口径（已同步到设计与 ADR）：

1. 100% 且窗口等于源图尺寸时零重采样，直接把源 DIB 交给 `UpdateLayeredWindow`；
   低于 100% 用 box 缩小，高于 100% 用自写分带并行双线性；不使用 GDI `HALFTONE`。
2. 不调用 `SetCapture`（会被立即收回并结束拖动）；拖动期间临时安装 `WH_MOUSE_LL`，
   回调只 `GetCursorPos` + `PostMessage`，抬手即卸载；`GetAsyncKeyState` 兜底。
3. 缩放比例提示用独立的共享 96×36 分层小窗，不画进贴图 DIB，100% 时不存在展示 DIB。

`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` 的截图排除已由现网同类 API
（`platform::set_window_capture_excluded`）验证；`UpdateLayeredWindow` 失败时整窗
alpha 回退仍能显示不透明截图。

---

## 1. P0-1 对象模型与注册表

### 1.1 新增 `src-tauri/src/pin/mod.rs`

```rust
pub struct PinId(pub u64);
pub struct PinImage { pub width: u32, pub height: u32, pub bgra: Arc<[u8]> } // 预乘
pub enum PinSource { Asset(uuid::Uuid), Memory { token: PinToken, image: PinImage } }
pub struct PinToken(String); // 32 位十六进制，仅进程内有效
pub struct PinRecord { pub id: PinId, pub label: String, pub hwnd: isize,
                       pub rect: Rect, pub z: u64 }
pub struct PinRegistry { next: u64, z: u64, pins: Vec<PinRecord>, source_bytes: u64,
                         display_bytes: u64 }
impl PinRegistry {
    pub fn insert(&mut self, label: String, hwnd: isize, rect: Rect, source_bytes: u64)
        -> Result<PinId, String>;
    pub fn remove_by_label(&mut self, label: &str) -> Option<PinRecord>;
    pub fn label_at(&self, point: (f64, f64)) -> Option<&str>;
    pub fn raise(&mut self, label: &str);
    pub fn is_empty(&self) -> bool;
}
```

- `MAX_PINS: usize = 16`；`MAX_PIN_SOURCE_BYTES: u64 = 256 * 1024 * 1024`；
  `MAX_PIN_DISPLAY_BYTES: u64 = 256 * 1024 * 1024`；`MAX_PIN_DISPLAY_PIXELS: u64 = 32_000_000`。
  创建超源图预算返回"先关闭一张贴图"；缩放超展示预算或单张像素上限时夹取倍率，
  不返回错误。
- `label` 形如 `pin-<instance>`，由注册表分配，不再使用 asset id。
- `label_at`：倒序遍历（后创建在上），半开区间 `[x, x+w) × [y, y+h)`；调用方随后可用
  `WindowFromPoint` 校准。
- 注册表只存元数据，不存图像；图像由 surface 或 asset 持有。源图按预乘 BGRA 只存一份，
  展示 DIB 由 surface 记账并在释放时回减 `display_bytes`。

### 1.2 接入 `AppState`

`state.rs` 增加：

```rust
pub pins: std::sync::Mutex<crate::pin::PinRegistry>,
pub pin_tokens: std::sync::Mutex<HashMap<String, Arc<[u8]>>>, // 仅非 Windows 回退使用
```

`AppState::default/new` 同步初始化。原生贴图由 surface 线程的 `WM_DESTROY` 调用
`state.pins.remove_by_label(label)`；非 Windows 的 WebView 回退仍用
`lib.rs` 的 `WindowEvent::Destroyed`。注册表从非空变空时卸载 Esc/自愈钩子（P0-4）。

### 1.3 测试

- 上限：第 17 次 `insert` 失败且状态不变；源图超 256 MB、单张展示超 32 MP 时
  分别拒绝创建 / 夹取倍率。
- label 唯一、`remove` 后可重新创建；删除后源图字节与展示字节都回减。
- 重叠命中取最上层；边界点属于右侧/下侧窗口；无命中返回 `None`。
- 负坐标显示器（左侧副屏）命中正确。

---

## 2. P0-2 Windows 原生贴图窗口

### 2.1 新增 `src-tauri/src/pin/surface_windows.rs`

独立线程 `kiri-pin-surface`，自有消息循环，持有全部贴图窗口：

- 注册窗口类 `KiriPinWindow`（`RegisterClassW`），`CS_DBLCLKS`。
- 创建：`CreateWindowExW(WS_POPUP, x, y, w, h, ...)`，扩展样式为
  `WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST`，并在系统开启悬停滚轮时
  附加 `WS_EX_NOACTIVATE`。**不能永久省略 `WS_EX_NOACTIVATE`**：实测仅返回
  `MA_NOACTIVATE` 时，点击未激活的置顶分层窗口仍会取消原前台窗口，桌面变成
  "没有前台窗口"；附加该样式后原应用保持焦点，悬停滚轮缩放仍正常。系统关闭悬停
  滚动时去掉该样式，窗口才能成为前台并接收滚轮。
- 焦点：`WM_MOUSEACTIVATE` 默认返回 `MA_NOACTIVATE`，显示用
  `ShowWindow(SW_SHOWNOACTIVATE)`；启动和 `WM_SETTINGCHANGE` 时用
  `SystemParametersInfoW(SPI_GETMOUSEWHEELROUTING, ...)` 读取系统设置，值为 0 时
  对该窗口的点击返回 `MA_ACTIVATE`，让"关闭悬停滚动"的用户点一下就能滚。创建贴图
  的任何路径都不调用 `SetForegroundWindow`，默认配置下仍不抢焦点。
- 置顶保障：创建、显示、复用和置顶切换后都同步
  `SetWindowPos(HWND_TOPMOST, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE)`，再用
  `GetWindowLongPtrW(GWL_EXSTYLE)` 校验 `WS_EX_TOPMOST`；未进带时重试一次。样式只读不写：
  直接改写 `WS_EX_TOPMOST` 会让失败的重入带看起来成功，而窗口仍在其他应用后面。
  同一线程安装 `SetWinEventHook(EVENT_SYSTEM_FOREGROUND, OUTOFCONTEXT | SKIPOWNPROCESS)`
  做自愈：只在有贴图时存在，桌面切到其他应用后只修复仍要置顶、但已掉出置顶带的贴图。
  多个贴图同属置顶带，点击只 `SetWindowPos` 在带内提升且不激活窗口。
- 解码：资产 PNG/JPEG 与剪贴板图片在 worker 线程解码成**预乘 BGRA**，一次性把
  `Arc<[u8]>` 交给 surface 线程；surface 线程不读文件、不解码、不排版。贴图是快照，
  不监听库里的资产修改；重新贴一次才取新像素。
- 绘制：源图只存一份预乘 BGRA。100% 且窗口等于源图尺寸时把源 DIB 直接交给
  `UpdateLayeredWindow`（零重采样、零额外分配）；低于 100% 用 box 滤波缩小；高于
  100% 才分配一张窗口大小的展示 DIB，用自写的分带、按行并行双线性填充后提交（4 线程
  封顶）。**不用 `StretchDIBits(HALFTONE)`**：实测到 1080p 就要 30.6 ms、到 8K 要
  208.6 ms；`COLORONCOLOR` 只作为钩子/线程创建失败时的最近邻降级。回到 100% 后释放
  展示 DIB。重采样在 worker 线程完成，结果带代次号投递给 surface 线程，过期帧丢弃；
  surface 线程只做 `UpdateLayeredWindow` 与几何提交，单帧预算 1080p ≈ 10 ms、
  4K ≈ 28 ms、8K ≈ 60 ms。
- 透明区域：逐像素 alpha，`UpdateLayeredWindow` 下透明像素不接收鼠标。
- 截图排除：`SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)`。
- 拖动：`WM_LBUTTONDOWN` 记录 `GetCursorPos` 的屏幕坐标作为起点，`WM_MOUSEMOVE` 里用
  新的 `GetCursorPos` 减起点，再
  `SetWindowPos(..., SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER)`；不重绘。
  不能用客户区坐标：窗口自身在移动，客户区坐标会把位移反馈进增量。
  **不调用 `SetCapture`**：贴图不激活、不是前台窗口，实测捕获会被立即收回并送来
  `WM_CAPTURECHANGED`，用它结束拖动会让每次拖动在第一次移动前就中断。改为在拖动期间
  由钩子线程临时安装 `WH_MOUSE_LL`，回调只 `GetCursorPos` + `PostMessage` 给贴图线程，
  按 4 ms 节流；按键抬起（包括在贴图外抬起）结束拖动并卸载钩子；`GetAsyncKeyState(VK_LBUTTON)`
  兜底，避免丢失抬起事件后卡在拖动状态。拖动中同步更新注册表矩形，松手后再去抖持久化。
- 尺寸调整：8 个 12px 命中区；默认锁比例，`Shift` 自由；缩放时用同一个重采样器
  重新生成展示 DIB 并 `UpdateLayeredWindow`，与滚轮缩放共用几何函数。
- 滚轮缩放：`WM_MOUSEWHEEL` 取 `GET_WHEEL_DELTA_WPARAM`，按光标在窗口内的归一化位置
  （`GET_X_LPARAM/GET_Y_LPARAM` + 窗口尺寸）锚定，倍率 `1.1^(delta/120)`；
  在消息循环里累积目标倍率，只对最新值提交一次 `SetWindowPos`（位置与尺寸一起，
  `SWP_NOZORDER`）。强制图像宽高比；`100%` = 1:1 物理像素；最小 80×60 DIP；
  最大同时受 8000 单边和单张 32 MP 展示上限约束；触顶后继续滚不报错、不移动窗口。
  百分比提示不画进贴图 DIB：用一张共享的 96×36 分层小窗
  （`WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_TRANSPARENT`），跟随指针所在象限，
  显示桌面实际应用后的百分比，最后一次滚轮后 900 ms 用一个 `SetTimer` 隐藏。
  所有滚动缩放都不改变置顶带与同带顺序。
- 右键菜单：`CreatePopupMenu` + `TrackPopupMenu`，项为"取消/保持置顶""关闭""关闭全部"。
- 关闭：surface 线程的 `WM_DESTROY` 负责销毁 HWND、从注册表移除、释放源图与展示
  缓冲；原生贴图不是 Tauri 窗口，不能依赖 `WindowEvent::Destroyed`。最后一张关闭后
  通知平台层卸载 Esc/自愈钩子。
- 失败降级：`UpdateLayeredWindow` 返回错误时改用普通 `WS_POPUP` +
  `SetLayeredWindowAttributes`（整窗 alpha），截图贴图仍可贴、文字卡片的圆角会变成
  直角；不把失败当成致命错误。

公共接口（平台无关）：

```rust
pub struct PinSurfaceHandle { /* Send + Sync 的控制句柄 */ }
pub fn open(spec: PinSpec) -> Result<PinSurfaceHandle>;
pub fn close(label: &str);
pub fn close_all();
pub fn hit_test(point: (f64, f64)) -> Option<String>;
```

命令层与注册表只依赖这组接口；非 Windows 的实现直接转发现有 WebView 逻辑。

### 2.2 非 Windows 回退

`commands::open_pinned_screenshot` 保留现有 WebView 分支，用 `cfg(not(windows))`。
`PinWindow.tsx` 与 `pin-window.css` 同步去掉常驻黑边（P0 视觉一致性）。拖动、滚轮缩放
与比例提示已在 WebView 版实现：滚轮只发一条 `zoom_pin`（原生一次 `SetWindowPos`
同时改位置与尺寸），百分比由原生返回的实际尺寸推出。原生 surface 落地后，非 Windows
继续复用同一命令语义，Windows 侧改由 `WM_MOUSEWHEEL` 驱动同一套几何函数。

### 2.3 测试

原生窗口不能单测。抽出可测部分：

- `pin::layout`：工作区夹取、级联偏移、80% 缩放比。
- `pin::surface` 的指针数学：拖动增量（屏幕坐标）、8 方向缩放、最小尺寸、锁比例，
  滚轮缩放的指针锚点（中心/四角不动）、宽高比强制、8000 单边与 32 MP 展示上限。
- `pin::resample`：整数权重与浮点参考的误差上界、分带接缝与一次性重采样一致、
  预乘 alpha 不被破坏、1:1 直接返回源不分配。
- `pin::wheel_routing`：`SPI_GETMOUSEWHEELROUTING` 为 0/非 0 时点击
  `MA_ACTIVATE`/`MA_NOACTIVATE`；设置变化后缓存刷新。
- 拖动钩子状态机：按下安装、抬起（含贴图外抬起）卸载、安装失败退回纯
  `WM_MOUSEMOVE` 且不卡在拖动状态。
- 手动：创建/关闭 16 次无句柄泄漏；任务管理器观察 GDI 对象数稳定；4K 源图
  缩放到上限再回到 100%，展示缓冲被释放；按住图片快速甩动使指针一次越过贴图边界，
  拖动不中断。

---

## 3. P0-3 截图 → 贴图整合

### 3.1 保留现有确认链路

`OverlayWindow.tsx:1531` 的 `onPin → complete(true)` 不变；
`confirm_capture` 仍把结果写入库一次；`finalize_confirmed_capture_after_overlay_destroyed`
在 overlay 全部销毁后调用 `open_pinned_screenshot`。

### 3.2 改造 `open_pinned_screenshot`

- 命令层在库锁内把 asset 解析成可读路径（`readable_asset_url`），连同尺寸一起交给
  surface；解码在 worker 线程完成，只读一次并缓存预乘 BGRA。截图路径优先直接复用
  `capture` 会话里已有的预乘 BGRA（确认时本来就在内存里），省掉一次 PNG 解码和读盘；
  只有库/编辑器入口才回退到读文件解码。路径不经过前端 IPC。surface 线程只接收解码好
  的缓冲区，不在消息循环里读盘。
- 放置沿用 `capture_pin_placements` 的逻辑矩形 + backing scale，转物理坐标。
- Windows 走 `pin::surface_windows::open`；不再创建 WebView、不再 `set_focus`。
- 每次调用生成新的实例，不做"已存在则复用"。
- 白名单扩到 `library`、`toast`、`editor-*`、`viewer-*`；编辑器有未保存标注时前端禁用。

### 3.3 验收

- 截图 → 📌：贴图与原选区像素对齐（100%/150% 各测一次）。
- 原应用焦点不变；贴图不出现在任务栏与 Alt+Tab。
- 立即再截一张：上一张贴图不出现在新截图里。

---

## 4. P0-4 Esc 关闭鼠标下的贴图

### 4.1 纯逻辑先行

`pin/hit_test.rs`：

```rust
pub fn topmost_at(pins: &[PinRecord], point: (f64, f64)) -> Option<&str>;
```

单测覆盖重叠、边界、负坐标、无命中。平台层再叠加 `WindowFromPoint` 校准。

### 4.2 `platform/windows.rs::PinEscapeMonitor`

- 复用 `MessageLoopWorker`（安装线程 + `GetMessageW` 循环 + `PostThreadMessageW` 退出）。
- `SetWindowsHookExW(WH_KEYBOARD_LL, Some(pin_key_hook_proc), None, 0)`。
- 回调：
  1. `code < 0` → `CallNextHookEx`；
  2. 仅 `WM_KEYDOWN`/`WM_SYSKEYDOWN` 且 `vkCode == VK_ESCAPE`；
  3. 忽略自动重复位 `0x4000_0000`；
  4. `GetCursorPos` → `WindowFromPoint` → `GetAncestor(GA_ROOT)`；
  5. 把 HWND 交给注入的 `Arc<dyn Fn(isize) -> Option<String> + Send + Sync>`；
  6. 命中：向贴图线程 `PostMessage(WM_APP_CLOSE_PIN)`，返回 `LRESULT(1)`；
  7. 未命中：`CallNextHookEx`。
- 原生贴图不是 Tauri 窗口，关闭不能走 `run_on_main_thread` 的 WebView 路径；
  `WM_APP_CLOSE_PIN` 由 surface 线程统一销毁 HWND、更新注册表、释放缓冲。
- 生命周期：`pins` 从空变非空时安装；回到空时卸载并 join。安装失败只记录 warning，
  贴图仍可通过右键/窗口 keydown 关闭。
- 全局静态回调沿用 `CLICK_CALLBACK` 的写法，保证 Hook 线程不持有 Tauri 锁。

### 4.3 测试

- 状态机单测：空集合不安装、非空只安装一次、回到空卸载、重复调用幂等。
- 命中函数单测（无平台 API）。
- 手动：光标在贴图上 Esc 只关一张；在空白处 Esc 仍能退出全屏/关闭其他应用；
  按住 Esc 不连续关闭多张。

---

## 5. P0-5 剪贴板 → 贴图（F3）

### 5.1 读取与选择（纯函数）

`pin/clipboard_source.rs`：

```rust
pub enum ClipboardSource { Image, Files(Vec<PathBuf>), Text(String) }
pub fn choose(image: bool, files: Option<Vec<PathBuf>>, text: Option<String>)
    -> Option<ClipboardSource>;
```

- 优先级固定：图片 > 图片文件 > 文字。
- 文件过滤扩展名（`png/jpg/jpeg/webp/gif/bmp`），最多 16 个。
- 空文本、纯空白 → `None`，命令返回"剪贴板没有可贴的内容"。
- 单测覆盖：只有文字、图片+文字、只有文件、混合图片与非图片、文件超限、空剪贴板。

### 5.2 平台读取

`pin/clipboard.rs`（Windows）：

```rust
pub fn read_clipboard_pin() -> Result<Vec<PinSource>, String>;
```

- `arboard::Clipboard::get_image()` → 预乘 BGRA；
- `get().file_list()` → 先用 `image::image_dimensions` 校验尺寸/预算，再
  `image::open` → 预乘 BGRA；
- `get_text()` → 交给 `text_image`（Windows GDI 路径）。
- 剪贴板被占用时重试 3 次（间隔 50 ms）。
- 全程在 `spawn_blocking`，不阻塞主线程。

### 5.3 文字排版

`pin/text_image.rs`，Windows 上用 GDI `DrawTextW`，不引入 `cosmic-text` / `tiny-skia`：

- 输入：文本、目标显示器 `scale`、主题（浅/深）。
- 规则：最大宽度 480 逻辑像素、内边距 12、字号 14，行距用字体自身行高；
  CJK 按字断行；超长无空格串先插入软断点再断词；最多 20 000 字符；
  高度超过 1200 逻辑像素时截断并追加 `…`。
- 输出：不透明圆角卡片 + 文字的 BGRA。卡片内部 alpha = 255，文字抗锯齿直接与底色
  混合（GDI 不写 alpha 的问题因此不存在）；圆角外侧置 alpha = 0。
- 单测：纯中文、纯英文、中英混排、空串、20 000 字符、单行 2 000 字符 URL，
  断言宽高有界、非空、不会 panic；逐像素排版由 Windows 实机检查。
- 非 Windows 的 P0 不提供文字贴图；图片与文件仍可走 WebView 回退。

### 5.4 命令与放置

`commands::paste_as_pin(app)`：

1. 读剪贴板 → 源列表；
2. 每张图计算初始物理尺寸：1:1，超过光标显示器工作区 80% 时等比缩小；
3. 源图累计解码字节超过 256 MB 时拒绝创建并提示先关闭贴图；展示缓冲另计 256 MB，
   缩放时按 32 MP/张夹取；
4. 以光标为中心，夹到工作区，多张按 24px 级联；
5. 通过 surface 打开，注册表登记；
6. 返回创建数量；失败时 `emit_notice` 给出可读原因。

不写库、不写磁盘、不创建 WebView。

### 5.5 测试

- `choose` 与 `text_image` 单测。
- 手动：图片、文字、2 张文件、非图片文件、空剪贴板、超大图。

---

## 6. P0-6 快捷键、设置与文案

### 6.1 快捷键

- `ShortcutAction` 增加 `PastePin`，默认 `Shortcut::new(None, Code::F3)`；
  `ALL` 由 6 项扩到 7，`Bindings([_; 7])`、`index()`、`default_binding()`、
  `command() = "kiri --paste-pin"` 同步。
- `decode` 对旧版 `shortcuts.json` 缺失的 `pastePin` 自动补默认值；与既有键冲突时
  保留 `None` 并记录 warning（不能让升级失败）。
- `lib.rs`：快捷键分发加 `PastePin` 分支；`desktop_shortcut_action` 加
  `--paste-pin`；`desktop_launch_opens_library` 把 `PastePin` 视为不打开库。
- 设置页新增"粘贴为贴图"行，沿用事务式替换与冲突提示。

### 6.2 文案

新增 key（七个字典一致）：

- `"Paste as Pin"`、`"Pinned image"`、`"Pin on Top"`、`"Unpin"`、
  `"Close All Pins"`、`"Close a pinned image before pinning another."`、
  `"The clipboard has no image or text to pin."`、
  `"Could not read the clipboard right now."`。

### 6.3 测试

- `scripts/shortcut-settings.test.mjs`：默认值、`ALL` 长度、冲突拒绝、升级补默认。
- `scripts/i18n.test.mjs`：七字典键集一致。
- `scripts/pin-window.test.mjs`：WebView 回退的 DOM 断言继续通过。

---

## 7. P0-7 性能与收尾

1. 测量并记录（写入设计文档附录或 PR 说明）：
   - 0/1/4/8/16 张贴图的进程工作集，以及源图字节/展示缓冲字节；
   - 创建延迟中位数（图片、文字各 10 次）；
   - 4K 源图缩放到 1080p/4K/8K 目标的「自写重采样 + `UpdateLayeredWindow`」P50/P95
     耗时（P0-0 的原型值见第 0 节，实机再复核一次）；
   - 空闲 10 秒 CPU；
   - GDI/USER 对象数。
2. 确认无轮询、无后台定时器；Esc/前台自愈钩子只在有贴图时存在；滚轮提示的
   900 ms 定时器在最后一次滚动前不常驻。
3. `KIRI_PIN_BACKEND=webview` 仅用于排障，不进设置、不写配置。
4. 删除 Windows 上不再使用的 pin WebView 能力项（保留非 Windows 所需的 `pin.json`）。
5. 补齐 `windows` crate 的 `Win32_UI_HiDpi` feature 与 `image` crate 的 `bmp` feature；
   二者只增加编译面，不增加运行时组件。

---

## 8. P1 体验补齐

- 8 方向缩放 + `Shift` 自由比例（若 P0 未完成）。
- 右键菜单补齐：复制图像、另存为、在编辑器中打开。
- 点击贴图提升层级；置顶状态可切换并在菜单中显示勾选。
- 多贴图级联与"关闭全部"。
- 编辑器/查看器 📌 入口（编辑器有未保存标注时禁用）。
- 拖动节流与高 DPI 光标反馈。

## 9. P2 持久化与恢复

按设计文档第 6 节实现：

1. `pin/persistence.rs`：`PinSnapshot` 编解码、版本、原子写、去抖 500 ms。
2. `%APPDATA%\kiri\pins.json` + `%APPDATA%\kiri\pins\<id>.png`（仅内存来源）。
3. 启动恢复顺序与校验：资产缺失、缓存缺失、越界矩形、超上限、损坏清单。
4. 设置项："退出后保留贴图"（默认开）、"清理贴图缓存"。
5. 测试：编码往返、损坏文件降级、拔掉副屏后夹取、LRU 淘汰、资产被删后丢弃。

---

## 10. 验证

### 10.1 命令

```bash
cargo test --manifest-path src-tauri/Cargo.toml
cargo check --manifest-path src-tauri/Cargo.toml
pnpm build
node --test scripts/pin-window.test.mjs scripts/shortcut-settings.test.mjs scripts/i18n.test.mjs
git diff --check
```

`src-tauri/target` 保留，不做清理。

### 10.2 Windows 实机

按设计文档 8.2 的清单逐条验收（含滚轮缩放与比例提示）；补充：

- 截图快捷键若绑定为 `F1`，全流程不变；改回默认也不影响贴图。
- 关闭最后一张贴图后，检查键盘钩子已卸载（日志无残留安装记录）。
- 贴图与屏幕截图对照像素：1:1，无缩放模糊。
- 任务栏、Alt+Tab、Win+Tab 均不出现贴图条目。
- 贴图存在时依次点击浏览器、资源管理器、桌面：贴图全程可见，不被普通窗口遮挡；
  2–4 张贴图共存时，点击的那张在带内最上，切到其他应用后全部仍在最上层。
- 滚轮停在未点选的贴图上：只有该张放大/缩小，光标下内容不漂移，指针所在角显示比例
  并在停止滚动后消失；100% 时与原图 1:1 清晰。
- 拖动图片移动与滚轮缩放交替进行：拖动跟手、滚轮期间不改尺寸、边界处继续滚动无报错；
  按住图片快速甩动、一次把指针甩出贴图矩形，拖动仍不中断（`WH_MOUSE_LL` 生效），
  松开后拖动状态结束。
- 关闭"在我悬停时滚动非活动窗口"（Windows 设置）后重启：未点击时滚轮不到贴图，
  点击一次后该贴图可缩放；创建贴图时原应用焦点仍不变。设置回来后再重启，悬停缩放恢复。
- 4K 源图放大到 32 MP 上限再回到 100%：触顶不报错、不移动窗口；回到 100% 后展示缓冲
  释放，工作集回落；任务管理器记录的源图/展示字节不超过两个 256 MB 预算。
- 用第三方工具清除 `WS_EX_TOPMOST` 后切换前台窗口：自愈钩子把贴图重新放回置顶带，
  日志出现一次 `[pin] restoring topmost band`。
- 关闭最后一张贴图后确认钩子已卸载；关闭与新贴图并发时不出现"无自愈"的贴图。

### 10.3 平台边界

macOS/Linux 只跑 `cargo check` 与 `pnpm build`；其贴图仍走 WebView，
不声称全局 Esc 可用。Wayland 的降级文案保持现状。
