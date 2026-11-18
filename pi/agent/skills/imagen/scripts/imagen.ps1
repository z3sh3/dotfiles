<#
.SYNOPSIS
    Windows / PowerShell front-end for imagen-skill.

.DESCRIPTION
    Thin wrapper around scripts/imagen.mjs. All generation logic stays in the
    Node runner, so behaviour is identical on Windows, macOS and Linux; this
    script only handles Windows ergonomics:

      * PowerShell-native parameters (-Prompt, -Out, -Model, ...) instead of
        bash-style flags, so no backtick/backslash line continuation is needed.
      * Prompts are handed over in a temporary UTF-8 JSON file, which avoids the
        Windows argv encoding problems that mangle Chinese prompts, emoji and
        quotes when they are passed as native command-line arguments.
      * Console input/output is switched to UTF-8 so Chinese prompts and the
        printed report survive PowerShell 5.1 (whose default OEM codepage would
        otherwise turn them into garbage).
      * Exit code is propagated to the caller / CI.

    Verified on Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Prompt
    One or more prompts. Each prompt becomes its own parallel task.

.PARAMETER Name
    Optional filename slugs, positionally paired with -Prompt.

.PARAMETER PromptList
    Prompts separated by '|', e.g. -PromptList 'a cat|a dog'. Use this when the
    script is invoked as "powershell -File imagen.ps1 ..." from cmd.exe, bash or
    CI, where PowerShell cannot bind a real array - it would otherwise merge
    "a","b" into a single prompt. '|' was chosen because prompts rarely contain it.

.PARAMETER NameList
    Slugs separated by '|', paired positionally with -PromptList.

.PARAMETER Json
    Raw JSON (or @file.json) passed straight to the runner.

.PARAMETER PromptFile
    Text file, one prompt per line, optional "name :: prompt".

.PARAMETER Concurrency
    Parallel tasks (runner default 10).

.PARAMETER QueueCapacity
    Bound of the FIFO queue that holds submissions throttled with HTTP 429
    (runner default 50). Pass 0 to disable the queue: a throttled submission then
    fails immediately instead of waiting.

.PARAMETER MaxRequeues
    How many times one task may be requeued after being throttled (default 10).

.PARAMETER Out
    Output directory (default ./generated-images/<timestamp>).

.PARAMETER Check
    Verify credentials and API reachability, generate nothing.

.EXAMPLE
    .\imagen.ps1 -Prompt "a glass teapot on marble, soft studio light" -Name teapot

.EXAMPLE
    .\imagen.ps1 -Prompt "cyberpunk city at night","the same city at sunrise" `
                 -Name cyber-city,cyber-dawn -Size 16:9 -Resolution 2k -Out .\out

.EXAMPLE
    # from cmd.exe / bash / CI, where comma-separated arrays do not survive:
    powershell -ExecutionPolicy Bypass -File imagen.ps1 -PromptList "cat|dog" -Size 1:1

.EXAMPLE
    # 30 images, 10 at a time; throttled submissions wait in a bounded queue
    .\imagen.ps1 -PromptFile .\prompts.txt -Concurrency 10 -QueueCapacity 50

.EXAMPLE
    .\imagen.ps1 -Check
#>
[CmdletBinding()]
param(
    [string[]] $Prompt,
    [string[]] $Name,
    [string]   $PromptList,
    [string]   $NameList,
    [string]   $Json,
    [string]   $PromptFile,
    [string]   $Out,
    [string]   $Model,
    [string]   $FallbackModel,
    [string]   $Size,
    [string]   $Resolution,
    [string]   $Quality,
    [string]   $Background,
    [int]      $Count,
    [string[]] $Reference,
    [int]      $Concurrency,
    [int]      $QueueCapacity = -1,
    [int]      $MaxRequeues,
    [int]      $Timeout,
    [int]      $Interval,
    [int]      $Retries,
    [switch]   $KeepUrls,
    [switch]   $JsonOutput,
    [switch]   $Check,
    [switch]   $ListModels,
    [switch]   $DryRun,
    [string]   $NodePath,
    [string[]] $ExtraArgs
)

$ErrorActionPreference = 'Stop'

# --- UTF-8 everywhere: PS 5.1 defaults to an OEM codepage (e.g. IBM437 / 936) ---
$utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $utf8 } catch { }
try { [Console]::InputEncoding = $utf8 } catch { }
$OutputEncoding = $utf8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$runner = Join-Path $scriptDir 'imagen.mjs'
if (-not (Test-Path -LiteralPath $runner)) {
    throw "Runner not found: $runner (expected next to imagen.ps1)"
}

# --- locate Node.js (18+ required for global fetch) ---
$node = $NodePath
if (-not $node) {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $node = $cmd.Source }
}
if (-not $node) { $node = 'node' }

$argv = New-Object System.Collections.Generic.List[string]

function Add-Option {
    param($List, [string] $Flag, $Value)
    if ($null -ne $Value -and "$Value" -ne '') {
        $List.Add($Flag)
        $List.Add([string] $Value)
    }
}

if ($Prompt -and $Json) {
    throw 'Use either -Prompt or -Json, not both.'
}

# -PromptList / -NameList exist for "-File" style invocation from cmd/bash/CI,
# where PS binds "a","b" as the single string "a,b".
if ($PromptList) {
    if ($Prompt) { throw 'Use either -Prompt or -PromptList, not both.' }
    $Prompt = @($PromptList -split '\|')
}
if ($NameList) {
    if ($Name) { throw 'Use either -Name or -NameList, not both.' }
    $Name = @($NameList -split '\|')
}

$tempJson = $null
try {
    # --- prompts: ship them as UTF-8 JSON so encoding never depends on argv ---
    if ($Prompt -and $Prompt.Count -gt 0) {
        $jobs = @()
        for ($i = 0; $i -lt $Prompt.Count; $i++) {
            $job = '{"prompt":' + (ConvertTo-Json -InputObject ([string] $Prompt[$i]) -Compress)
            if ($Name -and $i -lt $Name.Count -and $Name[$i]) {
                $job += ',"name":' + (ConvertTo-Json -InputObject ([string] $Name[$i]) -Compress)
            }
            $job += '}'
            $jobs += $job
        }
        $payload = '{"prompts":[' + ($jobs -join ',') + ']}'
        $tempJson = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'imagen-skill-' + [Guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($tempJson, $payload, $utf8)
        $argv.Add('--json')
        $argv.Add('@' + $tempJson)
    }
    elseif ($Json) {
        Add-Option $argv '--json' $Json
    }

    if ($PromptFile) { Add-Option $argv '--file' $PromptFile }
    if ($Out)        { Add-Option $argv '--out' $Out }
    if ($Model)      { Add-Option $argv '--model' $Model }
    if ($FallbackModel) { Add-Option $argv '--fallback-model' $FallbackModel }
    if ($Size)       { Add-Option $argv '--size' $Size }
    if ($Resolution) { Add-Option $argv '--resolution' $Resolution }
    if ($Quality)    { Add-Option $argv '--quality' $Quality }
    if ($Background) { Add-Option $argv '--background' $Background }
    if ($Count -gt 0) { Add-Option $argv '--count' $Count }
    if ($Reference)  { foreach ($r in $Reference) { Add-Option $argv '--reference' $r } }
    if ($Concurrency -gt 0) { Add-Option $argv '--concurrency' $Concurrency }
    # 0 is meaningful here (disable the queue), so unset is detected via -1.
    if ($QueueCapacity -ge 0) { Add-Option $argv '--queue-capacity' $QueueCapacity }
    if ($MaxRequeues -gt 0) { Add-Option $argv '--max-requeues' $MaxRequeues }
    if ($Timeout -gt 0) { Add-Option $argv '--timeout' $Timeout }
    if ($Interval -gt 0) { Add-Option $argv '--interval' $Interval }
    if ($Retries -gt 0) { Add-Option $argv '--retries' $Retries }
    if ($KeepUrls)   { $argv.Add('--keep-urls') }
    if ($JsonOutput) { $argv.Add('--json-output') }
    if ($Check)      { $argv.Add('--check') }
    if ($ListModels) { $argv.Add('--list-models') }
    if ($DryRun)     { $argv.Add('--dry-run') }
    if ($ExtraArgs)  { foreach ($a in $ExtraArgs) { $argv.Add([string] $a) } }

    # No work requested -> show help instead of failing with "no prompts".
    if ($argv.Count -eq 0) { $argv.Add('--help') }

    & $node $runner @argv
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
}
finally {
    if ($tempJson -and (Test-Path -LiteralPath $tempJson)) {
        Remove-Item -LiteralPath $tempJson -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
