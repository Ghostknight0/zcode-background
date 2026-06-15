# ZCode 背景注入工具

> 🪟 **仅支持 Windows**（Win10 1607+ / Win11）。依赖 PowerShell 7、.NET Framework、Chrome DevTools Protocol 等 Windows 特有机制，macOS / Linux 无法使用。

给 [ZCode](https://z.ai) 编辑器注入自定义背景的工具。支持**图片**和**视频**背景，支持**目录随机**、**图片视频混合 1:1 轮换**、**运行时定时轮换**、**图片/视频分别设置透明度**。

原理：以远程调试模式启动 ZCode，通过 Chrome DevTools Protocol (CDP) 把一个覆盖层（`<img>` 或 `<video>`）注入到 ZCode 的每个页面里。图片/视频由本地 HTTP 服务（`127.0.0.1`）提供，用 CSS `opacity` 控制透明度。

> ⚠️ **重要**：本工具会**先关闭再重启 ZCode**（因为需要带 `--remote-debugging-port` 启动参数）。运行前请保存好你在 ZCode 里的工作。

---

## 一、运行前提

> 🪟 本工具**仅支持 Windows**（Win10 1607+ / Win11），macOS / Linux 无法使用。

| 依赖 | 说明 | 检查方法 |
|---|---|---|
| **Windows 10 1607+ / Win11** | 依赖 .NET Framework、Windows 注册表、COM 快捷方式接口 | — |
| **ZCode** | 已安装并能正常运行 | — |
| **PowerShell 7 (`pwsh.exe`)** | **必须**。脚本是无 BOM 的 UTF-8，Windows PowerShell 5.1 会乱码崩溃 | 命令行执行 `pwsh -v`，能出版本号即可。没有就到 https://github.com/PowerShell/PowerShell/releases 下载安装 |
| **.NET Framework 4.x** | 用于编译启动器（Win10 1607+/Win11 自带，一般无需操心） | 基本不用管 |

---

## 二、文件清单

```
zcode-background/
├── install-zcode-background-shortcut.ps1   # 一键安装脚本（编译+建快捷方式）
├── zcode-background.ps1                    # 核心逻辑（关ZCode→重启→注入背景）
├── zcode-background-launcher.exe           # 无控制台启动器（预编译成品）
├── zcode-background-launcher.cs            # 启动器源码（安装时会重新编译）
├── assets/
│   ├── sample-background.jpg               # 示例背景图（约 410KB）
│   └── sample-background.mp4               # 示例背景视频（约 2.8MB，赛博朋克公寓）
├── .gitignore
└── README.md                               # 本文档
```

**默认配置**：开箱即用 `assets\` 目录里的示例图片和视频。你也可以换成自己的媒体目录（见下文）。

---

## 三、三种背景模式

| 模式 | 说明 | 媒体来源 |
|---|---|---|
| `random` ⭐ 默认 | 从目录随机抽，**图片视频 1:1 混合**，抽到什么播什么 | `-MediaDirectory` |
| `image` | 固定一张图片（或单个视频）做背景 | `-ImagePath` 或 `-VideoPath` |
| `video` | 从目录随机抽**一个视频** | `-MediaDirectory` |

`random` 模式下，无论目录里图片和视频数量比例如何（比如 883 图 vs 206 视频），**图片和视频出现概率各 50%**，保证两类内容都能看到。

---

## 四、快速开始（3 步）

### 1. 克隆 / 下载本仓库

```bash
git clone <仓库地址> ZCodeBackground
```
或直接下载 zip 解压到一个**固定位置**（比如 `D:\Tools\ZCodeBackground\`）。

> ⚠️ **不要**解压后又移动目录——快捷方式里记录的是绝对路径，移动会导致失效。

### 2. 运行安装脚本（必须用 PowerShell 7）

在解压目录里 **右键空白处 → 打开终端 / PowerShell 7**，执行：

```powershell
# 最简单：一行搞定（自动探测 ZCode + 用包内 assets 示例图片视频）
pwsh -ExecutionPolicy Bypass -File .\install-zcode-background-shortcut.ps1
```

就这样！工具会**自动探测你电脑上的 ZCode 安装路径**，用 `assets\` 里的示例图和视频，`random` 模式混合随机，每 60 分钟换一个。

> 💡 如果自动探测失败（极少数情况），手动指定：`-ZCodePath "C:\你的\ZCode\ZCode.exe"`

成功后桌面会出现 **「ZCode Background」** 快捷方式。

### 3. 双击快捷方式启动

双击桌面快捷方式 → 工具会关闭当前 ZCode → 以调试模式重启 → 启动本地媒体服务 → 注入背景。

> 💡 以后日常使用就**只双击这个快捷方式**，不要再用原来的方式启动 ZCode，否则没有背景。

---

## 五、用你自己的媒体目录

包内 `assets\` 只有一张图和一个视频做演示。想用自己的壁纸库，安装时传 `-MediaDirectory`：

```powershell
pwsh -ExecutionPolicy Bypass -File .\install-zcode-background-shortcut.ps1 `
    -MediaDirectory "E:\你的壁纸库" `
    -Opacity 0.2 `
    -RotateInterval 3600
```

媒体目录里**图片和视频可以混放**，`random` 模式会按 1:1 比例随机抽取。

**支持的格式：**
- 图片：`.jpg .jpeg .png .gif .webp .bmp`
- 视频：`.mp4 .webm .mov .mkv .avi`（推荐 `.mp4 H.264`，兼容性最好）

---

## 六、参数详解

### 安装时参数（传给 install 脚本）

| 参数 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `-ZCodePath` | 可选 | 自动探测 | ZCode.exe 完整路径；不传则自动探测本机安装位置 |
| `-BackgroundMode` | 可选 | `random` | `image` / `random` / `video` 三选一 |
| `-ImagePath` | image 模式用 | `assets\sample-background.jpg` | 固定图片路径 |
| `-MediaDirectory` | random/video 用 | `assets\` | 媒体目录（图片视频可混放） |
| `-Opacity` | 可选 | `0.15` | 通用透明度兜底值（`0.01`～`1.0`），越大越显眼 |
| `-ImageOpacity` | 可选 | 回退到 `-Opacity` | **图片专用透明度**，混合轮换时图片用这个值 |
| `-VideoOpacity` | 可选 | 回退到 `-Opacity` | **视频专用透明度**，混合轮换时视频用这个值 |
| `-RotateInterval` | 可选 | `3600`（60分钟） | 运行时轮换间隔（秒），`0` = 不轮换 |
| `-MediaPort` | 可选 | `9231` | 本地媒体 HTTP 服务端口，被占自动 +1 |

### ZCode 路径自动探测

安装时**不需要手动指定 ZCode 的安装路径**——工具会自动探测，按以下顺序查找（找到即停）：

1. **运行中的 ZCode 进程**（最准）
2. **注册表卸载项**（最通用，DisplayName 含 "ZCode"）
3. **桌面/开始菜单快捷方式**（解析 .lnk 的目标路径）
4. **常见安装目录**（`%LOCALAPPDATA%\Programs\ZCode`、`%ProgramFiles%\ZCode` 等）

只有所有探测源都失败时，才会提示你用 `-ZCodePath` 手动指定。绝大多数情况下你只需一行命令就能完成安装。

### 动态透明度（图片/视频分别设置）

混合随机轮换时，图片和视频可以**用不同的透明度**——视频是动态的通常需要更高透明度才好看，图片是静态的太高了会抢戏：

- 都不传 `-ImageOpacity` / `-VideoOpacity` → 两者都用 `-Opacity` 的值（统一）
- 只传其中一个 → 指定的用指定值，另一个回退到 `-Opacity`
- 两个都传 → 各用各的，轮换切换时自动应用对应透明度

**推荐组合**：
```powershell
-Opacity 0.15 -ImageOpacity 0.15 -VideoOpacity 0.25
```
图片用 0.15（温和），视频用 0.25（明显但不刺眼）。

### 运行时轮换说明

`-RotateInterval` 控制的是**运行时**自动换背景的频率，**不需要重启 ZCode**：

- 值 `> 0`：每隔这么多秒，背景自动从目录换一个新媒体（图片↔视频都可能）
- 值 `= 0`：关闭运行时轮换，仅在每次启动 ZCode 时随机一次

**示例**：
- `-RotateInterval 60` → 每分钟换一个（适合频繁换心情）
- `-RotateInterval 3600` → 每小时换一个（默认，推荐）
- `-RotateInterval 0` → 不轮换，只靠启动随机

> ⚠️ 运行时轮换只在 `random` 和 `video` 模式下生效。`image` 模式是固定单图，轮换无意义。

---

## 七、如何修改参数（安装后）

安装后所有参数都写死在**桌面快捷方式的「目标」属性**里。右键快捷方式 → 属性 → 看「目标」一栏，大概长这样：

```
...\zcode-background-launcher.exe "...\pwsh.exe" "...\zcode-background.ps1" -BackgroundMode random -MediaDirectory "E:\xxx" -ImageOpacity 0.15 -VideoOpacity 0.25 -RotateInterval 3600 -MediaPort 9231
```

### 想换目录
把 `-MediaDirectory "..."` 的路径换掉。

### 想调透明度
**统一调整**：把 `-Opacity "0.15"` 的数字改掉：

| 值 | 效果 |
|---|---|
| `0.05` ~ `0.10` | 很淡，几乎只是个水印感 |
| `0.15` ~ `0.20` | 温和（图片默认） |
| `0.20` ~ `0.35` | 视频背景建议范围 |
| `0.50` ~ `1.0` | 很清楚，可能影响文字阅读 |

**图片/视频分别调**（混合轮换推荐）：在目标栏加上 `-ImageOpacity` 和 `-VideoOpacity`，例如：
```
-Opacity "0.15" -ImageOpacity 0.15 -VideoOpacity 0.25
```

### 想改轮换频率
把 `-RotateInterval 3600` 改成你想要的秒数，或改成 `0` 关闭轮换。

### 想换背景模式
把 `-BackgroundMode random` 改成 `image` 或 `video`，同时配套改 `-MediaDirectory` / `-ImagePath`。

---

## 八、视频背景注意事项

### 支持的视频格式

| 格式 | 浏览器原生播放 | 推荐度 |
|---|---|---|
| `.mp4`（H.264） | ✅ 全平台 | ⭐⭐⭐ 强烈推荐 |
| `.webm`（VP9/VP8） | ✅ 大多数 | ⭐⭐ 推荐 |
| `.mov` | 🟡 部分支持 | ⭐ 一般 |
| `.mkv` / `.avi` | ❌ 多数不行 | 不推荐，抽到会显示空白 |

**建议把视频转成 `.mp4 (H.264)`**，兼容性最好。可以用 ffmpeg：
```bash
ffmpeg -i input.mkv -c:v libx264 -crf 23 -c:a aac output.mp4
```

### 视频背景为什么需要本地 HTTP 服务

视频文件通常几十 MB，不能像图片那样转成 Base64 注入（CDP 消息体装不下）。所以工具会在本地启动一个 HTTP 服务（`127.0.0.1`，只本机访问），由 `<video>` 标签流式加载。这个服务：
- **随 ZCode 启动而启动，随 ZCode 退出而关闭**（不会留孤儿进程）
- 支持 HTTP Range 请求（视频拖动进度条/缓冲必需）
- 只绑定回环地址，**不向局域网公开**

### 为什么选 HTTP 而不是改 ZCode 源码

参考了 VSCode 的 background-cover 类插件，它们需要**修改 VSCode 的源码文件**（`workbench.js`），每次升级都要重做，还会触发"文件已损坏"警告。本工具用 CDP 注入，**不改任何源码文件**，ZCode 升级不受影响。

---

## 九、常见问题

### Q1：双击快捷方式后 ZCode 没出现 / 闪一下就没了

手动验证一下（不会关闭 ZCode）：
```powershell
pwsh -ExecutionPolicy Bypass -File .\zcode-background.ps1 -ValidateOnly
```
加 `-ValidateOnly` 只检查参数，**不会关闭 ZCode**。输出 JSON 说明参数 OK。

### Q2：报「PowerShell 主程序不存在」

没装 PowerShell 7。装好后再运行安装脚本。**不要**用系统自带的 5.1，会因编码问题崩溃。

### Q3：报「媒体目录中没有可用的媒体文件」

`-MediaDirectory` 指的目录里没有支持的文件。检查：
- 图片：`.jpg .jpeg .png .gif .webp .bmp`
- 视频：`.mp4 .webm .mov .mkv .avi`
- 文件是否被 OneDrive/网盘"仅在线"占位（没真正下载到本地）

### Q4：视频背景显示空白 / 不播放

- 视频格式可能是 ZCode 内置浏览器不支持的（如 mkv/avi）→ 转成 mp4
- 在 ZCode 里按 `Ctrl+Shift+I` 打开开发者工具，看 Console 报错

### Q5：背景出现了但每次刷新页面就没了

不会的。脚本用 `Page.addScriptToEvaluateOnNewDocument` 注册了持久注入，导航/刷新都会自动重新铺背景。

### Q6：端口 9231 被占用怎么办

工具会**自动往后找空闲端口**（9232, 9233...），无需手动处理。启动时的输出会显示实际用的端口。

### Q7：HTTP 服务进程残留怎么办

正常情况下服务随 ZCode 退出自动关闭。如果异常残留（比如强制杀进程），任务管理器找名为 `pwsh.exe` 的进程结束即可。

### Q8：怎么彻底卸载

1. 删桌面「ZCode Background」快捷方式
2. 删整个仓库目录
3. ZCode 本身不受影响，下次正常启动即可（只是没背景了）

---

## 十、给开发者/想二次修改的人

### 改注入逻辑

核心注入代码在 `zcode-background.ps1` 的 `New-OverlayJavaScript` 函数。它返回一段 JS 字符串，包含：
- 覆盖层元素创建（根据类型建 `<img>` 或 `<video>`）
- 全屏 CSS 样式（`object-fit: cover`、透明度、`pointer-events: none`）
- 双透明度映射（`opacityByType` + `opacityFor(type)` 函数）
- 轮换定时器（`setInterval` 定时 `fetch("/random")` 拿新媒体）
- 图↔视频切换时的元素销毁重建 + 透明度自动切换

改 CSS 就能调整覆盖层行为（比如改 `object-fit` 为 `contain`，加 `filter: blur()` 模糊等）。

### 改随机抽取逻辑

`random` 模式 1:1 比例的实现：
- `Get-RandomMediaFromDirectory`（ps1 函数）—— 启动时初始抽取
- HTTP 服务 `/random` 端点的 `_PickRandom`（在 `Start-MediaHttpServer` 内）—— 运行时轮换抽取

两处都是"先 50/50 抛硬币选类型，再从对应池选一个文件"。想改比例可以调整这里的逻辑。

### 改 HTTP 服务

`Start-MediaHttpServer` 函数实现了媒体 HTTP 服务，支持：
- `GET /<文件名>` —— 流式返回文件，支持 Range（206）
- `GET /random` —— 返回随机媒体 JSON（含 fileName 和 type）
- `GET /health` —— 存活探测
- 路径穿越防护（拒绝 `../` 越权访问）

### 改启动器

`zcode-background-launcher.cs` 是个 ~113 行的 C# 程序，作用是无控制台地拉起 pwsh。改完源码后，安装脚本会自动重新编译。

### 安全说明

- CDP 调试只绑定 `127.0.0.1`（回环），不向局域网开放
- 媒体 HTTP 服务也只绑定 `127.0.0.1`
- 脚本只终止名为 `ZCode` 的进程，不碰其他程序
- HTTP 服务有路径穿越防护，无法通过 `../` 访问目录外文件

---

## 十一、版本与致谢

- 工具版本：2.0
- 适用 ZCode：当前发行版（基于 Chromium/Electron）
- 视频背景实现参考：[VSCode background-cover](https://github.com/AShujiao/vscode-background-cover) 插件、[掘金：黑神话悟空视频背景](https://juejin.cn/post/7405464212958642227)
- 示例素材：背景图来自游民星空（gamersky），示例视频为赛博朋克风格（MoeWalls），仅作演示，商用请替换为自有素材
