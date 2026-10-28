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

Set-Alias tmp Edit-TmpVim

Set-Alias which Get-Command
Set-Alias cwd Copy-Cwd
Set-Alias mkin Go-Mkdir
Set-Alias rmdir Remove-Dir
Set-Alias cdd Cd-D

Set-Alias open Open-Item

Set-Alias l dir

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
