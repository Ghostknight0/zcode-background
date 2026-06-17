[CmdletBinding()]
param(
    # 中文文件名会被本机桌面策略删除，因此默认使用稳定的英文入口名。
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath("Desktop")) "ZCode Background.lnk"),

    # 背景启动脚本默认与本安装脚本放在同一目录。
    [string]$LauncherPath = (Join-Path $PSScriptRoot "zcode-background.ps1"),

    # 背景模式：image（固定单图）/ random（目录混合随机）/ video（目录随机视频）。
    [ValidateSet("image", "random", "video")]
    [string]$BackgroundMode = "random",

    # image 模式：固定图片路径；默认指向脚本同级 assets 示例图。
    [string]$ImagePath = (Join-Path $PSScriptRoot "assets\sample-background.jpg"),

    # random / video 模式：媒体目录（图片视频可混放）；默认指向脚本同级 assets。
    [string]$MediaDirectory = (Join-Path $PSScriptRoot "assets"),

    # 写入快捷方式的背景透明度（兜底默认值）；图片/视频可分别用下面两个参数覆盖。
    [ValidateRange(0.01, 1.0)]
    [double]$Opacity = 0.15,

    # 图片背景透明度；未指定（<=0）时回退到 $Opacity。
    [ValidateRange(0, 1.0)]
    [double]$ImageOpacity = 0,

    # 视频背景透明度；未指定（<=0）时回退到 $Opacity。
    [ValidateRange(0, 1.0)]
    [double]$VideoOpacity = 0,

    # 运行时轮换间隔（秒），默认 60 分钟；0 = 不轮换。
    [ValidateRange(0, 86400)]
    [int]$RotateInterval = 3600,

    # 本地媒体 HTTP 服务起始端口；被占用自动 +1。
    [ValidateRange(1, 65535)]
    [int]$MediaPort = 9231,

    # 无控制台启动器源码和编译产物默认与安装脚本放在同一目录。
    [string]$NativeLauncherSourcePath = (Join-Path $PSScriptRoot "zcode-background-launcher.cs"),

    [string]$NativeLauncherPath = (Join-Path $PSScriptRoot "zcode-background-launcher.exe"),

    # 快捷方式使用 ZCode 主程序自身的应用图标。
    # 留空（默认）时自动探测本机 ZCode 安装路径。
    [string]$ZCodePath = "",

    # 可手动指定 PowerShell；留空时优先选择 PowerShell 7。
    [string]$PowerShellPath = "",

    # 可手动指定 C# compiler；留空时使用系统 .NET Framework 64 位版本。
    [string]$CSharpCompilerPath = ""
)

$ErrorActionPreference = "Stop"

function Find-ZCodeInstallation {
    # 自动探测本机 ZCode 安装路径。多源回退，找到即返回 ZCode.exe 完整路径。
    # 探测顺序（从最可靠到最兜底）：运行中进程 → 注册表卸载项 → 桌面/开始菜单快捷方式 → 常见安装目录。

    # 1. 运行中的 ZCode 进程（最准，但需要 ZCode 正在运行）。
    $proc = Get-Process -Name "ZCode" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        try {
            $procPath = $proc.Path
            if ($procPath -and (Test-Path -LiteralPath $procPath -PathType Leaf)) {
                return $procPath
            }
        } catch {
            # 进程权限不足读不到路径，继续尝试其他源。
        }
    }

    # 2. 注册表卸载项（最通用，安装版基本都有）。
    # DisplayName 含 "ZCode"，从 DisplayIcon / UninstallString 反推安装目录。
    $regRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $regRoots) {
        if (-not (Test-Path $root)) { continue }
        $entries = Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        } | Where-Object { $_.DisplayName -match "ZCode" }
        foreach ($entry in $entries) {
            # DisplayIcon / UninstallString 通常指向安装目录下的文件，取同目录的 ZCode.exe。
            foreach ($propName in @("DisplayIcon", "UninstallString", "InstallLocation")) {
                $val = $entry.$propName
                if (-not $val) { continue }
                # 去掉引号和参数，提取路径主体。
                $cleaned = $val.Trim('"').Trim()
                # 取目录部分（如果是文件路径）或本身（如果是 InstallLocation）。
                $dir = if (Test-Path $cleaned -PathType Container) { $cleaned }
                       elseif (Test-Path $cleaned -PathType Leaf) { Split-Path -Parent $cleaned }
                       else {
                           # 可能带参数，取第一个 token 的目录。
                           $firstToken = ($cleaned -split '\s+')[0].Trim('"')
                           if (Test-Path $firstToken -PathType Leaf) { Split-Path -Parent $firstToken }
                       }
                if ($dir) {
                    $candidate = Join-Path $dir "ZCode.exe"
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                        return $candidate
                    }
                }
            }
        }
    }

    # 3. 桌面 / 开始菜单快捷方式。
    $lnkDirs = @(
        [Environment]::GetFolderPath("Desktop"),
        [Environment]::GetFolderPath("CommonDesktopDirectory"),
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"),
        (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs")
    )
    foreach ($dir in $lnkDirs) {
        if (-not (Test-Path $dir)) { continue }
        $lnks = Get-ChildItem $dir -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "ZCode" }
        foreach ($lnk in $lnks) {
            try {
                $sh = New-Object -ComObject WScript.Shell
                $target = $sh.CreateShortcut($lnk.FullName).TargetPath
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($sh)
                if ($target -and $target -match "ZCode\.exe$" -and (Test-Path -LiteralPath $target -PathType Leaf)) {
                    return $target
                }
            } catch {}
        }
    }

    # 4. 常见安装目录（兜底）。
    $commonDirs = @(
        (Join-Path $env:LOCALAPPDATA "Programs\ZCode"),
        (Join-Path $env:ProgramFiles "ZCode"),
        (Join-Path ${env:ProgramFiles(x86)} "ZCode"),
        (Join-Path $env:APPDATA "ZCode")
    )
    foreach ($dir in $commonDirs) {
        $candidate = Join-Path $dir "ZCode.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

try {
    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
        throw "背景启动脚本不存在：$LauncherPath"
    }

    # 按模式校验资源：
    #   image + 传了 MediaDirectory → 校验目录（轮换图片模式）
    #   image + 未传 MediaDirectory → 校验 ImagePath（固定单文件，向后兼容）
    #   random/video → 校验 MediaDirectory
    $resolvedMediaPath = ""
    if ($BackgroundMode -eq "image" -and [string]::IsNullOrWhiteSpace($MediaDirectory)) {
        if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
            throw "背景图片不存在：$ImagePath"
        }
        $resolvedMediaPath = (Resolve-Path -LiteralPath $ImagePath).Path
    }
    else {
        if ([string]::IsNullOrWhiteSpace($MediaDirectory)) {
            throw "$BackgroundMode 模式必须指定 -MediaDirectory 参数。"
        }
        if (-not (Test-Path -LiteralPath $MediaDirectory -PathType Container)) {
            throw "媒体目录不存在：$MediaDirectory"
        }
    }

    if (-not (Test-Path -LiteralPath $NativeLauncherSourcePath -PathType Leaf)) {
        throw "无控制台启动器源码不存在：$NativeLauncherSourcePath"
    }

    # ZCode 路径：未指定或不存在时自动探测本机安装位置。
    if ([string]::IsNullOrWhiteSpace($ZCodePath) -or -not (Test-Path -LiteralPath $ZCodePath -PathType Leaf)) {
        if (-not [string]::IsNullOrWhiteSpace($ZCodePath)) {
            Write-Warning "指定的 ZCode 路径不存在，尝试自动探测：$ZCodePath"
        }
        $detected = Find-ZCodeInstallation
        if ($detected) {
            $ZCodePath = $detected
            Write-Host "已自动探测到 ZCode：$ZCodePath"
        } else {
            throw "未找到 ZCode 安装路径。请用 -ZCodePath 参数手动指定 ZCode.exe 的完整路径。"
        }
    }

    if (-not (Test-Path -LiteralPath $ZCodePath -PathType Leaf)) {
        throw "ZCode 主程序不存在：$ZCodePath"
    }

    if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
        $powerShellCommand = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
        if (-not $powerShellCommand) {
            $powerShellCommand = Get-Command "powershell.exe" -ErrorAction Stop
        }
        $PowerShellPath = $powerShellCommand.Source
    }

    if (-not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) {
        throw "PowerShell 主程序不存在：$PowerShellPath"
    }

    if ([string]::IsNullOrWhiteSpace($CSharpCompilerPath)) {
        $compilerCandidates = @(
            (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
            (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
        )
        $CSharpCompilerPath = $compilerCandidates |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
    }

    if (-not (Test-Path -LiteralPath $CSharpCompilerPath -PathType Leaf)) {
        throw "C# compiler 不存在：$CSharpCompilerPath"
    }

    $resolvedLauncherPath = (Resolve-Path -LiteralPath $LauncherPath).Path
    $resolvedMediaDirectory = if ($MediaDirectory) { (Resolve-Path -LiteralPath $MediaDirectory).Path } else { "" }
    $resolvedNativeLauncherSourcePath = (Resolve-Path -LiteralPath $NativeLauncherSourcePath).Path
    $resolvedZCodePath = (Resolve-Path -LiteralPath $ZCodePath).Path
    $resolvedPowerShellPath = (Resolve-Path -LiteralPath $PowerShellPath).Path
    $resolvedCSharpCompilerPath = (Resolve-Path -LiteralPath $CSharpCompilerPath).Path
    $resolvedNativeLauncherPath = [IO.Path]::GetFullPath($NativeLauncherPath)
    $opacityLiteral = $Opacity.ToString(
        "0.################",
        [Globalization.CultureInfo]::InvariantCulture
    )
    # 构造双透明度参数片段：仅当指定了 ImageOpacity/VideoOpacity（>0）时才加入，避免无谓传参。
    $opacityArgs = "-Opacity `"$opacityLiteral`""
    if ($ImageOpacity -gt 0) {
        $opacityArgs += " -ImageOpacity $ImageOpacity"
    }
    if ($VideoOpacity -gt 0) {
        $opacityArgs += " -VideoOpacity $VideoOpacity"
    }
    $nativeLauncherDirectory = Split-Path -Parent $resolvedNativeLauncherPath
    $shortcutDirectory = Split-Path -Parent $ShortcutPath

    if (-not (Test-Path -LiteralPath $nativeLauncherDirectory -PathType Container)) {
        # 用户可把编译产物放到自定义目录，安装时自动补齐目录。
        New-Item -ItemType Directory -Path $nativeLauncherDirectory -Force | Out-Null
    }

    $sourceWriteTime = (Get-Item -LiteralPath $resolvedNativeLauncherSourcePath).LastWriteTimeUtc
    $needsLauncherBuild = (
        -not (Test-Path -LiteralPath $resolvedNativeLauncherPath -PathType Leaf) -or
        (Get-Item -LiteralPath $resolvedNativeLauncherPath).LastWriteTimeUtc -lt $sourceWriteTime
    )

    if ($needsLauncherBuild) {
        # /target:winexe 让启动器自身没有控制台，再由它隐藏启动 PowerShell。
        Remove-Item -LiteralPath $resolvedNativeLauncherPath -Force -ErrorAction SilentlyContinue
        $compilerOutput = & $resolvedCSharpCompilerPath `
            "/nologo" `
            "/target:winexe" `
            "/optimize+" `
            "/out:$resolvedNativeLauncherPath" `
            $resolvedNativeLauncherSourcePath 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "无控制台启动器编译失败：$($compilerOutput -join [Environment]::NewLine)"
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedNativeLauncherPath -PathType Leaf)) {
        throw "无控制台启动器构建失败：$resolvedNativeLauncherPath"
    }

    if (-not (Test-Path -LiteralPath $shortcutDirectory -PathType Container)) {
        # 支持测试目录或用户指定目录尚未创建的情况。
        New-Item -ItemType Directory -Path $shortcutDirectory -Force | Out-Null
    }

    # 按模式构造 Arguments：
    #   image + 传了 MediaDirectory → 从目录轮换图片
    #   image + 未传 MediaDirectory → 固定单文件（向后兼容）
    #   random/video → 从 MediaDirectory 随机
    $modeArgs = if ($BackgroundMode -eq "image" -and [string]::IsNullOrWhiteSpace($MediaDirectory)) {
        "-BackgroundMode image -ImagePath `"$resolvedMediaPath`""
    } else {
        "-BackgroundMode $BackgroundMode -MediaDirectory `"$resolvedMediaDirectory`""
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $resolvedNativeLauncherPath
    $shortcut.Arguments = (
        "`"$resolvedPowerShellPath`" " +
        "`"$resolvedLauncherPath`" " +
        "$modeArgs " +
        "$opacityArgs " +
        "-RotateInterval $RotateInterval " +
        "-MediaPort $MediaPort"
    )
    $shortcut.WorkingDirectory = Split-Path -Parent $resolvedLauncherPath
    $shortcut.IconLocation = "$resolvedZCodePath,0"
    $shortcut.Description = "无控制台启动带可配置背景的 ZCode（模式：$BackgroundMode）"
    # native launcher 是 Windows GUI 程序，普通窗口样式不会影响 ZCode 编辑器窗口。
    $shortcut.WindowStyle = 1
    $shortcut.Save()

    # 主动释放 COM 对象，确保快捷方式在脚本退出前完成落盘。
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)

    Write-Host "已创建 ZCode 背景版快捷方式：$ShortcutPath"
    Write-Host "背景模式：$BackgroundMode"
    if ($BackgroundMode -eq "image") {
        Write-Host "图片：$resolvedMediaPath"
    }
    else {
        Write-Host "媒体目录：$resolvedMediaDirectory"
    }
    if ($ImageOpacity -gt 0 -and $VideoOpacity -gt 0) {
        Write-Host "透明度：图片 $ImageOpacity / 视频 $VideoOpacity"
    } else {
        Write-Host "透明度：$Opacity（图片视频统一）"
    }
    Write-Host "轮换间隔：$(if ($RotateInterval -gt 0) { "$RotateInterval 秒" } else { "关闭" })"
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
