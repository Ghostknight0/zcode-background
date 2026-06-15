# ZCode 背景注入工具

> 🪟 仅支持 **Windows 10 1607+ / Win11** | 需要 PowerShell 7 + ZCode

给 [ZCode](https://z.ai) 编辑器注入自定义背景：支持图片/视频、目录随机、图片视频 1:1 混合轮换、运行时定时换背景、图片/视频分别设透明度。

---

## 🚀 快速开始

```powershell
# 1. 克隆或下载本仓库到固定位置（不要解压后又移动）
git clone <仓库地址> ZCodeBackground && cd ZCodeBackground

# 2. 用 PowerShell 7 一行安装（自动探测 ZCode，用包内示例素材）
pwsh -ExecutionPolicy Bypass -File .\install-zcode-background-shortcut.ps1

# 3. 双击桌面的「ZCode Background」快捷方式启动
```

就这三步。工具会自动找到你电脑上的 ZCode，用 `assets\` 里的示例图片视频，`random` 模式混合随机，每 60 分钟换一个。

> 💡 自动探测失败（极少数情况）时手动指定：`-ZCodePath "C:\...\ZCode.exe"`

> ⚠️ 工具会**先关闭再重启 ZCode**（需带调试端口启动）。运行前请保存工作。

---

## 三种背景模式

| 模式 | 说明 |
|---|---|
| `random` ⭐ 默认 | 从目录随机抽，**图片视频 1:1 混合**（无论数量比例，各 50% 概率） |
| `image` | 固定一张图片或单个视频 |
| `video` | 从目录随机抽视频 |

## 用自己的媒体库

```powershell
pwsh -ExecutionPolicy Bypass -File .\install-zcode-background-shortcut.ps1 `
    -MediaDirectory "E:\你的壁纸库" `
    -ImageOpacity 0.15 -VideoOpacity 0.25
```

图片视频可混放同一目录。支持格式：图片 `.jpg .jpeg .png .gif .webp .bmp`，视频 `.mp4 .webm .mov .mkv .avi`（推荐 `.mp4 H.264`）。

---

## 参数说明

安装时传给 install 脚本，或安装后改快捷方式「目标」栏：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-ZCodePath` | 自动探测 | ZCode.exe 路径；不传则自动探测（进程→注册表→快捷方式→常见目录） |
| `-BackgroundMode` | `random` | `image` / `random` / `video` |
| `-MediaDirectory` | `assets\` | 媒体目录（图片视频可混放） |
| `-Opacity` | `0.15` | 通用透明度兜底值 |
| `-ImageOpacity` | 回退 Opacity | 图片专用透明度 |
| `-VideoOpacity` | 回退 Opacity | 视频专用透明度 |
| `-RotateInterval` | `3600` | 运行时轮换间隔（秒），`0` = 不轮换 |
| `-MediaPort` | `9231` | 媒体 HTTP 端口，被占自动 +1 |

**透明度参考**：图片建议 `0.15`（温和），视频建议 `0.25`（明显）。混合轮换时用 `-ImageOpacity`/`-VideoOpacity` 分别设置，切换时自动应用。

**轮换说明**：`-RotateInterval > 0` 时背景定时自动换（**不重启 ZCode**），仅 `random`/`video` 模式生效。

---

## 常见问题

| 问题 | 解决 |
|---|---|
| ZCode 没出现/闪退 | `pwsh -File .\zcode-background.ps1 -ValidateOnly` 验证参数（不会关 ZCode） |
| 报「PowerShell 不存在」 | 装 PowerShell 7（不要用 5.1，会乱码） |
| 报「媒体目录无文件」 | 检查目录格式/文件是否仅在线（OneDrive 占位） |
| 视频空白不播放 | 多半格式问题（mkv/avi），转成 mp4；`Ctrl+Shift+I` 看 Console |
| 端口 9231 被占 | 自动往后找，无需处理 |
| HTTP 进程残留 | 任务管理器结束 `pwsh.exe` |
| 卸载 | 删快捷方式 + 删仓库目录，ZCode 不受影响 |

---

## 技术细节（给开发者）

- **核心脚本** `zcode-background.ps1`：CDP 注入 + HTTP 服务 + 轮换逻辑
  - `New-OverlayJavaScript`：生成注入 JS（覆盖层创建/双透明度/轮换定时器）
  - `Start-MediaHttpServer`：本地 HTTP 服务（支持 Range、`/random` 端点、路径穿越防护）
  - `Get-RandomMediaFromDirectory` + `/random` 的 `_PickRandom`：1:1 比例抽取（先抛硬币选类型再选文件）
- **启动器** `zcode-background-launcher.cs`：~113 行 C#，无控制台拉起 pwsh，改源码后安装脚本自动重编译
- **安全**：CDP 和 HTTP 都只绑 `127.0.0.1`；只终止 `ZCode` 进程；HTTP 有路径穿越防护

视频背景实现参考：[VSCode background-cover](https://github.com/AShujiao/vscode-background-cover)、[掘金：黑神话悟空视频背景](https://juejin.cn/post/7405464212958642227)。

---

## 致谢

- 工具版本：2.0
- 示例素材：背景图来自游民星空（gamersky），示例视频为赛博朋克风格（MoeWalls），仅作演示，商用请替换
