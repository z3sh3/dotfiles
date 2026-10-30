function Open-Download {
    Open-Item "$HOME\downloads"
}

function Open-Item {
    param(
            [PSDefaultValue(Help="default open pwd")]
            [string]$path = $PWD.Path
         )
    Invoke-Item $path
}

function Force-Mkdir {
    param([string]$path)

    New-Item -ItemType Directory -Force -Path $path
}

function Go-Mkdir {
    param([string]$path)

    Force-Mkdir $path
    cd $path
}

function Find-Files {
    param([string]$file_name)

    rg --files | rg $file_name
}

function Vi-Fzf {
    vim (fzf)
}

function Copy-Cwd {
    Set-Clipboard -Value $PWD
}

function Check-Note {
    param(
        [PSDefaultValue(Help="days before or after now")]
        [double]$days = 0.0
    )

    $target_date = (Get-Date).AddDays($days)
    $current_year = Get-Date $target_date -Format 'yyyy'
    $current_date = (Get-Date $target_date -Format 'yyyyMMdd')
    $note_dir = "D:\notes\$current_year"
    $note_filename = "$current_date.md"
    $note_file = "$note_dir\$note_filename"

    vi $note_file
}

function Up-Folder {
    Set-Location ..
}

function Remove-Dir {
    param([string]$path)
    Remove-Item -Force -Recurse $path
}

# `rm` accepting multiple files/directories. The built-in `rm` alias must be
# removed because aliases win over functions in PowerShell's command lookup.
Remove-Item Alias:rm -Force -ErrorAction SilentlyContinue

# Deletes files and/or directories. Prompts for confirmation only when more
# than one item would be deleted; a single item is removed without asking.
function rm {
    param(
        [Parameter(ValueFromRemainingArguments = $true, Mandatory = $true)]
        [string[]]$Path
    )

    if ($Path.Count -eq 0) {
        Write-Error 'rm: missing operand'
        return
    }

    $targets = @(
        foreach ($p in $Path) {
            $item = Get-Item -Path $p -Force -ErrorAction SilentlyContinue
            if ($null -eq $item) {
                Write-Warning "rm: no such file or directory: $p"
            }
            else {
                $item
            }
        }
    )
    $targets = @($targets | Sort-Object -Property FullName -Unique)

    if ($targets.Count -eq 0) { return }

    if ($targets.Count -gt 1) {
        $targets | ForEach-Object { Write-Host "  $($_.FullName)" }
        $answer = Read-Host "rm: delete these $($targets.Count) items? [y/N]"
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host 'rm: cancelled'
            return
        }
    }

    foreach ($t in $targets) {
        try {
            Remove-Item -LiteralPath $t.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "rm: cannot remove '$($t.FullName)': $($_.Exception.Message)"
        }
    }
}

function Make-Tags {
    rg --files | ctags -R --links=no -L -
}

function Cd-D {
    cd D:\
}

function Cd-Work {
    cd D:\work
}

function gdf {
    git diff
}

function gcm {
    git commit -a
}

function gst {
    git status
}

function Git-Push {
    git push
}

function Edit-TmpVim {
    [CmdletBinding()]
    param (
        # 文件后缀，例如 md,txt,json；不要带小数点
        [Parameter(Position = 0)]
        [string]$Extension
    )

    # 临时目录
    $tmpDir = "D:\tmp"
    # 不存在则创建目录
    if (-not (Test-Path $tmpDir)) {
        New-Item -Path $tmpDir -ItemType Directory -Force | Out-Null
    }

    # 设置默认后缀
    if ([string]::IsNullOrWhiteSpace($Extension)) {
        $ext = "txt"
    }
    else {
        # 清理用户可能传入的 .md 这种带点的情况
        $ext = $Extension.TrimStart('.')
    }

    # 生成时间戳：yyMMddHHmmssfff（两位年+月+日+24h时+分+秒+3位毫秒）
    $timeStamp = (Get-Date).ToString("yyMMddHHmmssfff")

    # 拼接文件名 tmp_时间戳.后缀
    $fileName = "tmp_$timeStamp.$ext"
    $fullPath = Join-Path $tmpDir $fileName

    # 创建空文件
    New-Item -Path $fullPath -ItemType File -Force | Out-Null

    vim $fullPath
}

function Set-Proxy {
    param(
        [string]$ProxyHost = "127.0.0.1",
        [int]$Port = 7897,
        [switch]$Off,
        [switch]$UseHttp,
        [switch]$Socks
    )

    if ($Off) {
        Remove-Item -Path Env:http_proxy -ErrorAction SilentlyContinue
        Remove-Item -Path Env:https_proxy -ErrorAction SilentlyContinue
        Remove-Item -Path Env:all_proxy -ErrorAction SilentlyContinue
        Remove-Item -Path Env:socks_proxy -ErrorAction SilentlyContinue
        Remove-Item -Path Env:SOCKS_PROXY -ErrorAction SilentlyContinue
        Write-Host "All proxies have been turned OFF." -ForegroundColor Yellow
        return
    }

    # HTTP (mixed port) is the default: the host name stays visible to the proxy,
    # so domain based routing rules keep matching, and it is understood by
    # curl/git/npm as well as by .NET (Invoke-WebRequest / Invoke-RestMethod).
    # -UseHttp is kept for backward compatibility and means the same as default.
    # -Socks switches to socks5h, i.e. the proxy resolves DNS; use it only for
    # tools that need a SOCKS endpoint, because .NET based cmdlets do not
    # understand the socks5h scheme and will time out.
    $useSocks = $Socks -and -not $UseHttp

    if ($useSocks) {
        $socksUrl = "socks5h://${ProxyHost}:${Port}"
        $env:all_proxy = $socksUrl
        $env:socks_proxy = $socksUrl
        $env:SOCKS_PROXY = $socksUrl
        # Drop HTTP/HTTPS proxies to avoid conflicts
        Remove-Item -Path Env:http_proxy -ErrorAction SilentlyContinue
        Remove-Item -Path Env:https_proxy -ErrorAction SilentlyContinue
        Write-Host "SOCKS5 (remote DNS) proxy set to: $socksUrl" -ForegroundColor Green
    }
    else {
        $httpUrl = "http://${ProxyHost}:${Port}"
        $env:http_proxy = $httpUrl
        $env:https_proxy = $httpUrl
        $env:all_proxy = $httpUrl
        # Drop SOCKS proxies to avoid conflicts
        Remove-Item -Path Env:socks_proxy -ErrorAction SilentlyContinue
        Remove-Item -Path Env:SOCKS_PROXY -ErrorAction SilentlyContinue
        Write-Host "HTTP/HTTPS proxy set to: $httpUrl" -ForegroundColor Green
    }
}

# Upgrade every installed winget package through the local HTTP proxy.
# Without -ExcludedIds it falls back to a single `winget upgrade --all`.
# With -ExcludedIds, winget has no --exclude option for `upgrade --all`, and the
# table printed by `winget upgrade` cannot be parsed reliably (long names and
# versions make winget drop the column padding), so the installed ids come from
# `winget export` (JSON) and every remaining package is upgraded one by one.
# The --proxy option needs the admin setting ProxyCommandLineOptions to be enabled:
#   winget settings --enable ProxyCommandLineOptions
function Update-Winget {
    param(
        [string[]]$ExcludedIds = @()
    )

    $proxy = 'http://localhost:7897'

    if (-not $ExcludedIds) {
        winget upgrade --all --proxy $proxy --include-unknown --accept-source-agreements
        return
    }

    $json = Join-Path $env:TEMP 'wgu-export.json'

    winget export -o $json --include-versions --accept-source-agreements --disable-interactivity --proxy $proxy | Out-Null
    if (-not (Test-Path $json)) {
        Write-Error "winget export produced no package list at $json"
        return
    }

    $ids = (Get-Content $json -Raw | ConvertFrom-Json).Sources.Packages.PackageIdentifier |
        Where-Object { $_ -and $_ -notin $ExcludedIds }

    foreach ($id in $ids) {
        winget upgrade --id $id --exact --proxy $proxy --include-unknown --accept-source-agreements
    }
}

# ------------------------------------------------------------- ls -lAh style
# `ll` mimics GNU `ls -lAh`: long format, hidden items included, human readable
# sizes. `l` stays the plain listing (an alias of `ls`).
function Format-Size {
    param([long]$Bytes)

    if     ($Bytes -ge 1TB) { '{0,5:0.#}T' -f ($Bytes / 1TB) }
    elseif ($Bytes -ge 1GB) { '{0,5:0.#}G' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0,5:0.#}M' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0,5:0.#}K' -f ($Bytes / 1KB) }
    else                    { '{0,6}'      -f $Bytes }
}

function Get-LsLong {
    [CmdletBinding()]
    param(
        [PSDefaultValue(Help = "default pwd")]
        [string]$Path = '.'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "ll: cannot access '$Path': No such file or directory"
        return
    }

    $items = Get-ChildItem -LiteralPath $Path -Force
    if ($null -eq $items) { return }

    # Only colourise when the output goes straight to the console: a line feeding
    # another command must stay plain, otherwise the escape bytes end up in files.
    # $PSStyle does not exist before PowerShell 7.
    $useColor = ($PSVersionTable.PSVersion.Major -ge 7) -and ($MyInvocation.PipelineLength -eq 1)
    if ($useColor) {
        $dirPrefix = $PSStyle.FileInfo.Directory
        $reset = $PSStyle.Reset
    }

    # One line per entry: timestamp, size, name. There is no leading permission
    # column because `Mode` on Windows only exposes file attributes (hidden,
    # system, read-only, ...), not POSIX permissions, so it says nothing useful.
    # Directories are distinguished by the `-` placeholder plus the name colour.
    #
    # The size tiers are inlined instead of calling Format-Size: a PowerShell
    # function call costs ~25 us and dominated the loop (51 ms of the 112 ms
    # measured on a 2050 item directory), while the `-f` operator is ~0.4 us/line.
    foreach ($item in $items) {
        if ($item.PSIsContainer) {
            $size = '     -'
            $name = if ($useColor) { "$dirPrefix$($item.Name)$reset" } else { $item.Name }
        }
        else {
            $len = $item.Length
            if     ($len -ge 1TB) { $size = '{0,5:0.#}T' -f ($len / 1TB) }
            elseif ($len -ge 1GB) { $size = '{0,5:0.#}G' -f ($len / 1GB) }
            elseif ($len -ge 1MB) { $size = '{0,5:0.#}M' -f ($len / 1MB) }
            elseif ($len -ge 1KB) { $size = '{0,5:0.#}K' -f ($len / 1KB) }
            else                  { $size = '{0,6}'      -f $len }
            $name = $item.Name
        }

        '{0} {1} {2}' -f $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'),
                         $size,
                         $name
    }
}
# -----------------------------------------------------------------------------

Set-Alias tmp Edit-TmpVim

Set-Alias which Get-Command
Set-Alias cwd Copy-Cwd
Set-Alias mkin Go-Mkdir
Set-Alias rmdir Remove-Dir
Set-Alias cdd Cd-D

Set-Alias open Open-Item

# `l` is the plain directory listing; `ll` is the `ls -lAh` style long listing
Set-Alias l ls
Set-Alias ll Get-LsLong

# Directory listings: draw directory names as bold blue text on the default background.
# The default PSStyle value (ESC[44;1m) paints a blue background block instead.
$PSStyle.FileInfo.Directory = "`e[1;34m"
Set-Alias vim nvim
Set-Alias vi nvim
Set-Alias .. Up-Folder

Set-Alias gps Git-Push -Force

# Elixir command alias
Set-Alias elx iex.bat

Set-Alias onproxy Set-Proxy

Set-Alias wgu Update-Winget

# Save the current value in the $p variable.
$p = [Environment]::GetEnvironmentVariable("PSModulePath")
# Add the new path to the $p variable. Begin with a semi-colon separator.
$p += ";$HOME\PSmodules"
# set english output
[System.Threading.Thread]::CurrentThread.CurrentUICulture = 'en-US'
[System.Threading.Thread]::CurrentThread.CurrentCulture = 'en-US'
chcp 437 | Out-Null
# Add the paths in $p to the PSModulePath value.
[Environment]::SetEnvironmentVariable("PSModulePath",$p)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Console]::InputEncoding = [Text.Encoding]::UTF8
$env:EDITOR = "nvim"
$env:LESSCHARSET='utf-8'
$env:POWERSHELL_UPDATECHECK = 'Off'
$env:NODE_PATH = "D:\npm_lib"
$env:RIPGREP_CONFIG_PATH = "$HOME\ripgreprc"
$env:PYTHONUTF8 = 1
# Load PSReadLine explicitly before the key handler calls below, otherwise the first
# Set-PSReadLineKeyHandler triggers the very same on-demand module import.
Import-Module PSReadLine

Set-PSReadLineKeyHandler -Chord Ctrl+r -ScriptBlock {
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert('vim (fzf)')
    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
}
Set-PSReadLineKeyHandler -Chord Ctrl+u -Function BackwardKillLine

# Terminal-Icons is no longer used: its format.ps1xml rewrote every FileSystemInfo
# object, roughly doubling the time of a large directory listing, and importing it at
# startup was also expensive. Get-ChildItem is left untouched (no proxy function).

# zoxide config at the end of config file
Invoke-Expression (& { (zoxide init --cmd cd powershell | Out-String) })

# Native prompt. Only .git/HEAD is read, so no git.exe process is spawned per prompt.
# Keep python/venv from rewriting the prompt.
$env:VIRTUAL_ENV_DISABLE_PROMPT = 1
$env:PYENV_VIRTUALENV_DISABLE_PROMPT = 1

$global:GitDirCache = @{}

function Get-GitDirectory {
    param([string]$Path)

    if ($global:GitDirCache.ContainsKey($Path)) { return $global:GitDirCache[$Path] }

    $found = $null
    $current = $Path

    while ($current) {
        $dotGit = Join-Path $current '.git'

        if (Test-Path -LiteralPath $dotGit -PathType Container) {
            $found = $dotGit
            break
        }

        # Worktrees and submodules use a .git file pointing at the real git dir
        if (Test-Path -LiteralPath $dotGit -PathType Leaf) {
            $firstLine = Get-Content -LiteralPath $dotGit -TotalCount 1 -ErrorAction SilentlyContinue
            if ($firstLine -like 'gitdir:*') {
                $target = $firstLine.Substring(7).Trim()
                if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $current $target }
                $found = $target
                break
            }
        }

        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }

    $global:GitDirCache[$Path] = $found
    return $found
}

function Get-GitBranchName {
    param([string]$GitDirectory)

    $headFile = Join-Path $GitDirectory 'HEAD'
    $firstLine = Get-Content -LiteralPath $headFile -TotalCount 1 -ErrorAction SilentlyContinue
    if (-not $firstLine) { return '' }

    # "ref: refs/heads/main" for a branch, a plain sha for a detached HEAD
    if ($firstLine -like 'ref:*') {
        return ($firstLine.Substring(4).Trim() -replace '^refs/heads/', '')
    }

    return $firstLine.Substring(0, [Math]::Min(7, $firstLine.Length))
}

function global:prompt {
    # $? must be read before any other statement runs: every statement, including a
    # plain variable assignment, resets it.
    $lastSucceeded = $?
    $lastExitCode = $LASTEXITCODE

    $esc = [char]27
    $bel = [char]7
    $reset = "${esc}[0m"
    $loc = $PWD.Path

    # Windows Terminal shell integration. OSC 9;9 tells the terminal the working
    # directory, which is what makes a pane created with "splitMode": "duplicate"
    # open in the same directory as this pane. The OSC 133 marks are the prompt and
    # commandline boundaries used for the scrollbar marks. They are only emitted when
    # running inside Windows Terminal (which sets WT_SESSION) so other consoles never
    # receive them. The emits cost no measurable time because no command is spawned.
    $marksStart = ''
    $marksEnd = ''
    if ($env:WT_SESSION) {
        # 133;D expects an exit code: 0 for success, non-zero for failure
        if ($lastSucceeded) { $markExitCode = 0 }
        elseif ($lastExitCode) { $markExitCode = $lastExitCode }
        else { $markExitCode = 1 }

        # The very first prompt has no command to close, so the D mark is skipped then
        # (a stray D would show up as a phantom mark in the scrollbar).
        if ($global:PromptMarksStarted) { $markDone = "${esc}]133;D;$markExitCode${bel}" }
        else { $markDone = '' }
        $global:PromptMarksStarted = $true

        $marksStart = "$markDone${esc}]133;A${bel}${esc}]9;9;`"$loc`"${bel}"
        $marksEnd = "${esc}]133;B${bel}"
    }

    $displayPath = $loc
    if ($displayPath.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) {
        if ($displayPath.Length -eq $HOME.Length) { $displayPath = '~' }
        else { $displayPath = '~' + $displayPath.Substring($HOME.Length) }
    }

    $pathPart = "${esc}[38;2;86;156;214m$displayPath$reset"

    $gitPart = ''
    $gitDirectory = Get-GitDirectory -Path $loc
    if ($gitDirectory) {
        $branch = Get-GitBranchName -GitDirectory $gitDirectory
        if ($branch) { $gitPart = " ${esc}[38;2;152;195;121mgit:($branch)$reset" }
    }

    $statusPart = ''
    if (-not $lastSucceeded) {
        if ($lastExitCode) { $statusPart = " ${esc}[38;2;224;108;117m[$lastExitCode]$reset" }
        else { $statusPart = " ${esc}[38;2;224;108;117m[!]$reset" }
    }

    "$marksStart$pathPart$gitPart$statusPart`n${esc}[38;2;152;195;121m$reset ${marksEnd}"
}



# ---- YouTube playback helpers (ported from ~/.dotfiles/config/fish/functions) ----

function Get-ProxyAddr {
    # First line starting with "socks" in ~/proxy.info (socks5 is the default)
    $file = Join-Path $HOME 'proxy.info'
    if (Test-Path $file) {
        $line = Select-String -Path $file -Pattern '^socks' -List | Select-Object -First 1
        if ($line) { return $line.Line.Trim() }
    }
    return ''
}

function Get-NoProxySites {
    $file = Join-Path $HOME '.dotfiles\firefox\noproxy.txt'
    if (-not (Test-Path $file)) { return @() }
    (Get-Content $file -Raw) -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

function Test-NoProxyUrl {
    param([string]$Url)
    foreach ($site in Get-NoProxySites) {
        if ($Url -like "*$site*") { return $true }
    }
    return $false
}

function Get-YtMetaTitle {
    param([string]$Url, [string]$Proxy)
    $raw = (& yt-dlp --proxy="$Proxy" --remote-components ejs:npm --cookies-from-browser firefox -j $Url 2>$null) -join "`n"
    if (-not $raw) { return $null }
    try {
        $meta = $raw | ConvertFrom-Json
    } catch {
        return $null
    }
    # Strip double quotes so the value survives the cmd pipeline unchanged
    return ('{0} - {1}' -f $meta.title, $meta.uploader) -replace '"', ''
}

function Invoke-YListen {
    param([string]$Url, [string]$Proxy)
    if (-not $Url) { return }
    if (Test-NoProxyUrl $Url) {
        & mpv --no-video $Url
        return
    }
    Write-Host "using proxy: $Proxy"
    $title = Get-YtMetaTitle -Url $Url -Proxy $Proxy
    if (-not $title) {
        Write-Host "Failed to fetch metadata: $Url"
        return
    }
    $mpv = @(
        'mpv', '--no-video',
        "--term-playing-msg=`"$title`"",
        '--cache-secs=300',
        '--demuxer-max-bytes=64MiB',
        '--demuxer-max-back-bytes=32MiB',
        '--force-seekable=yes',
        '-'
    )
    $yt = @(
        'yt-dlp', '-q', '--no-warnings',
        "--proxy=`"$Proxy`"",
        '--cookies-from-browser firefox',
        '--format', 'worstaudio',
        '--remote-components', 'ejs:npm',
        '--remote-components', 'ejs:github',
        '-o', '-',
        "`"$Url`""
    )
    # Pipe through cmd so the audio stream stays binary
    & cmd /c (($yt -join ' ') + ' | ' + ($mpv -join ' '))
}

function ting {
    $proxy = Get-ProxyAddr
    if ($args.Count -ge 1 -and (Test-Path -LiteralPath $args[0] -PathType Leaf)) {
        foreach ($url in (Get-Content -LiteralPath $args[0])) {
            $url = $url.Trim()
            if ($url) { Invoke-YListen -Url $url -Proxy $proxy }
        }
        return
    }
    if ($args.Count -ge 1) {
        Invoke-YListen -Url $args[0] -Proxy $proxy
    }
}

function kan {
    if ($args.Count -lt 1) {
        Write-Host 'provide a url to play'
        return 1
    }
    $url = $args[0]
    if (Test-NoProxyUrl $url) {
        & mpv $url
        return
    }
    $proxy = Get-ProxyAddr
    Write-Host "using proxy: $proxy"
    $title = Get-YtMetaTitle -Url $url -Proxy $proxy
    if (-not $title) {
        Write-Host 'Failed to fetch metadata'
        return 1
    }
    $mpv = @(
        'mpv',
        "--force-media-title=`"$title`"",
        '--force-seekable=yes',
        '-'
    )
    $yt = @(
        'yt-dlp', '-q', '--no-warnings',
        "--proxy=`"$proxy`"",
        '--cookies-from-browser firefox',
        '--remote-components', 'ejs:npm',
        '--format', '"best[height<=720]/best[height<=480]/best[height<=1080]/best"',
        '--embed-subs',
        '-o', '-',
        "`"$url`""
    )
    & cmd /c (($yt -join ' ') + ' | ' + ($mpv -join ' '))
}

# Common yt-dlp options (cookies, remote-components) come from the default
# per-user config, loaded via ~/.dotfiles/config/yt-dlp/config; only the
# format/output specifics are passed here.
function yt-video {
    $proxy = Get-ProxyAddr
    $out = 'D:\yt-download\Video\%(title)s.%(ext)s'
    if ($proxy) {
        & yt-dlp --proxy $proxy --embed-subs -o $out @args
    } else {
        & yt-dlp --embed-subs -o $out @args
    }
}

function yt-audio {
    $proxy = Get-ProxyAddr
    $out = 'D:\yt-download\Music\%(title)s.%(ext)s'
    if ($proxy) {
        & yt-dlp --proxy $proxy --format bestaudio -o $out @args
    } else {
        & yt-dlp --format bestaudio -o $out @args
    }
}
