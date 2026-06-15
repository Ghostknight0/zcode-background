[CmdletBinding()]
param(
    # 背景模式：image（固定单图）/ random（目录混合随机）/ video（目录随机视频）。
    [ValidateSet("image", "random", "video")]
    [string]$BackgroundMode = "random",

    # 固定图片路径（image 模式用）；默认指向脚本同级的 assets 示例图。
    [string]$ImagePath = (Join-Path $PSScriptRoot "assets\sample-background.jpg"),

    # 媒体目录（random / video 模式用，图片视频可混放同一目录）；默认指向脚本同级 assets。
    [string]$MediaDirectory = (Join-Path $PSScriptRoot "assets"),

    # 固定视频路径（可选；image 模式下想直接放视频时用）。
    [string]$VideoPath,

    # 运行时轮换间隔（秒），默认 60 分钟；0 表示不轮换，仅在启动时随机一次。
    [ValidateRange(0, 86400)]
    [int]$RotateInterval = 3600,

    # 覆盖层透明度（兜底默认值）；图片/视频可分别用下面两个参数覆盖。
    [ValidateRange(0.01, 1.0)]
    [double]$Opacity = 0.15,

    # 图片背景透明度；未指定（<=0）时回退到 $Opacity。
    [ValidateRange(0, 1.0)]
    [double]$ImageOpacity = 0,

    # 视频背景透明度；未指定（<=0）时回退到 $Opacity。
    [ValidateRange(0, 1.0)]
    [double]$VideoOpacity = 0,

    # ZCode 使用的本地 Chrome DevTools Protocol 端口。
    [ValidateRange(1, 65535)]
    [int]$DebugPort = 9230,

    # 本地媒体 HTTP 服务起始端口；被占用则自动 +1 寻找空闲端口。
    [ValidateRange(1, 65535)]
    [int]$MediaPort = 9231,

    # 本机 ZCode 主程序路径，可在安装位置变化后手动覆盖。
    [string]$ZCodePath = "D:\ProgramFiles\ZCode\ZCode.exe",

    # 仅验证参数和资源，不关闭或启动 ZCode。
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"

# 支持的媒体扩展名分类。
$script:ImageExtensions = @(".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp")
$script:VideoExtensions = @(".mp4", ".webm", ".mov", ".mkv", ".avi")

function Get-MediaMimeType {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # 根据扩展名返回浏览器/HTTP 可识别的 MIME 类型。
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".jpg"  { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".png"  { return "image/png" }
        ".gif"  { return "image/gif" }
        ".webp" { return "image/webp" }
        ".bmp"  { return "image/bmp" }
        ".mp4"  { return "video/mp4" }
        ".webm" { return "video/webm" }
        ".mov"  { return "video/quicktime" }
        ".mkv"  { return "video/x-matroska" }
        ".avi"  { return "video/x-msvideo" }
        default { throw "不支持的媒体格式：$([IO.Path]::GetExtension($Path))" }
    }
}

function Get-ImageMimeType {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # 旧函数保留，委托给统一的 Get-MediaMimeType。
    return Get-MediaMimeType -Path $Path
}

function ConvertTo-ImageDataUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$MimeType
    )

    # 使用 Data URL 直接注入页面（旧逻辑保留，image 模式回退或 ValidateOnly 摘要用）。
    $bytes = [IO.File]::ReadAllBytes($Path)
    $base64 = [Convert]::ToBase64String($bytes)
    return "data:$MimeType;base64,$base64"
}

function Get-MediaType {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # 按扩展名判定媒体类型。
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($script:ImageExtensions -contains $ext) { return "image" }
    if ($script:VideoExtensions -contains $ext) { return "video" }
    return $null
}

function Get-RandomMediaFromDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [ValidateSet("random", "video")]
        [string]$Mode
    )

    # 构建候选池，按类型分组。
    $files = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction Stop)
    $imagePool = @()
    $videoPool = @()
    foreach ($f in $files) {
        $type = Get-MediaType -Path $f.FullName
        if (-not $type) { continue }
        $entry = [pscustomobject]@{
            Path     = $f.FullName
            Type     = $type
            FileName = $f.Name
        }
        if ($type -eq "video") { $videoPool += $entry }
        else { $imagePool += $entry }
    }

    # video 模式：只用视频池。
    if ($Mode -eq "video") {
        if ($videoPool.Count -eq 0) {
            throw "媒体目录中没有可用的视频文件：$Directory"
        }
        return ($videoPool | Get-Random)
    }

    # random 模式：图片视频 1:1 比例（先 50/50 选类型，再从对应池随机选一个）。
    # 这样无论目录里图片视频数量悬殊多少，每种类型出现概率都是 50%。
    # 某一类为空时自动回退到另一类。
    if ($imagePool.Count -eq 0 -and $videoPool.Count -eq 0) {
        throw "媒体目录中没有可用的媒体文件：$Directory"
    }
    if ($imagePool.Count -eq 0) { return ($videoPool | Get-Random) }
    if ($videoPool.Count -eq 0) { return ($imagePool | Get-Random) }

    # 两类都有：抛硬币决定类型。
    if ((Get-Random -Maximum 2) -eq 0) {
        return ($imagePool | Get-Random)
    }
    return ($videoPool | Get-Random)
}

function Find-AvailableMediaPort {
    param(
        [Parameter(Mandatory)]
        [int]$StartPort,

        [int]$MaxAttempts = 100
    )

    # 从起始端口开始，逐个尝试绑定 TCP 监听以确认端口空闲。
    # 用 TcpListener 真实绑定比查询连接表更可靠（避免 TOCTOU）。
    for ($offset = 0; $offset -lt $MaxAttempts; $offset++) {
        $port = $StartPort + $offset
        if ($port -gt 65535) { break }
        $listener = $null
        try {
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
            $listener.Start()
            return $port
        }
        catch {
            # 端口被占用，继续尝试下一个。
        }
        finally {
            if ($listener) {
                try { $listener.Stop() } catch {}
            }
        }
    }

    throw "在 $StartPort 起的 $MaxAttempts 个端口范围内未找到空闲端口。"
}

function Start-MediaHttpServer {
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        [Parameter(Mandatory)]
        [string]$Directory,

        [ValidateSet("random", "video", "none")]
        [string]$RandomMode = "none"
    )

    # 启动一个绑定 127.0.0.1 的本地 HTTP 服务：
    #   GET /<文件名>      → 流式返回该文件，支持 Range 请求（视频 seek 必需）
    #   GET /random        → 返回一个随机媒体文件的 JSON 描述（供覆盖层轮换用）
    #   GET /health        → 返回 200，用于存活探测
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $listener.Start()

    # 用后台 Runspace 处理请求，避免阻塞主线程（主线程要等 ZCode 退出）。
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript({
        param($Listener, $Directory, $ImgExt, $VidExt, $RandomMode)

        $script:ImageExtensions = $ImgExt
        $script:VideoExtensions = $VidExt

        function _MediaType($Path) {
            $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
            if ($script:ImageExtensions -contains $ext) { return "image" }
            if ($script:VideoExtensions -contains $ext) { return "video" }
            return $null
        }

        function _PickRandom {
            $files = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue)
            $imagePool = @()
            $videoPool = @()
            foreach ($f in $files) {
                $type = _MediaType $f.FullName
                if (-not $type) { continue }
                $entry = [pscustomobject]@{
                    fileName = $f.Name
                    type     = $type
                }
                if ($type -eq "video") { $videoPool += $entry }
                else { $imagePool += $entry }
            }

            # video 模式：只用视频池。
            if ($RandomMode -eq "video") {
                if ($videoPool.Count -eq 0) { return $null }
                return ($videoPool | Get-Random)
            }

            # random 模式：图片视频 1:1（先 50/50 选类型，再从对应池选一个）。
            # 某一类为空时回退到另一类。
            if ($imagePool.Count -eq 0 -and $videoPool.Count -eq 0) { return $null }
            if ($imagePool.Count -eq 0) { return ($videoPool | Get-Random) }
            if ($videoPool.Count -eq 0) { return ($imagePool | Get-Random) }

            if ((Get-Random -Maximum 2) -eq 0) {
                return ($imagePool | Get-Random)
            }
            return ($videoPool | Get-Random)
        }

        # 主请求循环：持续 Accept 直到 listener 被外部 Stop。
        while ($Listener.IsListening) {
            $context = $null
            try {
                # 同步 Accept；listener.Stop() 会让此调用抛 ObjectDisposedException，正常退出。
                $context = $Listener.GetContext()
            }
            catch {
                break
            }

            try {
                $req = $context.Request
                $res = $context.Response
                $rawUrl = $req.Url.AbsolutePath.TrimStart("/")

                # URL 解码（文件名可能含中文/空格）。
                $decoded = [Uri]::UnescapeDataString($rawUrl)

                if ($decoded -eq "health") {
                    $res.StatusCode = 200
                    $res.Close()
                    continue
                }

                if ($decoded -eq "random") {
                    $picked = _PickRandom
                    if (-not $picked) {
                        $res.StatusCode = 404
                        $res.Close()
                        continue
                    }
                    $json = @{
                        fileName = $picked.fileName
                        type     = $picked.type
                    } | ConvertTo-Json -Compress
                    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = "application/json; charset=utf-8"
                    $res.ContentLength64 = $bytes.Length
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                    $res.Close()
                    continue
                }

                # 普通文件请求：严格限定在目录内，防止路径穿越（../ 之类）。
                # 使用 GetFullPath 规范化后再比对根目录前缀。
                $fullPath = [IO.Path]::GetFullPath([IO.Path]::Combine($Directory, $decoded))
                $rootNorm = [IO.Path]::GetFullPath($Directory).TrimEnd('\') + '\'
                if (-not $fullPath.StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) {
                    $res.StatusCode = 403
                    $res.Close()
                    continue
                }
                if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                    $res.StatusCode = 404
                    $res.Close()
                    continue
                }

                $fileInfo = Get-Item -LiteralPath $fullPath
                $total = $fileInfo.Length

                # 处理 Range 请求（视频 seek / 分段缓冲必需）。
                $rangeHeader = $req.Headers["Range"]
                $start = 0L
                $end = $total - 1
                $hasRange = $false

                if ($rangeHeader -and $rangeHeader -match "bytes=(\d*)-(\d*)") {
                    $rStart = $Matches[1]
                    $rEnd = $Matches[2]
                    if ($rStart) { $start = [int64]$rStart }
                    if ($rEnd) { $end = [int64]$rEnd }
                    if ($end -ge $total) { $end = $total - 1 }
                    $hasRange = $true
                }

                if ($hasRange) {
                    $res.StatusCode = 206
                    $res.Headers["Content-Range"] = "bytes $start-$end/$total"
                }
                else {
                    $res.StatusCode = 200
                }

                $length = $end - $start + 1
                $res.ContentLength64 = $length

                try {
                    $mime = switch ([IO.Path]::GetExtension($fullPath).ToLowerInvariant()) {
                        ".jpg"  { "image/jpeg" }
                        ".jpeg" { "image/jpeg" }
                        ".png"  { "image/png" }
                        ".gif"  { "image/gif" }
                        ".webp" { "image/webp" }
                        ".bmp"  { "image/bmp" }
                        ".mp4"  { "video/mp4" }
                        ".webm" { "video/webm" }
                        ".mov"  { "video/quicktime" }
                        ".mkv"  { "video/x-matroska" }
                        ".avi"  { "video/x-msvideo" }
                        default { "application/octet-stream" }
                    }
                    $res.ContentType = $mime
                }
                catch {
                    $res.ContentType = "application/octet-stream"
                }

                # 流式写入文件内容，避免大视频一次性读入内存。
                $stream = [IO.File]::OpenRead($fullPath)
                try {
                    if ($start -gt 0) { $stream.Seek($start, [IO.SeekOrigin]::Begin) | Out-Null }
                    $remaining = $length
                    $buffer = [byte[]]::new(65536)
                    while ($remaining -gt 0) {
                        $toRead = [Math]::Min($buffer.Length, $remaining)
                        $read = $stream.Read($buffer, 0, $toRead)
                        if ($read -le 0) { break }
                        $res.OutputStream.Write($buffer, 0, $read)
                        $remaining -= $read
                    }
                }
                finally {
                    $stream.Dispose()
                }
                $res.Close()
            }
            catch {
                try {
                    $context.Response.StatusCode = 500
                    $context.Response.Close()
                } catch {}
            }
        }
    }).AddArgument($listener).AddArgument($Directory).AddArgument($script:ImageExtensions).AddArgument($script:VideoExtensions).AddArgument($RandomMode)

    $handle = $ps.BeginInvoke()

    return [pscustomobject]@{
        Listener   = $listener
        PowerShell = $ps
        Handle     = $handle
        Port       = $Port
    }
}

function Stop-MediaHttpServer {
    param(
        [Parameter(Mandatory)]
        $Server
    )

    # 顺序：停 listener（让 GetContext 抛异常退出循环）→ 等 runspace 结束 → 清理。
    if ($Server.Listener) {
        try { $Server.Listener.Stop() } catch {}
        try { $Server.Listener.Close() } catch {}
    }
    if ($Server.PowerShell) {
        try {
            if ($Server.Handle) {
                $Server.PowerShell.EndInvoke($Server.Handle)
            }
        }
        catch {
            # listener 关闭时 runspace 抛异常属于预期，忽略。
        }
        try { $Server.PowerShell.Dispose() } catch {}
    }
}

function Stop-ZCodeProcesses {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath
    )

    $processes = @(Get-Process -Name "ZCode" -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        return
    }

    Write-Host "正在关闭当前 ZCode..."

    # 优先请求主窗口正常退出，让 ZCode 有机会保存界面状态。
    foreach ($process in $processes) {
        if ($process.MainWindowHandle -ne 0) {
            [void]$process.CloseMainWindow()
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-Process -Name "ZCode" -ErrorAction SilentlyContinue)
    } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        # 用户已允许脚本自动重启 ZCode；只终止同名 ZCode 进程，不操作其他程序。
        $remaining | Stop-Process -Force -ErrorAction Stop
        Wait-Process -Id $remaining.Id -Timeout 10 -ErrorAction SilentlyContinue
    }

    if (Get-Process -Name "ZCode" -ErrorAction SilentlyContinue) {
        throw "无法完全关闭 ZCode，请手动退出后重试。"
    }
}

function Start-ZCodeWithDebugging {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [int]$Port
    )

    # 调试接口只绑定回环地址，避免向局域网公开 CDP 控制能力。
    $arguments = @(
        "--remote-debugging-address=127.0.0.1",
        "--remote-debugging-port=$Port",
        "--remote-allow-origins=http://127.0.0.1:$Port"
    )

    Write-Host "正在启动 ZCode，CDP 端口：$Port"
    return Start-Process -FilePath $ExecutablePath `
        -ArgumentList $arguments `
        -WorkingDirectory (Split-Path -Parent $ExecutablePath) `
        -PassThru
}

function Wait-CdpTargets {
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        # ZCode 重启后页面加载较慢（恢复会话、初始化插件），给足等待时间。
        [int]$TimeoutSeconds = 90
    )

    $endpoint = "http://127.0.0.1:$Port/json/list"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = $null

    do {
        try {
            $targets = @(Invoke-RestMethod -Uri $endpoint -Method Get -TimeoutSec 2)
            $injectableTargets = @(
                $targets | Where-Object {
                    $_.webSocketDebuggerUrl -and
                    $_.type -in @("page", "webview") -and
                    $_.title -notmatch "DevTools"
                }
            )

            if ($injectableTargets.Count -gt 0) {
                return $injectableTargets
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)

    $detail = if ($lastError) { "；最后错误：$lastError" } else { "" }
    throw "等待 ZCode CDP 页面超时：$endpoint$detail"
}

function Invoke-CdpCommand {
    param(
        [Parameter(Mandatory)]
        [string]$WebSocketUrl,

        [Parameter(Mandatory)]
        [string]$Method,

        [hashtable]$Parameters = @{},

        [int]$CommandId = 1
    )

    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(10))

    try {
        # 每条命令使用独立连接，简化事件帧与响应帧的匹配逻辑。
        $socket.ConnectAsync([Uri]$WebSocketUrl, $cancellation.Token).GetAwaiter().GetResult()

        $payload = [ordered]@{
            id     = $CommandId
            method = $Method
            params = $Parameters
        } | ConvertTo-Json -Compress -Depth 20

        $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $payloadSegment = [ArraySegment[byte]]::new($payloadBytes)
        $socket.SendAsync(
            $payloadSegment,
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $cancellation.Token
        ).GetAwaiter().GetResult()

        do {
            $stream = [IO.MemoryStream]::new()
            try {
                do {
                    $buffer = [byte[]]::new(65536)
                    $bufferSegment = [ArraySegment[byte]]::new($buffer)
                    $receiveResult = $socket.ReceiveAsync(
                        $bufferSegment,
                        $cancellation.Token
                    ).GetAwaiter().GetResult()

                    if ($receiveResult.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                        throw "CDP WebSocket 在返回命令结果前关闭。"
                    }

                    $stream.Write($buffer, 0, $receiveResult.Count)
                } while (-not $receiveResult.EndOfMessage)

                $responseText = [Text.Encoding]::UTF8.GetString($stream.ToArray())
                $response = $responseText | ConvertFrom-Json
            }
            finally {
                $stream.Dispose()
            }
        } while ($response.id -ne $CommandId)

        if ($response.error) {
            throw "CDP 命令失败 [$Method]：$($response.error.message)"
        }

        return $response.result
    }
    finally {
        if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
            try {
                $socket.CloseAsync(
                    [Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    "done",
                    [Threading.CancellationToken]::None
                ).GetAwaiter().GetResult()
            }
            catch {
                # 关闭连接失败不影响已完成的 CDP 命令结果。
            }
        }

        $cancellation.Dispose()
        $socket.Dispose()
    }
}

function New-OverlayJavaScript {
    param(
        [Parameter(Mandatory)]
        [string]$SourceUrl,

        [Parameter(Mandatory)]
        [ValidateSet("image", "video")]
        [string]$MediaType,

        # 图片背景透明度。
        [Parameter(Mandatory)]
        [ValidateRange(0.01, 1.0)]
        [double]$ImageOpacityValue,

        # 视频背景透明度。
        [Parameter(Mandatory)]
        [ValidateRange(0.01, 1.0)]
        [double]$VideoOpacityValue,

        # 是否启用运行时轮换：>0 时覆盖层会定时从 /random 拉取新媒体。
        [int]$RotateSeconds = 0,

        # 媒体基础 URL（不含文件名），用于拼接 /random 返回的 fileName。
        [string]$MediaBaseUrl
    )

    $sourceLiteral = ConvertTo-Json -InputObject $SourceUrl -Compress
    $imageOpacityLiteral = $ImageOpacityValue.ToString(
        "0.################",
        [Globalization.CultureInfo]::InvariantCulture
    )
    $videoOpacityLiteral = $VideoOpacityValue.ToString(
        "0.################",
        [Globalization.CultureInfo]::InvariantCulture
    )
    $typeLiteral = ConvertTo-Json -InputObject $MediaType -Compress
    $rotateLiteral = [int]$RotateSeconds
    $mediaBaseLiteral = ConvertTo-Json -InputObject $MediaBaseUrl -Compress

    # 固定节点 ID 使脚本可以重复执行，并在页面导航后重新安装同一覆盖层。
    # 运行时轮换：定时器每 RotateSeconds 秒请求 /random，拿到新 fileName 后重建覆盖层。
    # 动态透明度：图片和视频分别用不同透明度，按当前媒体类型切换。
    return @"
(() => {
    const overlayId = "zcode-background-overlay";
    let current = { url: $sourceLiteral, type: $typeLiteral };
    // 图片/视频分别的透明度；轮换时按类型自动切换。
    const opacityByType = { image: "$imageOpacityLiteral", video: "$videoOpacityLiteral" };
    const rotate = $rotateLiteral;
    const mediaBase = $mediaBaseLiteral;

    function opacityFor(type) {
        return opacityByType[type] || opacityByType.image;
    }

    // 创建覆盖层元素，图片用 <img>，视频用 <video>。
    // 图↔视频切换需要销毁重建，因为两者是不同的 HTML 标签。
    function createElement(type, url) {
        let el;
        if (type === "video") {
            el = document.createElement("video");
            el.loop = true;
            el.muted = true;
            el.defaultMuted = true;
            el.autoplay = true;
            el.setAttribute("playsinline", "");
            el.setAttribute("webkit-playsinline", "");
            el.setAttribute("aria-hidden", "true");
        } else {
            el = document.createElement("img");
            el.alt = "";
            el.setAttribute("aria-hidden", "true");
        }

        const commonStyle = {
            position: "fixed",
            inset: "0",
            width: "100vw",
            height: "100vh",
            objectFit: "cover",
            objectPosition: "center center",
            opacity: opacityFor(type),
            pointerEvents: "none",
            zIndex: "2147483646",
            userSelect: "none"
        };
        for (const k in commonStyle) {
            el.style[k] = commonStyle[k];
        }
        el.src = url;
        return el;
    }

    function installOverlay() {
        const root = document.documentElement;
        if (!root) return false;

        let image = document.getElementById(overlayId);
        if (image) {
            // 同类型：直接换 src + 同步透明度；不同类型：销毁重建。
            const sameType = (image.tagName.toLowerCase() === current.type);
            if (sameType) {
                image.src = current.url;
                image.style.opacity = opacityFor(current.type);
                return true;
            }
            image.remove();
        }

        const el = createElement(current.type, current.url);
        el.id = overlayId;
        root.appendChild(el);
        return true;
    }

    // 轮换：请求 /random 拿新媒体描述，更新 current 后重建覆盖层。
    async function rotateOnce() {
        try {
            const resp = await fetch(mediaBase + "random", { cache: "no-store" });
            if (!resp.ok) return;
            const data = await resp.json();
            if (!data || !data.fileName || !data.type) return;
            // 类型/URL 变了才重建，避免无谓 DOM 操作。
            if (data.type !== current.type || (mediaBase + encodeURIComponent(data.fileName)) !== current.url) {
                current.type = data.type;
                current.url = mediaBase + encodeURIComponent(data.fileName);
                installOverlay();
            }
        } catch (e) {
            // 网络抖动等不影响现有背景，静默忽略。
        }
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", installOverlay, { once: true });
    }
    installOverlay();
    setTimeout(installOverlay, 250);

    // 启动轮换定时器（rotate=0 时不启动）。
    if (rotate > 0) {
        setInterval(rotateOnce, rotate * 1000);
    }

    return true;
})();
"@
}

function Install-ZCodeBackground {
    param(
        [Parameter(Mandatory)]
        [object[]]$Targets,

        [Parameter(Mandatory)]
        [string]$JavaScript
    )

    $successCount = 0
    $failureMessages = [Collections.Generic.List[string]]::new()

    foreach ($target in $Targets) {
        try {
            # 新文档注册保证页面刷新或导航后仍会重新创建背景层。
            Invoke-CdpCommand `
                -WebSocketUrl $target.webSocketDebuggerUrl `
                -Method "Page.addScriptToEvaluateOnNewDocument" `
                -Parameters @{ source = $JavaScript } `
                -CommandId 1 | Out-Null

            # 当前文档不会触发上面的注册脚本，因此需要立即执行一次。
            Invoke-CdpCommand `
                -WebSocketUrl $target.webSocketDebuggerUrl `
                -Method "Runtime.evaluate" `
                -Parameters @{
                expression    = $JavaScript
                returnByValue = $true
                awaitPromise  = $true
            } `
                -CommandId 2 | Out-Null

            $successCount++
            Write-Host "已注入页面：$($target.title)"
        }
        catch {
            $failureMessages.Add("$($target.title)：$($_.Exception.Message)")
        }
    }

    if ($successCount -eq 0) {
        throw "未能向任何 ZCode 页面注入背景。$($failureMessages -join '；')"
    }

    if ($failureMessages.Count -gt 0) {
        Write-Warning "部分页面注入失败：$($failureMessages -join '；')"
    }

    return $successCount
}

function Resolve-MediaForCurrentRun {
    param(
        [string]$Mode,
        [string]$ImagePath,
        [string]$VideoPath,
        [string]$MediaDirectory
    )

    # 根据模式决定本次启动用哪个媒体文件、什么类型。
    # 返回：@{ Path=...; Type=...; Directory=...(HTTP 服务要托管的目录) }
    if ($Mode -eq "image") {
        # image 模式：优先 VideoPath（若给了），否则 ImagePath。
        if ($VideoPath) {
            $resolved = (Resolve-Path -LiteralPath $VideoPath).Path
            return @{
                Path      = $resolved
                Type      = "video"
                Directory = (Split-Path -Parent $resolved)
            }
        }
        $resolved = (Resolve-Path -LiteralPath $ImagePath).Path
        return @{
            Path      = $resolved
            Type      = (Get-MediaType -Path $resolved)
            Directory = (Split-Path -Parent $resolved)
        }
    }

    # random / video 模式：必须给 MediaDirectory。
    if (-not $MediaDirectory) {
        throw "$Mode 模式必须指定 -MediaDirectory 参数。"
    }
    if (-not (Test-Path -LiteralPath $MediaDirectory -PathType Container)) {
        throw "媒体目录不存在：$MediaDirectory"
    }
    $resolvedDir = (Resolve-Path -LiteralPath $MediaDirectory).Path

    $picked = Get-RandomMediaFromDirectory -Directory $resolvedDir -Mode $Mode
    return @{
        Path      = $picked.Path
        Type      = $picked.Type
        Directory = $resolvedDir
    }
}

# ============================================================
# main
# ============================================================
$mediaServer = $null
try {
    if (-not (Test-Path -LiteralPath $ZCodePath -PathType Leaf)) {
        throw "ZCode 主程序不存在：$ZCodePath"
    }
    $resolvedZCodePath = (Resolve-Path -LiteralPath $ZCodePath).Path

    # 解析本次运行的媒体。
    $media = Resolve-MediaForCurrentRun `
        -Mode $BackgroundMode `
        -ImagePath $ImagePath `
        -VideoPath $VideoPath `
        -MediaDirectory $MediaDirectory

    $resolvedMediaPath = $media.Path
    $mediaType = $media.Type
    $mediaDirectory = $media.Directory

    if (-not $mediaType) {
        throw "无法识别媒体类型（扩展名不支持）：$resolvedMediaPath"
    }

    if ($ValidateOnly) {
        # 只输出轻量摘要，不启动任何服务，不关闭 ZCode。
        $rotateMode = if ($RotateInterval -gt 0) { "enabled ($($RotateInterval)s)" } else { "disabled" }
        $effImg = if ($ImageOpacity -gt 0) { $ImageOpacity } else { $Opacity }
        $effVid = if ($VideoOpacity -gt 0) { $VideoOpacity } else { $Opacity }
        [ordered]@{
            BackgroundMode     = $BackgroundMode
            MediaPath          = $resolvedMediaPath
            MediaType          = $mediaType
            MediaDirectory     = $mediaDirectory
            Opacity            = $Opacity
            ImageOpacity       = $effImg
            VideoOpacity       = $effVid
            RotateInterval     = if ($RotateInterval -gt 0) { "$RotateInterval 秒" } else { "关闭" }
            RotateMode         = $rotateMode
            DebugPort          = $DebugPort
            MediaPort          = $MediaPort
            ZCodePath          = $resolvedZCodePath
            MediaBytes         = (Get-Item -LiteralPath $resolvedMediaPath).Length
        } | ConvertTo-Json
        exit 0
    }

    # 1. 找空闲 HTTP 端口。
    $actualPort = Find-AvailableMediaPort -StartPort $MediaPort
    if ($actualPort -ne $MediaPort) {
        Write-Warning "媒体端口 $MediaPort 被占用，改用 $actualPort。"
    }

    # 2. 启动媒体 HTTP 服务。
    #    random/video 模式才提供 /random 端点；image 模式不需要（轮换也无意义）。
    $httpRandomMode = if ($BackgroundMode -in @("random", "video")) { $BackgroundMode } else { "none" }
    $mediaServer = Start-MediaHttpServer -Port $actualPort -Directory $mediaDirectory -RandomMode $httpRandomMode
    Write-Host "媒体 HTTP 服务已启动：http://127.0.0.1:$actualPort/ （托管：$mediaDirectory）"

    # 3. 关闭 → 重启 ZCode。
    Stop-ZCodeProcesses -ExecutablePath $resolvedZCodePath
    $zcodeProcess = Start-ZCodeWithDebugging -ExecutablePath $resolvedZCodePath -Port $DebugPort
    $targets = @(Wait-CdpTargets -Port $DebugPort)

    # 4. 构造注入 JS。
    $fileName = [IO.Path]::GetFileName($resolvedMediaPath)
    $encodedName = [Uri]::EscapeDataString($fileName)
    $mediaBaseUrl = "http://127.0.0.1:$actualPort/"
    $sourceUrl = $mediaBaseUrl + $encodedName

    # 仅 random/video 模式 + RotateInterval>0 才真正轮换。
    $effectiveRotate = if ($BackgroundMode -in @("random", "video") -and $RotateInterval -gt 0) { $RotateInterval } else { 0 }

    # 解析实际生效的双透明度：未指定（<=0）时回退到通用 $Opacity。
    $effectiveImageOpacity = if ($ImageOpacity -gt 0) { $ImageOpacity } else { $Opacity }
    $effectiveVideoOpacity = if ($VideoOpacity -gt 0) { $VideoOpacity } else { $Opacity }

    $javaScript = New-OverlayJavaScript `
        -SourceUrl $sourceUrl `
        -MediaType $mediaType `
        -ImageOpacityValue $effectiveImageOpacity `
        -VideoOpacityValue $effectiveVideoOpacity `
        -RotateSeconds $effectiveRotate `
        -MediaBaseUrl $mediaBaseUrl

    $installedCount = Install-ZCodeBackground -Targets $targets -JavaScript $javaScript

    Write-Host ""
    Write-Host "ZCode 背景已启用：成功注入 $installedCount 个页面。"
    Write-Host "模式：$BackgroundMode"
    Write-Host "媒体：$resolvedMediaPath （$mediaType）"
    # 两个透明度相同时只显示一个，不同时分别显示。
    if ([Math]::Abs($effectiveImageOpacity - $effectiveVideoOpacity) -lt 0.001) {
        Write-Host "透明度：$effectiveImageOpacity（图片视频统一）"
    } else {
        Write-Host "透明度：图片 $effectiveImageOpacity / 视频 $effectiveVideoOpacity"
    }
    if ($effectiveRotate -gt 0) {
        Write-Host "轮换：每 $effectiveRotate 秒换一个（来源：$mediaDirectory）"
    }
    else {
        Write-Host "轮换：关闭"
    }
    Write-Host "HTTP 服务端口：$actualPort"
    Write-Host "ZCode PID：$($zcodeProcess.Id)"

    # 5. 【生命周期绑定】阻塞等待 ZCode 退出，退出后关闭 HTTP 服务。
    #    这是新架构的关键：ps1 常驻直到 ZCode 关闭，期间维持 HTTP 服务。
    Write-Host ""
    Write-Host "后台运行中（媒体服务随 ZCode 退出而关闭）。按 Ctrl+C 或关闭 ZCode 以结束。"

    # 用 WaitForExit 阻塞主线程；ZCode 关闭时此调用返回。
    # 注意：PowerShell 的 $ErrorActionPreference=Stop 不会影响 .NET 方法抛异常，这里安全。
    $zcodeProcess.WaitForExit()

    Write-Host "ZCode 已退出，正在关闭媒体服务..."
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    # 无论正常退出还是异常，都确保 HTTP 服务被关闭，不留孤儿进程。
    if ($mediaServer) {
        Stop-MediaHttpServer -Server $mediaServer
    }
}
