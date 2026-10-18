#requires -Version 5.1
<#
  run-tests.ps1 - end-to-end protocol test driver for the DSH Computer Use Windows helper.

  IMPORTANT: This file MUST be saved as UTF-8 *WITH* BOM. Windows PowerShell 5.1 parses
  BOM-less UTF-8 .ps1 files as the ANSI/GBK code page, which corrupts the Chinese literals
  used by the encoding round-trip test. A self-check below fails fast if that happened.

  Usage:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File helper\tests\run-tests.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File helper\tests\run-tests.ps1 -AgentPath <path>

  Exit codes: 0 = all checks passed, 1 = failures or fatal error, 2 = interactive desktop
  locked/secure (skipped, nothing automated).

  Safety: only a Notepad window is automated, and only after creating a fresh *untitled* tab
  via the "Add tab" (AutomationId AddButton) button. Before any typing the driver re-reads
  document_text and refuses to type unless the document is blank. A pre-existing user Notepad
  session is never killed; in that case the test tab is closed (best effort) instead.
#>
[CmdletBinding()]
param(
    [string]$AgentPath = '',
    [int]$PingTimeoutMs = 60000,
    [int]$CallTimeoutMs = 20000,
    [switch]$KeepHelperAliveOnFailure
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ---------------------------------------------------------------------------------------------
# Paths / run directory
# ---------------------------------------------------------------------------------------------
$script:TestDir = $PSScriptRoot
$script:HelperDir = Split-Path -Parent $script:TestDir
$script:RepoRoot = Split-Path -Parent $script:HelperDir
if ([string]::IsNullOrWhiteSpace($AgentPath)) { $AgentPath = Join-Path $script:HelperDir 'ComputerUseAgent.ps1' }
$script:AgentPath = $AgentPath
$script:ProtocolPath = Join-Path $script:RepoRoot 'docs\helper-protocol.md'

$script:RunDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-cu-tests\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Maximum 99999))
New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
$script:TranscriptPath = Join-Path $script:RunDir 'transcript.jsonl'
$script:ReportPath = Join-Path $script:RunDir 'report.txt'
$script:StderrPath = Join-Path $script:RunDir 'helper-stderr.log'

# ---------------------------------------------------------------------------------------------
# Console / result plumbing
# ---------------------------------------------------------------------------------------------
$script:Transcript = New-Object System.Collections.ArrayList
$script:Checks = New-Object System.Collections.ArrayList
$script:LastExchanges = New-Object System.Collections.ArrayList
$script:Timings = [ordered]@{}
$script:FailCount = 0
$script:WarnCount = 0
$script:ThreadNotes = New-Object System.Collections.ArrayList
$script:ChecksByItem = @{}
$script:SkippedItems = New-Object System.Collections.ArrayList
$script:ReqSeq = 0
$script:RequestCount = 0
$script:Proc = $null
$script:Stdin = $null
$script:HelperStarted = $false
$script:HelperExited = $false
$script:HelperExitCode = $null
$script:HelperShutdownSent = $false
$script:PreexistingNotepadPids = @()
$script:NewNotepadPids = @()
$script:LaunchedNotepadStubPid = 0
$script:MainWindowId = 0
$script:MainNotepadPid = 0
$script:MainStateId = $null
$script:OurTabOpen = $false
$script:ShutdownDone = $false

function Write-Line {
    param([string]$Text = '')
    Write-Host $Text
}
function Write-Note {
    param([string]$Text)
    [void]$script:ThreadNotes.Add($Text)
    Add-Transcript ('# NOTE ' + $Text)
    Write-Line ('       note: ' + $Text)
}
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Add-Transcript {
    param([string]$Line)
    [void]$script:Transcript.Add($Line)
    try { [System.IO.File]::AppendAllText($script:TranscriptPath, ($Line + "`n"), $script:Utf8NoBom) } catch { }
}

function Add-Check {
    param(
        [string]$Item,
        [string]$Name,
        [bool]$Ok,
        [string]$Detail = '',
        [long]$Ms = -1,
        $Exchange = $null
    )
    $entry = [pscustomobject]@{ Item = $Item; Name = $Name; Ok = $Ok; Detail = $Detail; Ms = $Ms }
    [void]$script:Checks.Add($entry)
    if (-not $script:ChecksByItem.ContainsKey($Item)) { $script:ChecksByItem[$Item] = New-Object System.Collections.ArrayList }
    [void]$script:ChecksByItem[$Item].Add($entry)
    $tag = 'PASS'
    if (-not $Ok) { $tag = 'FAIL' }
    $msPart = ''
    if ($Ms -ge 0) { $msPart = (' ({0} ms)' -f $Ms) }
    Write-Line ('{0} [{1}] {2}{3}' -f $tag, $Item, $Name, $msPart)
    if (-not $Ok) {
        if (-not [string]::IsNullOrEmpty($Detail)) { Write-Line ('       detail: ' + $Detail) }
        $exchanges = @()
        if ($null -ne $Exchange) { $exchanges = @($Exchange) }
        elseif ($script:LastExchanges.Count -gt 0) { $exchanges = @($script:LastExchanges | Select-Object -Last 3) }
        foreach ($x in $exchanges) {
            if ($null -eq $x) { continue }
            if ($x -is [string]) { Write-Line ('       jsonl: ' + $x); continue }
            if ($x.PSObject.Properties['request']) { Write-Line ('       jsonl > ' + $x.request) }
            if ($x.PSObject.Properties['response']) { Write-Line ('       jsonl < ' + $x.response) }
        }
        $script:FailCount++
        Add-Transcript ('# FAIL [' + $Item + '] ' + $Name + ' :: ' + $Detail)
    }
}

function Add-Timing {
    param([string]$Name, [long]$Ms)
    $script:Timings[$Name] = $Ms
}

function Require-Check {
    param(
        [string]$Item,
        [string]$Name,
        [bool]$Ok,
        [string]$Detail = '',
        [long]$Ms = -1,
        $Exchange = $null
    )
    Add-Check -Item $Item -Name $Name -Ok $Ok -Detail $Detail -Ms $Ms -Exchange $Exchange
    if (-not $Ok) { throw [CuTestAbort]::new(('precondition failed: [' + $Item + '] ' + $Name + ' :: ' + $Detail)) }
}

# ---------------------------------------------------------------------------------------------
# stderr drainer (keeps the helper's stderr pipe from filling and captures it for diagnostics)
# ---------------------------------------------------------------------------------------------
$script:DrainerSource = @'
using System;
using System.Text;
using System.Threading;

public class CuTestAbort : System.Exception {
    public CuTestAbort(string message) : base(message) { }
}

public static class CuTestStderr {
    private static readonly object Sync = new object();
    private static readonly StringBuilder Buf = new StringBuilder();
    private static Thread _thread;

    public static void Start(System.IO.StreamReader reader) {
        _thread = new Thread(delegate() {
            try {
                string line;
                while ((line = reader.ReadLine()) != null) {
                    lock (Sync) { Buf.AppendLine(line); }
                }
            } catch { }
        });
        _thread.IsBackground = true;
        _thread.Start();
    }

    public static string Text() {
        lock (Sync) { return Buf.ToString(); }
    }
}
'@
Add-Type -TypeDefinition $script:DrainerSource

# ---------------------------------------------------------------------------------------------
# Preflight: encoding + helper presence + interactive desktop
# ---------------------------------------------------------------------------------------------
function Assert-FileEncoding {
    $bytes = [System.IO.File]::ReadAllBytes($script:AgentPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Add-Check -Item '0' -Name ("helper script exists: " + $script:AgentPath) -Ok $true
    if ($hasBom) {
        Write-Note 'helper script carries a UTF-8 BOM (protocol asks UTF-8 no BOM); harmless for a fully-ASCII source'
    }
}

function Start-Helper {
    if (-not (Test-Path -LiteralPath $script:AgentPath)) {
        throw [CuTestAbort]::new(('helper script not found: ' + $script:AgentPath))
    }
    Assert-FileEncoding
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $script:AgentPath)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.WorkingDirectory = $script:HelperDir
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$p.Start()
    $script:Proc = $p
    $script:HelperStarted = $true
    $script:Stdin = New-Object System.IO.StreamWriter($p.StandardInput.BaseStream, (New-Object System.Text.UTF8Encoding($false)))
    $script:Stdin.AutoFlush = $true
    [CuTestStderr]::Start($p.StandardError)
    Add-Timing 'helper_spawn' $sw.ElapsedMilliseconds
    Write-Line ('helper pid={0} exe={1}' -f $p.Id, $exe)
    Write-Line ('helper stdout/stderr redirected; transcripts: ' + $script:TranscriptPath)
}

function Read-ResponseLine {
    param([int]$TimeoutMs)
    $task = $script:Proc.StandardOutput.ReadLineAsync()
    $completed = $task.Wait($TimeoutMs)
    if (-not $completed) {
        $stderr = [CuTestStderr]::Text()
        throw [CuTestAbort]::new(('TIMEOUT: helper produced no response line within {0} ms. stderr so far:`n{1}' -f $TimeoutMs, $stderr))
    }
    if ($task.IsFaulted) {
        throw [CuTestAbort]::new(('helper stdout read failed: ' + $task.Exception.GetBaseException().Message))
    }
    $line = $task.Result
    if ($null -eq $line) {
        $stderr = [CuTestStderr]::Text()
        throw [CuTestAbort]::new(('helper closed stdout / exited unexpectedly. stderr so far:`n' + $stderr))
    }
    return $line
}

function Send-Rpc {
    param(
        [string]$Method,
        $Params = $null,
        [int]$TimeoutMs = 0
    )
    if ($TimeoutMs -le 0) { $TimeoutMs = $CallTimeoutMs }
    if ($null -eq $script:Proc) { throw [CuTestAbort]::new('helper process is not running') }
    if ($script:Proc.HasExited) {
        throw [CuTestAbort]::new(('helper process already exited (code ' + $script:Proc.ExitCode + '). stderr:`n' + [CuTestStderr]::Text()))
    }
    $script:ReqSeq++
    $req = [ordered]@{ 'id' = $script:ReqSeq; 'method' = $Method }
    if ($null -ne $Params) { $req['params'] = $Params }
    $json = ConvertTo-Json -InputObject $req -Depth 30 -Compress
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:Stdin.WriteLine($json)
    $line = Read-ResponseLine -TimeoutMs $TimeoutMs
    $sw.Stop()
    $script:RequestCount++
    Add-Transcript ('> ' + $json)
    Add-Transcript ('< ' + $line)
    try { $resp = ConvertFrom-Json -InputObject $line } catch { throw [CuTestAbort]::new(('helper emitted invalid JSON: ' + $line)) }
    if ($null -eq $resp) { throw [CuTestAbort]::new('helper emitted an empty response') }
    $exch = [pscustomobject]@{ method = $Method; request = $json; response = $line; ms = $sw.ElapsedMilliseconds }
    [void]$script:LastExchanges.Add($exch)
    while ($script:LastExchanges.Count -gt 8) { $script:LastExchanges.RemoveAt(0) }
    return [pscustomobject]@{ Resp = $resp; Line = $line; Json = $json; Ms = $sw.ElapsedMilliseconds; Exchange = $exch }
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}
function Test-RpcOk {
    param($Rpc)
    return ($null -ne $Rpc) -and ($null -ne $Rpc.Resp) -and ($Rpc.Resp.ok -eq $true)
}
function Get-RpcErrorCode {
    param($Rpc)
    if ($null -eq $Rpc) { return '' }
    $err = Get-Prop $Rpc.Resp 'error'
    if ($null -eq $err) { return '' }
    return [string](Get-Prop $err 'code' '')
}
function Get-RpcErrorMessage {
    param($Rpc)
    if ($null -eq $Rpc) { return '' }
    $err = Get-Prop $Rpc.Resp 'error'
    if ($null -eq $err) { return '' }
    return [string](Get-Prop $err 'message' '')
}
function Get-RpcResult {
    param($Rpc)
    if ($null -eq $Rpc) { return $null }
    return (Get-Prop $Rpc.Resp 'result' $null)
}

# ---------------------------------------------------------------------------------------------
# Accessibility-tree text parser (protocol tree format -> objects)
# ---------------------------------------------------------------------------------------------
function ConvertFrom-TreeLine {
    param([string]$Line)
    if ($Line -notmatch '^\s*\[(?<idx>\d+)\]\s+(?<type>[A-Za-z][A-Za-z0-9_]*)\s+"(?<name>(?:[^"\\]|\\.)*)"(?<rest>.*)$') { return $null }
    $idx = [int]$Matches['idx']
    $type = [string]$Matches['type']
    $nameRaw = [string]$Matches['name']
    $rest = [string]$Matches['rest']
    $name = $nameRaw
    if ($nameRaw.Length -gt 0) {
        try { $name = [string](ConvertFrom-Json -InputObject ('"' + $nameRaw + '"')) } catch { }
    }
    $id = ''
    $cls = ''
    $value = $null
    $rect = $null
    $flags = New-Object System.Collections.ArrayList
    if ($rest -match 'id=(?<v>\S+)') { $id = [string]$Matches['v'] }
    if ($rest -match 'class=(?<v>\S+)') { $cls = [string]$Matches['v'] }
    if ($rest -match 'value="(?<v>(?:[^"\\]|\\.)*)"') {
        $value = [string]$Matches['v']
        try { $value = [string](ConvertFrom-Json -InputObject ('"' + $value + '"')) } catch { }
    }
    if ($rest -match 'rect=(?<x>-?\d+),(?<y>-?\d+),(?<w>-?\d+),(?<h>-?\d+)') {
        $rect = [pscustomobject]@{ X = [int]$Matches['x']; Y = [int]$Matches['y']; Width = [int]$Matches['w']; Height = [int]$Matches['h'] }
    }
    if ($rest -match '(^|\s)password(\s|$)') { [void]$flags.Add('password') }
    if ($rest -match '(^|\s)disabled(\s|$)') { [void]$flags.Add('disabled') }
    if ($rest -match '(^|\s)offscreen(\s|$)') { [void]$flags.Add('offscreen') }
    return [pscustomobject]@{
        Index = $idx; Type = $type; Name = $name; Id = $id; Class = $cls
        Value = $value; Rect = $rect; Flags = @($flags); Line = $Line
    }
}

function Get-TreeElements {
    param([string]$Tree)
    $list = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrEmpty($Tree)) { return ,$list }
    foreach ($ln in ($Tree -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        $el = ConvertFrom-TreeLine -Line $ln
        if ($null -ne $el) { [void]$list.Add($el) }
    }
    return ,$list
}

function Find-TreeElement {
    param($Elements, [scriptblock]$Predicate)
    foreach ($el in $Elements) { if (& $Predicate $el) { return $el } }
    return $null
}

function Find-TreeElements {
    param($Elements, [scriptblock]$Predicate)
    $list = New-Object System.Collections.ArrayList
    foreach ($el in $Elements) { if (& $Predicate $el) { [void]$list.Add($el) } }
    return ,$list
}

function Get-Accessibility {
    param($Rpc)
    $result = Get-RpcResult $Rpc
    if ($null -eq $result) { return $null }
    return (Get-Prop $result 'accessibility' $null)
}

function Get-StateTree {
    param($Rpc)
    $acc = Get-Accessibility $Rpc
    if ($null -eq $acc) { return '' }
    return [string](Get-Prop $acc 'tree' '')
}

function Get-DocumentTextFromState {
    param($Rpc)
    $acc = Get-Accessibility $Rpc
    if ($null -eq $acc) { return $null }
    $dt = Get-Prop $acc 'document_text' $null
    if ($null -eq $dt) { return $null }
    return [string]$dt
}

# Returns the most reliable observation of the document text we can get from a state:
# document_text first, then the focused element line's value attr / name, then the
# Document/Edit tree node's value attr. Objects: Text + Source.
function Get-ObservedDocument {
    param($Rpc)
    $acc = Get-Accessibility $Rpc
    if ($null -eq $acc) { return [pscustomobject]@{ Text = $null; Source = 'none'; HasDocumentText = $false } }
    $dt = Get-Prop $acc 'document_text' $null
    $hasDoc = ($null -ne $dt)
    if ($hasDoc -and ([string]$dt).Length -gt 0) {
        return [pscustomobject]@{ Text = [string]$dt; Source = 'document_text'; HasDocumentText = $true }
    }
    $tree = [string](Get-Prop $acc 'tree' '')
    $elements = Get-TreeElements $tree
    $doc = Find-TreeElement $elements {
        param($e)
        ($e.Type -eq 'Document' -or $e.Type -eq 'Edit') -and ($null -ne $e.Value -and $e.Value.Length -gt 0)
    }
    if ($null -ne $doc) { return [pscustomobject]@{ Text = $doc.Value; Source = 'tree.value'; HasDocumentText = $hasDoc } }
    $fe = Get-Prop $acc 'focused_element' ''
    if (-not [string]::IsNullOrEmpty([string]$fe)) {
        $fel = ConvertFrom-TreeLine -Line ([string]$fe)
        if ($null -ne $fel -and $null -ne $fel.Value) { return [pscustomobject]@{ Text = $fel.Value; Source = 'focused_element.value'; HasDocumentText = $hasDoc } }
    }
    return [pscustomobject]@{ Text = $null; Source = 'none'; HasDocumentText = $hasDoc }
}

function Find-DocumentElement {
    param($Elements)
    $cands = Find-TreeElements $Elements {
        param($e)
        ($e.Type -eq 'Document' -or $e.Type -eq 'Edit') -and
        ($e.Flags -notcontains 'offscreen') -and ($e.Flags -notcontains 'disabled')
    }
    if ($cands.Count -eq 0) { return $null }
    $best = $null
    $bestArea = -1
    foreach ($c in $cands) {
        $area = 0
        if ($null -ne $c.Rect) { $area = [int64]$c.Rect.Width * [int64]$c.Rect.Height }
        if ($area -gt $bestArea) { $bestArea = $area; $best = $c }
    }
    return $best
}

function Find-AddTabButton {
    param($Elements)
    return (Find-TreeElement $Elements { param($e) $e.Type -eq 'Button' -and $e.Id -eq 'AddButton' })
}

# ---------------------------------------------------------------------------------------------
# Notepad session bookkeeping
# ---------------------------------------------------------------------------------------------
function Get-NotepadWindowFromList {
    param($ListResult, $PreferForegroundId = 0)
    if ($null -eq $ListResult) { return $null }
    $windows = @(Get-Prop $ListResult 'windows' @())
    $cands = @($windows | Where-Object {
            $pn = [string](Get-Prop $_ 'process_name' '')
            $pn -ieq 'notepad.exe'
        })
    if ($cands.Count -eq 0) { return $null }
    if ($PreferForegroundId -ne 0) {
        foreach ($c in $cands) { if ([long](Get-Prop $c 'window_id' 0) -eq [long]$PreferForegroundId) { return $c } }
    }
    return $cands[0]
}

function Get-WindowIdSet {
    param($ListResult)
    $set = New-Object 'System.Collections.Generic.HashSet[long]'
    if ($null -eq $ListResult) { return ,$set }
    foreach ($w in @(Get-Prop $ListResult 'windows' @())) {
        [void]$set.Add([long](Get-Prop $w 'window_id' 0))
    }
    return ,$set
}

function Find-WindowById {
    param($ListResult, [long]$WindowId)
    foreach ($w in @(Get-Prop $ListResult 'windows' @())) {
        if ([long](Get-Prop $w 'window_id' 0) -eq $WindowId) { return $w }
    }
    return $null
}

function Wait-For {
    param([scriptblock]$Condition, [int]$TimeoutMs = 8000, [int]$IntervalMs = 300)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        $value = & $Condition
        if ($null -ne $value -and $value -ne $false) { return $value }
        Start-Sleep -Milliseconds $IntervalMs
    } while ([DateTime]::UtcNow -lt $deadline)
    return $null
}

# ---------------------------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------------------------
function Stop-HelperProcess {
    param([switch]$SkipShutdown)
    if ($null -eq $script:Proc) { return }
    try {
        if (-not $SkipShutdown -and -not $script:ShutdownDone -and $script:HelperStarted) {
            try {
                if (-not $script:Proc.HasExited) {
                    [void](Send-Rpc -Method 'shutdown' -TimeoutMs 10000)
                    $script:ShutdownDone = $true
                }
            } catch {
                Add-Transcript ('# NOTE shutdown during cleanup failed: ' + $_.Exception.Message)
            }
        }
        if (-not $script:Proc.HasExited) {
            if ($script:Proc.WaitForExit(4000)) {
                $script:HelperExited = $true
                $script:HelperExitCode = $script:Proc.ExitCode
            } else {
                Add-Transcript '# NOTE helper did not exit after shutdown; killing process'
                try { $script:Proc.Kill() } catch { }
                try { [void]$script:Proc.WaitForExit(3000) } catch { }
                $script:HelperExited = $true
                try { $script:HelperExitCode = $script:Proc.ExitCode } catch { }
            }
        } else {
            $script:HelperExited = $true
            $script:HelperExitCode = $script:Proc.ExitCode
        }
    } finally {
        if ($null -ne $script:Stdin) { try { $script:Stdin.Dispose() } catch { } }
        $stderrText = ''
        try { $stderrText = [CuTestStderr]::Text() } catch { }
        if (-not [string]::IsNullOrEmpty($stderrText)) {
            try { Add-Content -LiteralPath $script:StderrPath -Value $stderrText -Encoding UTF8 -ErrorAction Stop } catch { }
        }
        if ($script:RequestCount -gt 0) {
            Add-Transcript ('# helper requests: ' + $script:RequestCount)
        }
    }
}

function Sync-LaunchedNotepadPids {
    $current = @(Get-Process notepad -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
    $new = @($current | Where-Object { $script:PreexistingNotepadPids -notcontains $_ })
    $script:NewNotepadPids = $new
}

function Stop-TestNotepad {
    # Kills ONLY notepad processes that did not exist before the test launched Notepad.
    # If a user Notepad session was already running we never kill it (we only closed our tab).
    Sync-LaunchedNotepadPids
    $killPids = New-Object System.Collections.ArrayList
    # Always target the exact window owner we tested plus the launcher stub returned by launch_app.
    $candidates = @([int]$script:MainNotepadPid, [int]$script:LaunchedNotepadStubPid)
    foreach ($cand in $candidates) {
        if ($cand -le 0) { continue }
        if ($script:PreexistingNotepadPids -contains $cand) { continue }
        if (-not $killPids.Contains($cand)) { [void]$killPids.Add($cand) }
    }
    # If Notepad was not running before the test, every notepad.exe now running was spawned by us.
    if (@($script:PreexistingNotepadPids).Count -eq 0) {
        foreach ($freshPid in @($script:NewNotepadPids)) {
            if (-not $killPids.Contains([int]$freshPid)) { [void]$killPids.Add([int]$freshPid) }
        }
    }
    if ($killPids.Count -eq 0) { return }
    foreach ($pidToKill in $killPids) {
        try {
            $p = Get-Process -Id $pidToKill -ErrorAction SilentlyContinue
            if ($null -ne $p) {
                try { Stop-Process -Id $pidToKill -Force -ErrorAction Stop; Add-Transcript ('# killed test notepad pid ' + $pidToKill) }
                catch { Add-Transcript ('# could not kill notepad pid ' + $pidToKill + ': ' + $_.Exception.Message) }
            }
        } catch { }
    }
}

# ---------------------------------------------------------------------------------------------
# Constants used by the assertions
# ---------------------------------------------------------------------------------------------
$script:Text1 = 'Hello, DSH computer use!'
$script:ZhText = '你好，DSH computer use！'
$script:ChecklistItems = @(
    [pscustomobject]@{ Id = '1'; Name = 'ping' },
    [pscustomobject]@{ Id = '2'; Name = 'launch_app notepad + list_windows' },
    [pscustomobject]@{ Id = '3'; Name = 'get_window_state screenshot + tree' },
    [pscustomobject]@{ Id = '4'; Name = 'click element + type_text + UTF-8 round-trip' },
    [pscustomobject]@{ Id = '5'; Name = 'press_key Ctrl+A + type replace' },
    [pscustomobject]@{ Id = '6'; Name = 'Ctrl+S Save dialog + Escape' },
    [pscustomobject]@{ Id = '7'; Name = 'Meta rejected with FORBIDDEN_KEY' },
    [pscustomobject]@{ Id = '8'; Name = 'stale state rejected with STALE_STATE' },
    [pscustomobject]@{ Id = '9'; Name = 'activate_window + coordinate click' },
    [pscustomobject]@{ Id = '10'; Name = 'scroll + cursor_position + set_value' },
    [pscustomobject]@{ Id = '11'; Name = 'shutdown exits cleanly' }
)
$script:CurrentItem = '0'
$script:DesktopUnavailable = $false

# ---------------------------------------------------------------------------------------------
# Small assertion helpers
# ---------------------------------------------------------------------------------------------
function Read-PngSize {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 24) { return $null }
    if (-not ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47)) { return $null }
    $w = ([int64]$bytes[16] -shl 24) -bor ([int64]$bytes[17] -shl 16) -bor ([int64]$bytes[18] -shl 8) -bor [int64]$bytes[19]
    $h = ([int64]$bytes[20] -shl 24) -bor ([int64]$bytes[21] -shl 16) -bor ([int64]$bytes[22] -shl 8) -bor [int64]$bytes[23]
    return [pscustomobject]@{ Width = [int]$w; Height = [int]$h }
}

function Get-FirstScreenshot {
    param($StateResult)
    if ($null -eq $StateResult) { return $null }
    $shots = @(Get-Prop $StateResult 'screenshots' @())
    if ($shots.Count -eq 0) { return $null }
    return $shots[0]
}

function ConvertTo-ScreenPoint {
    param($Screenshot, [double]$X, [double]$Y, [double]$IX = 1.0, [double]$IY = 1.0)
    $sx = [double](Get-Prop $Screenshot 'capture_scale_x' 1.0)
    $sy = [double](Get-Prop $Screenshot 'capture_scale_y' 1.0)
    $ox = [double](Get-Prop $Screenshot 'origin_x' 0)
    $oy = [double](Get-Prop $Screenshot 'origin_y' 0)
    return [pscustomobject]@{ X = [int][Math]::Round($ox + $X * $sx * $IX); Y = [int][Math]::Round($oy + $Y * $sy * $IY) }
}

function Get-WindowRect {
    param($Window)
    $rect = Get-Prop $Window 'rect' $null
    if ($null -eq $rect) { return $null }
    return [pscustomobject]@{ X = [int](Get-Prop $rect 'x' 0); Y = [int](Get-Prop $rect 'y' 0); Width = [int](Get-Prop $rect 'width' 0); Height = [int](Get-Prop $rect 'height' 0) }
}

function Get-StateString {
    param($Rpc)
    $result = Get-RpcResult $Rpc
    return [string](Get-Prop $result 'state_id' '')
}

function Test-Near {
    param([double]$A, [double]$B, [double]$Tolerance = 1.5)
    return ([Math]::Abs($A - $B) -le $Tolerance)
}

function Assert-EncodingSelfCheck {
    $expected = @(0x4F60, 0x597D, 0xFF0C, 0x0044, 0x0053, 0x0048, 0x0020, 0x0063, 0x006F, 0x006D, 0x0070, 0x0075, 0x0074, 0x0065, 0x0072, 0x0020, 0x0075, 0x0073, 0x0065, 0xFF01)
    $has = $false
    if ($script:ZhText.Length -eq $expected.Count) {
        $has = $true
        for ($i = 0; $i -lt $expected.Count; $i++) {
            if ([int]$script:ZhText[$i] -ne $expected[$i]) { $has = $false; break }
        }
    }
    Require-Check -Item '0' -Name 'test source encoding intact (UTF-8 BOM required for PS 5.1)' -Ok $has `
        -Detail ('ZhText length=' + $script:ZhText.Length + ' expected=20; re-save run-tests.ps1 as UTF-8 WITH BOM')
}

# ---------------------------------------------------------------------------------------------
# Checklist 1: ping
# ---------------------------------------------------------------------------------------------
function Invoke-Checklist1-Ping {
    $script:CurrentItem = '1'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Send-Rpc -Method 'ping' -TimeoutMs $PingTimeoutMs
    $sw.Stop()
    Add-Timing 'ping_first_spawn_and_compile' $sw.ElapsedMilliseconds
    Require-Check -Item '1' -Name 'ping returns ok:true' -Ok (Test-RpcOk $r) -Ms $sw.ElapsedMilliseconds `
        -Detail ('error=' + (Get-RpcErrorCode $r) + ' ' + (Get-RpcErrorMessage $r)) -Exchange @($r.Exchange)
    $res = Get-RpcResult $r
    $version = [string](Get-Prop $res 'version' '')
    $helperPid = Get-Prop $res 'pid' 0
    $dpiAware = Get-Prop $res 'dpi_aware' $false
    $vs = Get-Prop $res 'virtual_screen' $null
    $displays = @(Get-Prop $res 'displays' @())
    $fg = Get-Prop $res 'foreground_window_id' $null
    $secure = Get-Prop $res 'secure_desktop' $null
    $problems = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrEmpty($version)) { [void]$problems.Add('version missing') }
    if ($null -eq $helperPid -or [int64]$helperPid -le 0) { [void]$problems.Add('pid missing/invalid') }
    elseif ([int64]$helperPid -ne [int64]$script:Proc.Id) { [void]$problems.Add('pid != helper process pid') }
    if ($dpiAware -ne $true) { [void]$problems.Add('dpi_aware is not true') }
    if ($null -eq $vs) { [void]$problems.Add('virtual_screen missing') }
    else {
        if ([int](Get-Prop $vs 'width' 0) -le 0) { [void]$problems.Add('virtual_screen.width<=0') }
        if ([int](Get-Prop $vs 'height' 0) -le 0) { [void]$problems.Add('virtual_screen.height<=0') }
    }
    if ($displays.Count -lt 1) { [void]$problems.Add('displays empty') }
    foreach ($d in $displays) {
        if ([int](Get-Prop $d 'width' 0) -le 0) { [void]$problems.Add('display width<=0') }
        if ([int](Get-Prop $d 'height' 0) -le 0) { [void]$problems.Add('display height<=0') }
        $scale = Get-Prop $d 'scale_factor' $null
        if ($null -eq $scale -or [double]$scale -le 0) { [void]$problems.Add('display scale_factor invalid') }
        if ($null -eq (Get-Prop $d 'index' $null)) { [void]$problems.Add('display index missing') }
        if ($null -eq (Get-Prop $d 'primary' $null)) { [void]$problems.Add('display primary missing') }
    }
    if ($null -eq $fg) { [void]$problems.Add('foreground_window_id missing') }
    if ($null -eq $secure) { [void]$problems.Add('secure_desktop missing') }
    Add-Check -Item '1' -Name 'ping result shape (version/pid/dpi/virtual_screen/displays/foreground)' `
        -Ok ($problems.Count -eq 0) -Detail ($problems -join '; ') -Exchange @($r.Exchange)

    # interactive-desktop preflight
    if ($secure -eq $true) {
        $script:DesktopUnavailable = $true
        throw [CuTestAbort]::new('SECURE DESKTOP active (UAC prompt / secure desktop). UI automation tests skipped.')
    }
    if ($null -eq $fg -or [int64]$fg -eq 0) {
        $script:DesktopUnavailable = $true
        throw [CuTestAbort]::new('foreground_window_id is 0: interactive desktop possibly locked. UI automation tests skipped.')
    }
    Write-Line ('       displays: ' + (($displays | ForEach-Object { '{0}x{1}@x{2},y{3} scale={4}' -f (Get-Prop $_ 'width'), (Get-Prop $_ 'height'), (Get-Prop $_ 'x'), (Get-Prop $_ 'y'), (Get-Prop $_ 'scale_factor') }) -join '; '))
}

function Invoke-SetPolicy {
    $script:CurrentItem = '1'
    $params = [ordered]@{
        blocked_process_names       = @('cmd.exe', 'powershell.exe', 'pwsh.exe', 'conhost.exe', 'windowsterminal.exe', 'wt.exe', 'regedit.exe', 'taskmgr.exe', 'mmc.exe', 'control.exe', 'msconfig.exe', 'mstsc.exe', 'lockapp.exe', 'logonui.exe', 'useraccountcontrol.exe', 'credentialuibroker.exe', 'securityhealthsystray.exe', 'msmpeng.exe', 'deepseek harness.exe')
        blocked_app_ids             = @()
        blocked_window_class_names  = @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS')
        allow_win_key               = $false
    }
    $r = Send-Rpc -Method 'set_policy' -Params $params
    Add-Check -Item '1' -Name 'set_policy accepts protocol defaults' -Ok (Test-RpcOk $r) `
        -Detail ((Get-RpcErrorCode $r) + ' ' + (Get-RpcErrorMessage $r)) -Exchange @($r.Exchange)
}

# ---------------------------------------------------------------------------------------------
# Checklist 2: launch_app notepad.exe + list_windows
# ---------------------------------------------------------------------------------------------
function Invoke-Checklist2-LaunchNotepad {
    $script:CurrentItem = '2'
    $script:PreexistingNotepadPids = @(Get-Process notepad -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
    if ($script:PreexistingNotepadPids.Count -gt 0) {
        Write-Note ('pre-existing Notepad process(es) ' + ($script:PreexistingNotepadPids -join ',') + ' will NOT be killed; only our tab is used/closed.')
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $launch = Send-Rpc -Method 'launch_app' -Params ([ordered]@{ app = 'notepad.exe' }) -TimeoutMs 30000
    Sync-LaunchedNotepadPids
    $script:LaunchedNotepadStubPid = [int](Get-Prop (Get-RpcResult $launch) 'pid' 0)
    Add-Timing 'launch_app' $sw.ElapsedMilliseconds
    Require-Check -Item '2' -Name 'launch_app {app:notepad.exe} returns ok:true' -Ok (Test-RpcOk $launch) `
        -Detail ((Get-RpcErrorCode $launch) + ' ' + (Get-RpcErrorMessage $launch)) -Exchange @($launch.Exchange)
    $lr = Get-RpcResult $launch
    $resolved = [string](Get-Prop $lr 'resolved' '')
    $resolvedOk = ($resolved -like '*notepad.exe')
    Add-Check -Item '2' -Name 'launch_app resolved path points at notepad.exe' -Ok $resolvedOk -Detail ('resolved=' + $resolved) -Exchange @($launch.Exchange)

    # poll list_windows until a notepad window shows up
    $window = $null
    $listRpc = $null
    $listSw = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = [DateTime]::UtcNow.AddMilliseconds(12000)
    do {
        $listRpc = Send-Rpc -Method 'list_windows' -Params ([ordered]@{ visible_only = $true; include_minimized = $true; max = 200 })
        if (Test-RpcOk $listRpc) {
            $listResult = Get-RpcResult $listRpc
            $fgId = [long](Get-Prop $listResult 'foreground_window_id' 0)
            $window = Get-NotepadWindowFromList -ListResult $listResult -PreferForegroundId $fgId
        }
        if ($null -ne $window) { break }
        Start-Sleep -Milliseconds 350
    } while ([DateTime]::UtcNow -lt $deadline)
    $listSw.Stop()
    Add-Timing 'list_windows_after_launch' $listSw.ElapsedMilliseconds
    Require-Check -Item '2' -Name 'list_windows contains a window with process_name=notepad.exe' -Ok ($null -ne $window) `
        -Detail 'notepad window not found within 12s' -Exchange @($launch.Exchange, $listRpc.Exchange)
    $script:MainWindowId = [long](Get-Prop $window 'window_id' 0)
    $script:MainNotepadPid = [int](Get-Prop $window 'process_id' 0)
    Write-Line ('       notepad window_id={0} pid={1} title=[{2}]' -f $script:MainWindowId, $script:MainNotepadPid, (Get-Prop $window 'title' ''))

    # shape checks on the list_windows result + the notepad entry
    $listResult = Get-RpcResult $listRpc
    $windows = @(Get-Prop $listResult 'windows' @())
    $problems = New-Object System.Collections.ArrayList
    if ($windows.Count -lt 1) { [void]$problems.Add('windows empty') }
    if ($null -eq (Get-Prop $listResult 'foreground_window_id' $null)) { [void]$problems.Add('foreground_window_id missing') }
    foreach ($required in @('window_id', 'title', 'class_name', 'process_id', 'process_name', 'process_path', 'app_id', 'app_name', 'is_foreground', 'is_minimized', 'is_visible', 'rect', 'display_index', 'z_order', 'blocked')) {
        if ($null -eq (Get-Prop $window $required $null)) { [void]$problems.Add(('notepad window missing field ' + $required)) }
    }
    if ($windows.Count -gt 0 -and [int](Get-Prop $windows[0] 'z_order' -1) -ne 0) { [void]$problems.Add('windows[0].z_order != 0') }
    if ([string](Get-Prop $window 'process_name' '') -ine 'notepad.exe') { [void]$problems.Add('process_name != notepad.exe') }
    if ((Get-Prop $window 'blocked' $true) -ne $false) { [void]$problems.Add('notepad window blocked=true') }
    $rect = Get-WindowRect $window
    if ($null -eq $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { [void]$problems.Add('notepad window rect invalid') }
    Add-Check -Item '2' -Name 'list_windows entries expose the protocol fields (z_order/rect/app_id/blocked...)' `
        -Ok ($problems.Count -eq 0) -Detail ($problems -join '; ') -Exchange @($listRpc.Exchange)
}

# ---------------------------------------------------------------------------------------------
# Checklist 3: get_window_state (screenshot + tree)
# ---------------------------------------------------------------------------------------------
function Invoke-Checklist3-CaptureAndTree {
    $script:CurrentItem = '3'
    $params = [ordered]@{
        window_id            = $script:MainWindowId
        include_screenshot   = $true
        include_text         = $true
        include_document_text = $true
        max_depth            = 12
        max_elements         = 800
        max_text_chars       = 20000
        screenshot_max_width = 8192
        screenshot_max_height = 8192
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Send-Rpc -Method 'get_window_state' -Params $params -TimeoutMs 30000
    $sw.Stop()
    Add-Timing 'get_window_state_screenshot_plus_text' $sw.ElapsedMilliseconds
    Require-Check -Item '3' -Name 'get_window_state(screenshot+text) returns ok:true' -Ok (Test-RpcOk $r) -Ms $sw.ElapsedMilliseconds `
        -Detail ((Get-RpcErrorCode $r) + ' ' + (Get-RpcErrorMessage $r)) -Exchange @($r.Exchange)
    $res = Get-RpcResult $r
    $stateId = [string](Get-Prop $res 'state_id' '')
    $script:MainStateId = $stateId

    $problems = New-Object System.Collections.ArrayList
    if ($stateId -notmatch '^s-\d+$') { [void]$problems.Add('state_id not matching ^s-N (got "' + $stateId + '")') }
    $capturedAt = [string](Get-Prop $res 'captured_at' '')
    if ([string]::IsNullOrEmpty($capturedAt)) { [void]$problems.Add('captured_at missing') }
    $win = Get-Prop $res 'window' $null
    if ($null -eq $win) { [void]$problems.Add('window missing') }
    else {
        if ([long](Get-Prop $win 'window_id' 0) -ne $script:MainWindowId) { [void]$problems.Add('window.window_id mismatch') }
        $wrect = Get-WindowRect $win
        if ($null -eq $wrect -or $wrect.Width -le 0 -or $wrect.Height -le 0) { [void]$problems.Add('window.rect invalid') }
        if ($null -eq (Get-Prop $win 'is_foreground' $null)) { [void]$problems.Add('window.is_foreground missing') }
        if ($null -eq (Get-Prop $win 'is_minimized' $null)) { [void]$problems.Add('window.is_minimized missing') }
    }
    $shot = Get-FirstScreenshot $res
    if ($null -eq $shot) { [void]$problems.Add('screenshots empty') }
    else {
        $path = [string](Get-Prop $shot 'path' '')
        if ([string]::IsNullOrEmpty($path)) { [void]$problems.Add('screenshot.path empty') }
        elseif (-not (Test-Path -LiteralPath $path)) { [void]$problems.Add('screenshot file does not exist: ' + $path) }
        else {
            $png = Read-PngSize -Path $path
            if ($null -eq $png) { [void]$problems.Add('screenshot file is not a PNG (magic/IHDR)') }
            else {
                $rw = [int](Get-Prop $shot 'width' 0)
                $rh = [int](Get-Prop $shot 'height' 0)
                if ($rw -le 0 -or $rh -le 0) { [void]$problems.Add('screenshot width/height <= 0') }
                if ($png.Width -ne $rw -or $png.Height -ne $rh) { [void]$problems.Add(('reported {0}x{1} != PNG {2}x{3}' -f $rw, $rh, $png.Width, $png.Height)) }
                # DPI / coordinate consistency: image * capture_scale must equal the window frame size
                $scaleX = [double](Get-Prop $shot 'capture_scale_x' 0)
                $scaleY = [double](Get-Prop $shot 'capture_scale_y' 0)
                if ($scaleX -le 0 -or $scaleY -le 0) { [void]$problems.Add('capture_scale_x/y <= 0') }
                if ($null -ne $win) {
                    $wrect = Get-WindowRect $win
                    if ($null -ne $wrect) {
                        if (-not (Test-Near ($rw * $scaleX) $wrect.Width 1.5)) { [void]$problems.Add(('screenshot width*scale={0} != window rect width {1}' -f ($rw * $scaleX), $wrect.Width)) }
                        if (-not (Test-Near ($rh * $scaleY) $wrect.Height 1.5)) { [void]$problems.Add(('screenshot height*scale={0} != window rect height {1}' -f ($rh * $scaleY), $wrect.Height)) }
                        $ox = [double](Get-Prop $shot 'origin_x' 0)
                        $oy = [double](Get-Prop $shot 'origin_y' 0)
                        $method = [string](Get-Prop $shot 'capture_method' '')
                        if ($method -eq 'printwindow') {
                            if (-not (Test-Near $ox $wrect.X 1.5)) { [void]$problems.Add('origin_x != window rect x for printwindow') }
                            if (-not (Test-Near $oy $wrect.Y 1.5)) { [void]$problems.Add('origin_y != window rect y for printwindow') }
                        } elseif ($method -eq 'screen-bitblt') {
                            # clipped capture is allowed, but it must be inside the window frame
                            if ($ox -lt ($wrect.X - 1) -or $oy -lt ($wrect.Y - 1) -or ($ox + $rw * $scaleX) -gt ($wrect.X + $wrect.Width + 1) -or ($oy + $rh * $scaleY) -gt ($wrect.Y + $wrect.Height + 1)) {
                                [void]$problems.Add('screen-bitblt origin/size outside the window frame')
                            }
                        } else { [void]$problems.Add('capture_method not printwindow/screen-bitblt: ' + $method) }
                    }
                }
            }
        }
    }
    Add-Check -Item '3' -Name 'screenshot file exists, PNG magic/IHDR, dimensions & DPI origin consistent' `
        -Ok ($problems.Count -eq 0) -Detail ($problems -join '; ') -Exchange @($r.Exchange)
    if ($null -ne $shot) { Write-Line ('       screenshot: ' + (Get-Prop $shot 'path' '') + (' ({0}x{1} scale={2},{3} origin={4},{5} method={6})' -f (Get-Prop $shot 'width'), (Get-Prop $shot 'height'), (Get-Prop $shot 'capture_scale_x'), (Get-Prop $shot 'capture_scale_y'), (Get-Prop $shot 'origin_x'), (Get-Prop $shot 'origin_y'), (Get-Prop $shot 'capture_method'))) }

    $acc = Get-Accessibility $r
    $tree = Get-StateTree $r
    $accProblems = New-Object System.Collections.ArrayList
    if ($null -eq $acc) { [void]$accProblems.Add('accessibility is null although include_text=true') }
    else {
        if ([string]::IsNullOrEmpty($tree)) { [void]$accProblems.Add('tree empty') }
        else {
            if (-not $tree.EndsWith("`n")) { [void]$accProblems.Add('tree does not end with a newline') }
            if ($tree -notmatch '^\[0\] [A-Za-z]') { [void]$accProblems.Add('tree does not start with [0] ControlType') }
            $lineCount = 0
            foreach ($ln in ($tree -split "`n")) { if (-not [string]::IsNullOrWhiteSpace($ln)) { $lineCount++ } }
            $elements = Get-TreeElements $tree
            if ($elements.Count -lt 5) { [void]$accProblems.Add('tree has fewer than 5 elements') }
            $count = [int](Get-Prop $acc 'element_count' -1)
            if ($count -ne $elements.Count) { [void]$accProblems.Add(('element_count={0} != parsed lines {1}' -f $count, $elements.Count)) }
            for ($i = 0; $i -lt $elements.Count; $i++) {
                if ($elements[$i].Index -ne $i) { [void]$accProblems.Add(('element indices are not dense: position {0} has index {1}' -f $i, $elements[$i].Index)); break }
            }
            $doc = Find-DocumentElement $elements
            if ($null -eq $doc) { [void]$accProblems.Add('no enabled Document/Edit element in tree') }
            if ($null -eq (Get-Prop $acc 'focused_element' $null)) { [void]$accProblems.Add('focused_element missing') }
            if ($null -eq (Get-Prop $acc 'focused_is_password' $null)) { [void]$accProblems.Add('focused_is_password missing') }
            if ($null -eq (Get-Prop $acc 'selected_text' $null)) { [void]$accProblems.Add('selected_text missing') }
            if ($null -eq (Get-Prop $acc 'document_text' $null)) { [void]$accProblems.Add('document_text missing when include_document_text=true') }
            if ($null -eq (Get-Prop $acc 'truncated' $null)) { [void]$accProblems.Add('truncated missing') }
            if ($null -ne (Get-Prop $acc 'truncated' $false) -and (Get-Prop $acc 'truncated' $false) -eq $true) { Write-Note 'accessibility tree is marked truncated' }
        }
    }
    Add-Check -Item '3' -Name 'accessibility tree non-empty, dense indices from 0, protocol attributes present' `
        -Ok ($accProblems.Count -eq 0) -Detail ($accProblems -join '; ') -Exchange @($r.Exchange)

    $cursor = Get-Prop $res 'cursor' $null
    if ($null -eq $cursor -or $null -eq (Get-Prop $cursor 'x' $null) -or $null -eq (Get-Prop $cursor 'y' $null)) {
        Add-Check -Item '3' -Name 'cursor position present' -Ok $false -Detail 'cursor missing' -Exchange @($r.Exchange)
    }
}

# ---------------------------------------------------------------------------------------------
# Reusable window-state request for the main Notepad window
# ---------------------------------------------------------------------------------------------
function Request-MainState {
    param(
        [switch]$Screenshot,
        [switch]$Text,
        [switch]$DocText,
        [int]$MaxElements = 800,
        [int]$TimeoutMs = 30000
    )
    $params = [ordered]@{
        window_id          = $script:MainWindowId
        include_screenshot = [bool]$Screenshot
        include_text       = [bool]$Text
        max_elements       = $MaxElements
    }
    if ($DocText) { $params['include_document_text'] = $true }
    $r = Send-Rpc -Method 'get_window_state' -Params $params -TimeoutMs $TimeoutMs
    $script:LastStateRpc = $r
    if (Test-RpcOk $r) { $script:MainStateId = Get-StateString $r }
    return $r
}

function Normalize-DocText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.TrimEnd([char]13, [char]10)
}

function Get-ClickTarget {
    param($Screenshot, [double]$Fx = 0.5, [double]$Fy = 0.55)
    $w = [double](Get-Prop $Screenshot 'width' 0)
    $h = [double](Get-Prop $Screenshot 'height' 0)
    return (ConvertTo-ScreenPoint -Screenshot $Screenshot -X ($w * $Fx) -Y ($h * $Fy))
}

function Get-LatestDocObservation {
    param($StateRpc)
    return (Get-ObservedDocument $StateRpc)
}

# ---------------------------------------------------------------------------------------------
# Checklist 4: click an element (new tab), type ASCII + Chinese, verify round-trip
# ---------------------------------------------------------------------------------------------
function Invoke-Checklist4-TypeText {
    $script:CurrentItem = '4'
    $r = Request-MainState -Text -DocText
    Require-Check -Item '4' -Name 'get_window_state(text) for tab selection returns ok' -Ok (Test-RpcOk $r) `
        -Detail ((Get-RpcErrorCode $r) + ' ' + (Get-RpcErrorMessage $r)) -Exchange @($r.Exchange)
    $els = Get-TreeElements (Get-StateTree $r)
    $tabsBefore = (Find-TreeElements $els { param($e) $e.Type -eq 'TabItem' }).Count
    $addBtn = Find-AddTabButton $els
    Require-Check -Item '4' -Name 'tree exposes the Add-tab button (AutomationId=AddButton)' -Ok ($null -ne $addBtn) `
        -Detail 'AddButton not found in accessibility tree; cannot create an isolated blank document' -Exchange @($r.Exchange)

    $clickAdd = Send-Rpc -Method 'click' -Params ([ordered]@{ state_id = $script:MainStateId; element_index = $addBtn.Index; button = 'left'; click_count = 1 })
    Require-Check -Item '4' -Name ('click element_index={0} (Add tab) returns ok' -f $addBtn.Index) -Ok (Test-RpcOk $clickAdd) `
        -Detail ((Get-RpcErrorCode $clickAdd) + ' ' + (Get-RpcErrorMessage $clickAdd)) -Exchange @($clickAdd.Exchange)
    $r2 = Request-MainState -Text -DocText
    Require-Check -Item '4' -Name 're-observe after adding a tab returns ok' -Ok (Test-RpcOk $r2) `
        -Detail ((Get-RpcErrorCode $r2) + ' ' + (Get-RpcErrorMessage $r2)) -Exchange @($r2.Exchange)
    $els2 = Get-TreeElements (Get-StateTree $r2)
    $tabsAfter = (Find-TreeElements $els2 { param($e) $e.Type -eq 'TabItem' }).Count
    Add-Check -Item '4' -Name ('new tab created (TabItem count {0} -> {1})' -f $tabsBefore, $tabsAfter) -Ok ($tabsAfter -gt $tabsBefore) `
        -Detail 'TabItem count did not increase after clicking AddButton' -Exchange @($r2.Exchange)

    $docEl = Find-DocumentElement $els2
    Require-Check -Item '4' -Name 'tree exposes the editable Document/Edit element' -Ok ($null -ne $docEl) `
        -Detail 'document element not found' -Exchange @($r2.Exchange)
    $clickDoc = Send-Rpc -Method 'click' -Params ([ordered]@{ state_id = $script:MainStateId; element_index = $docEl.Index; button = 'left'; click_count = 1 })
    Require-Check -Item '4' -Name ('click element_index={0} (document) returns ok' -f $docEl.Index) -Ok (Test-RpcOk $clickDoc) `
        -Detail ((Get-RpcErrorCode $clickDoc) + ' ' + (Get-RpcErrorMessage $clickDoc)) -Exchange @($clickDoc.Exchange)

    # safety gate: only type into a document we can prove is blank
    $r3 = Request-MainState -Text -DocText
    Require-Check -Item '4' -Name 're-observe after focusing document returns ok' -Ok (Test-RpcOk $r3) `
        -Detail ((Get-RpcErrorCode $r3) + ' ' + (Get-RpcErrorMessage $r3)) -Exchange @($r3.Exchange)
    $obs = Get-ObservedDocument $r3
    $blank = (Normalize-DocText $obs.Text).Length -eq 0
    Require-Check -Item '4' -Name 'SAFETY: document_text available and the focused document is blank before typing' `
        -Ok ($obs.HasDocumentText -and $blank) `
        -Detail ('HasDocumentText={0} source={1} text=["{2}"]' -f $obs.HasDocumentText, $obs.Source, (Normalize-DocText $obs.Text)) `
        -Exchange @($r3.Exchange)

    $type1 = Send-Rpc -Method 'type_text' -Params ([ordered]@{ state_id = $script:MainStateId; text = $script:Text1 }) -TimeoutMs 30000
    Require-Check -Item '4' -Name ('type_text ASCII text returns ok (result.focused_element present)') -Ok ((Test-RpcOk $type1) -and ($null -ne (Get-Prop (Get-RpcResult $type1) 'focused_element' $null))) `
        -Detail ((Get-RpcErrorCode $type1) + ' ' + (Get-RpcErrorMessage $type1)) -Exchange @($type1.Exchange)

    $r4 = Request-MainState -Text -DocText
    Require-Check -Item '4' -Name 're-observe after typing ASCII returns ok' -Ok (Test-RpcOk $r4) `
        -Detail ((Get-RpcErrorCode $r4) + ' ' + (Get-RpcErrorMessage $r4)) -Exchange @($r4.Exchange)
    $obs4 = Get-ObservedDocument $r4
    $got4 = Normalize-DocText $obs4.Text
    Add-Check -Item '4' -Name 're-observed text equals the typed ASCII text exactly' -Ok ($got4 -ceq $script:Text1) `
        -Detail ('expected="' + $script:Text1 + '" got="' + $got4 + '" via ' + $obs4.Source) -Exchange @($r4.Exchange, $type1.Exchange)

    # UTF-8 round-trip: type Chinese + full-width punctuation through JSON in AND out
    $type2 = Send-Rpc -Method 'type_text' -Params ([ordered]@{ state_id = $script:MainStateId; text = $script:ZhText }) -TimeoutMs 30000
    Require-Check -Item '4' -Name 'type_text Chinese text returns ok' -Ok (Test-RpcOk $type2) `
        -Detail ((Get-RpcErrorCode $type2) + ' ' + (Get-RpcErrorMessage $type2)) -Exchange @($type2.Exchange)
    $r5 = Request-MainState -Text -DocText
    Require-Check -Item '4' -Name 're-observe after typing Chinese returns ok' -Ok (Test-RpcOk $r5) `
        -Detail ((Get-RpcErrorCode $r5) + ' ' + (Get-RpcErrorMessage $r5)) -Exchange @($r5.Exchange)
    $obs5 = Get-ObservedDocument $r5
    $got5 = Normalize-DocText $obs5.Text
    $expected5 = $script:Text1 + $script:ZhText
    Add-Check -Item '4' -Name 'UTF-8 round-trip: Chinese text survives JSON in/out and SendInput exactly' -Ok ($got5 -ceq $expected5) `
        -Detail ('expected="' + $expected5 + '" got="' + $got5 + '" via ' + $obs5.Source) -Exchange @($r5.Exchange)
    $script:LastKnownBuffer = $got5
}

# ---------------------------------------------------------------------------------------------
# Checklist 5: Ctrl+A then type replacement
# ---------------------------------------------------------------------------------------------
function Invoke-Checklist5-SelectReplace {
    $script:CurrentItem = '5'
    $r = Request-MainState -Text -DocText
    Require-Check -Item '5' -Name 'get_window_state before Ctrl+A returns ok' -Ok (Test-RpcOk $r) `
        -Detail ((Get-RpcErrorCode $r) + ' ' + (Get-RpcErrorMessage $r)) -Exchange @($r.Exchange)
    $stateId = $script:MainStateId
    $pk = Send-Rpc -Method 'press_key' -Params ([ordered]@{ state_id = $stateId; key = 'Control_L+a' })
    Require-Check -Item '5' -Name 'press_key Control_L+a returns ok' -Ok (Test-RpcOk $pk) `
        -Detail ((Get-RpcErrorCode $pk) + ' ' + (Get-RpcErrorMessage $pk)) -Exchange @($pk.Exchange)
    $tt = Send-Rpc -Method 'type_text' -Params ([ordered]@{ state_id = $stateId; text = 'replaced' }) -TimeoutMs 30000
    Require-Check -Item '5' -Name 'type_text replacement returns ok' -Ok (Test-RpcOk $tt) `
        -Detail ((Get-RpcErrorCode $tt) + ' ' + (Get-RpcErrorMessage $tt)) -Exchange @($tt.Exchange)
    $r2 = Request-MainState -Text -DocText
    Require-Check -Item '5' -Name 'get_window_state after replacement returns ok' -Ok (Test-RpcOk $r2) `
        -Detail ((Get-RpcErrorCode $r2) + ' ' + (Get-RpcErrorMessage $r2)) -Exchange @($r2.Exchange)
    $obs = Get-ObservedDocument $r2
    $got = Normalize-DocText $obs.Text
    Add-Check -Item '5' -Name 'select-all + type_text replaced the whole document' -Ok ($got -ceq 'replaced') `
        -Detail ('expected="replaced" got="' + $got + '" via ' + $obs.Source) -Exchange @($r2.Exchange, $tt.Exchange)
    $script:LastKnownBuffer = $got
}

# ---------------------------------------------------------------------------------------------
# Checklist 6: Ctrl+S opens the Save As dialog; Escape closes it
# ---------------------------------------------------------------------------------------------
function Invoke-Checklist6-SaveDialog {
    $script:CurrentItem = '6'
    $r = Request-MainState -Text -DocText
    Require-Check -Item '6' -Name 'get_window_state before Ctrl+S returns ok' -Ok (Test-RpcOk $r) `
        -Detail ((Get-RpcErrorCode $r) + ' ' + (Get-RpcErrorMessage $r)) -Exchange @($r.Exchange)
    $stateId = $script:MainStateId
    $list0 = Send-Rpc -Method 'list_windows' -Params ([ordered]@{ visible_only = $true; include_minimized = $true; max = 200 })
    Require-Check -Item '6' -Name 'list_windows before Ctrl+S returns ok' -Ok (Test-RpcOk $list0) `
        -Detail ((Get-RpcErrorCode $list0) + ' ' + (Get-RpcErrorMessage $list0)) -Exchange @($list0.Exchange)
    $idsBefore = Get-WindowIdSet (Get-RpcResult $list0)
    $notepadPid = $script:MainNotepadPid

    $pk = Send-Rpc -Method 'press_key' -Params ([ordered]@{ state_id = $stateId; key = 'Control_L+s' })
    Add-Check -Item '6' -Name 'press_key Control_L+s returns ok' -Ok (Test-RpcOk $pk) `
        -Detail ((Get-RpcErrorCode $pk) + ' ' + (Get-RpcErrorMessage $pk)) -Exchange @($pk.Exchange)

    $dialog = Wait-For -TimeoutMs 10000 -IntervalMs 300 -Condition {
        $lr = Send-Rpc -Method 'list_windows' -Params ([ordered]@{ visible_only = $true; include_minimized = $true; max = 200 })
        if (-not (Test-RpcOk $lr)) { return $null }
        $script:LastDialogList = $lr
        $res = Get-RpcResult $lr
        foreach ($w in @(Get-Prop $res 'windows' @())) {
            $wid = [long](Get-Prop $w 'window_id' 0)
            if ($idsBefore.Contains($wid)) { continue }
            if ([int](Get-Prop $w 'process_id' 0) -ne $notepadPid) { continue }
            if ((Get-Prop $w 'is_visible' $true) -ne $true) { continue }
            return $w
        }
        return $null
    }
    $newWindows = ''
    if ($null -ne $script:LastDialogList) {
        $after = Get-WindowIdSet (Get-RpcResult $script:LastDialogList)
        $newList = @()
        foreach ($w in @(Get-Prop (Get-RpcResult $script:LastDialogList) 'windows' @())) {
            $wid = [long](Get-Prop $w 'window_id' 0)
            if (-not $idsBefore.Contains($wid)) { $newList += ('window_id={0} pid={1} title=[{2}] class={3}' -f $wid, (Get-Prop $w 'process_id'), (Get-Prop $w 'title'), (Get-Prop $w 'class_name')) }
        }
        $newWindows = $newList -join '; '
    }
    Require-Check -Item '6' -Name 'Ctrl+S opened a new top-level (Save As) window for the notepad process' -Ok ($null -ne $dialog) `
        -Detail ('new windows: ' + $newWindows) -Exchange @(@($pk.Exchange) + @($script:LastDialogList.Exchange))

    $dialogId = [long](Get-Prop $dialog 'window_id' 0)
    $dialogTitle = [string](Get-Prop $dialog 'title' '')
    Write-Line ('       save dialog: window_id={0} title=[{1}] class={2}' -f $dialogId, $dialogTitle, (Get-Prop $dialog 'class_name' ''))
    $rDlg = Send-Rpc -Method 'get_window_state' -Params ([ordered]@{ window_id = $dialogId; include_screenshot = $false; include_text = $true; max_elements = 300 }) -TimeoutMs 20000
    Require-Check -Item '6' -Name 'get_window_state on the Save As dialog returns ok' -Ok (Test-RpcOk $rDlg) `
        -Detail ((Get-RpcErrorCode $rDlg) + ' ' + (Get-RpcErrorMessage $rDlg)) -Exchange @($rDlg.Exchange)
    $dialogStateId = Get-StateString $rDlg
    $esc = Send-Rpc -Method 'press_key' -Params ([ordered]@{ state_id = $dialogStateId; key = 'Escape' })
    Add-Check -Item '6' -Name 'press_key Escape on the dialog returns ok' -Ok (Test-RpcOk $esc) `
        -Detail ((Get-RpcErrorCode $esc) + ' ' + (Get-RpcErrorMessage $esc)) -Exchange @($esc.Exchange)
    $closed = Wait-For -TimeoutMs 8000 -IntervalMs 300 -Condition {
        $lr = Send-Rpc -Method 'list_windows' -Params ([ordered]@{ visible_only = $true; include_minimized = $true; max = 200 })
        if (-not (Test-RpcOk $lr)) { return $null }
        $script:LastDialogList = $lr
        $w = Find-WindowById (Get-RpcResult $lr) $dialogId
        if ($null -eq $w) { return $true }
        return $null
    }
    Add-Check -Item '6' -Name 'Escape closed the Save As dialog (window no longer listed)' -Ok ($closed -eq $true) `
        -Detail 'dialog window still present after Escape' -Exchange @($script:LastDialogList.Exchange)
    # the notepad document must still be intact after cancelling the dialog
    $rAfter = Request-MainState -Text -DocText
    if (Test-RpcOk $rAfter) {
        $obs = Get-ObservedDocument $rAfter
        $got = Normalize-DocText $obs.Text
        Add-Check -Item '6' -Name 'document still contains the replaced text after cancelling Save As' -Ok ($got -ceq 'replaced') `
            -Detail ('expected="replaced" got="' + $got + '"') -Exchange @($rAfter.Exchange)
    }
}

# ---------------------------------------------------------------------------------------------
# Checklist 7: forbidden Meta key
# ---------------------------------------------------------------------------------------------
function Invoke-Checklist7-ForbiddenKey {
    $script:CurrentItem = '7'
    $r = Request-MainState -Text
    Require-Check -Item '7' -Name 'get_window_state before forbidden-key test returns ok' -Ok (Test-RpcOk $r) `
        -Detail ((Get-RpcErrorCode $r) + ' ' + (Get-RpcErrorMessage $r)) -Exchange @($r.Exchange)
    $pk = Send-Rpc -Method 'press_key' -Params ([ordered]@{ state_id = $script:MainStateId; key = 'Meta' })
    $code = Get-RpcErrorCode $pk
    Add-Check -Item '7' -Name 'press_key Meta is rejected with error.code=FORBIDDEN_KEY' -Ok (($pk.Resp.ok -eq $false) -and ($code -eq 'FORBIDDEN_KEY')) `
        -Detail ('ok=' + $pk.Resp.ok + ' code=' + $code + ' resp=' + $pk.Line) -Exchange @($pk.Exchange)
    $pk2 = Send-Rpc -Method 'press_key' -Params ([ordered]@{ state_id = $script:MainStateId; key = 'Control_L+Alt_L+Delete' })
    $code2 = Get-RpcErrorCode $pk2
    Add-Check -Item '7' -Name 'press_key Ctrl+Alt+Delete is rejected with FORBIDDEN_KEY' -Ok (($pk2.Resp.ok -eq $false) -and ($code2 -eq 'FORBIDDEN_KEY')) `
        -Detail ('ok=' + $pk2.Resp.ok + ' code=' + $code2) -Exchange @($pk2.Exchange)
    $ping = Send-Rpc -Method 'ping'
    Add-Check -Item '7' -Name 'helper still responsive after forbidden-key rejections' -Ok (Test-RpcOk $ping) -Exchange @($ping.Exchange)
}

# ---------------------------------------------------------------------------------------------
# Checklist 8: stale state invalidation
# ---------------------------------------------------------------------------------------------
function Invoke-Checklist8-StaleState {
    $script:CurrentItem = '8'
    $rA = Request-MainState -Text
    Require-Check -Item '8' -Name 'first get_window_state returns ok' -Ok (Test-RpcOk $rA) `
        -Detail ((Get-RpcErrorCode $rA) + ' ' + (Get-RpcErrorMessage $rA)) -Exchange @($rA.Exchange)
    $stateA = Get-StateString $rA
    $elsA = Get-TreeElements (Get-StateTree $rA)
    $docA = Find-DocumentElement $elsA
    Require-Check -Item '8' -Name 'first state contains a Document element to click' -Ok ($null -ne $docA) `
        -Detail 'document not found in first state tree' -Exchange @($rA.Exchange)
    $rB = Request-MainState -Text
    Require-Check -Item '8' -Name 'second get_window_state returns ok' -Ok (Test-RpcOk $rB) `
        -Detail ((Get-RpcErrorCode $rB) + ' ' + (Get-RpcErrorMessage $rB)) -Exchange @($rB.Exchange)
    $stateB = Get-StateString $rB
    Add-Check -Item '8' -Name ('second observation produced a different state_id (' + $stateA + ' -> ' + $stateB + ')') -Ok ($stateA -ne $stateB) `
        -Detail 'state_id did not change' -Exchange @($rB.Exchange)
    $clickOld = Send-Rpc -Method 'click' -Params ([ordered]@{ state_id = $stateA; element_index = $docA.Index })
    $codeOld = Get-RpcErrorCode $clickOld
    Add-Check -Item '8' -Name 'click with the invalidated state_id is rejected with STALE_STATE' -Ok (($clickOld.Resp.ok -eq $false) -and ($codeOld -eq 'STALE_STATE')) `
        -Detail ('ok=' + $clickOld.Resp.ok + ' code=' + $codeOld + ' ctx=' + $clickOld.Line) -Exchange @($clickOld.Exchange)
    $clickUnknown = Send-Rpc -Method 'click' -Params ([ordered]@{ state_id = 's-999999'; element_index = 0 })
    $codeUnknown = Get-RpcErrorCode $clickUnknown
    Add-Check -Item '8' -Name 'click with an unknown state_id is rejected with STALE_STATE' -Ok (($clickUnknown.Resp.ok -eq $false) -and ($codeUnknown -eq 'STALE_STATE')) `
        -Detail ('ok=' + $clickUnknown.Resp.ok + ' code=' + $codeUnknown) -Exchange @($clickUnknown.Exchange)
}

# ---------------------------------------------------------------------------------------------
# Checklist 9: activate_window + coordinate click
# ---------------------------------------------------------------------------------------------
function Invoke-Checklist9-ActivateCoordinate {
    $script:CurrentItem = '9'
    $act = Send-Rpc -Method 'activate_window' -Params ([ordered]@{ window_id = $script:MainWindowId })
    $actRes = Get-RpcResult $act
    $echoOk = ($null -ne $actRes) -and ([long](Get-Prop $actRes 'window_id' 0) -eq $script:MainWindowId) -and ($null -ne (Get-Prop $actRes 'title' $null))
    Add-Check -Item '9' -Name 'activate_window returns ok:true and echoes window_id/title' -Ok ((Test-RpcOk $act) -and $echoOk) `
        -Detail ((Get-RpcErrorCode $act) + ' ' + (Get-RpcErrorMessage $act)) -Exchange @($act.Exchange)

    $rC = Request-MainState -Screenshot
    Require-Check -Item '9' -Name 'get_window_state(screenshot) for coordinate click returns ok' -Ok (Test-RpcOk $rC) `
        -Detail ((Get-RpcErrorCode $rC) + ' ' + (Get-RpcErrorMessage $rC)) -Exchange @($rC.Exchange)
    $shot = Get-FirstScreenshot (Get-RpcResult $rC)
    Require-Check -Item '9' -Name 'coordinate-click state has a screenshot with origin/scale' -Ok ($null -ne $shot) `
        -Detail 'screenshots array empty' -Exchange @($rC.Exchange)
    $pt = Get-ClickTarget -Screenshot $shot -Fx 0.5 -Fy 0.58
    $click = Send-Rpc -Method 'click' -Params ([ordered]@{
            state_id   = $script:MainStateId
            x          = $pt.X
            y          = $pt.Y
            image_scale = [ordered]@{ x = 1.0; y = 1.0 }
            button     = 'left'
            click_count = 1
        })
    $target = [string](Get-Prop (Get-RpcResult $click) 'target' '')
    Add-Check -Item '9' -Name ('coordinate click accepted (screen {0},{1}) and target reported' -f $pt.X, $pt.Y) -Ok ((Test-RpcOk $click) -and ($target.Length -gt 0)) `
        -Detail ((Get-RpcErrorCode $click) + ' ' + (Get-RpcErrorMessage $click)) -Exchange @($click.Exchange)
    $ping = Send-Rpc -Method 'ping'
    Add-Check -Item '9' -Name 'helper still responsive after coordinate click' -Ok (Test-RpcOk $ping) -Exchange @($ping.Exchange)
}

# ---------------------------------------------------------------------------------------------
# Checklist 10: scroll, cursor_position, set_value
# ---------------------------------------------------------------------------------------------
function Invoke-Checklist10-ScrollCursorSetValue {
    $script:CurrentItem = '10'
    $rD = Request-MainState -Screenshot -Text
    Require-Check -Item '10' -Name 'get_window_state(screenshot+text) before scroll returns ok' -Ok (Test-RpcOk $rD) `
        -Detail ((Get-RpcErrorCode $rD) + ' ' + (Get-RpcErrorMessage $rD)) -Exchange @($rD.Exchange)
    $shot = Get-FirstScreenshot (Get-RpcResult $rD)
    Require-Check -Item '10' -Name 'state for scroll has a screenshot with origin/scale' -Ok ($null -ne $shot) -Detail 'screenshots empty' -Exchange @($rD.Exchange)
    $scroll = Send-Rpc -Method 'scroll' -Params ([ordered]@{
            state_id    = $script:MainStateId
            x           = [int](Get-Prop $shot 'width' 0) / 2
            y           = [int](Get-Prop $shot 'height' 0) / 2
            scroll_x    = 0
            scroll_y    = 600
            image_scale = [ordered]@{ x = 1.0; y = 1.0 }
        })
    $scrolled = [string](Get-Prop (Get-RpcResult $scroll) 'scrolled' '')
    Add-Check -Item '10' -Name 'scroll returns ok:true with a scrolled description' -Ok ((Test-RpcOk $scroll) -and ($scrolled.Length -gt 0)) `
        -Detail ((Get-RpcErrorCode $scroll) + ' ' + (Get-RpcErrorMessage $scroll)) -Exchange @($scroll.Exchange)

    $cursor = Send-Rpc -Method 'cursor_position'
    $cres = Get-RpcResult $cursor
    $cOk = ($null -ne $cres) -and ($null -ne (Get-Prop $cres 'x' $null)) -and ($null -ne (Get-Prop $cres 'y' $null)) -and ($null -ne (Get-Prop $cres 'foreground_window_id' $null))
    Add-Check -Item '10' -Name 'cursor_position returns numeric x/y and foreground_window_id' -Ok ((Test-RpcOk $cursor) -and $cOk) `
        -Detail ('resp=' + $cursor.Line) -Exchange @($cursor.Exchange)

    $elsD = Get-TreeElements (Get-StateTree $rD)
    $docD = Find-DocumentElement $elsD
    Require-Check -Item '10' -Name 'state exposes a Document/Edit element for set_value' -Ok ($null -ne $docD) `
        -Detail 'document element not found' -Exchange @($rD.Exchange)
    $sv = Send-Rpc -Method 'set_value' -Params ([ordered]@{ state_id = $script:MainStateId; element_index = $docD.Index; value = 'set via ValuePattern' }) -TimeoutMs 20000
    $svOk = Test-RpcOk $sv
    $svCode = Get-RpcErrorCode $sv
    Add-Check -Item '10' -Name 'set_value succeeds via ValuePattern or returns ELEMENT_UNSUPPORTED (no crash)' -Ok ($svOk -or ($svCode -eq 'ELEMENT_UNSUPPORTED')) `
        -Detail ('ok=' + $sv.Resp.ok + ' code=' + $svCode + ' msg=' + (Get-RpcErrorMessage $sv)) -Exchange @($sv.Exchange)
    if ($svOk) {
        $rE = Request-MainState -Text -DocText
        if (Test-RpcOk $rE) {
            $obs = Get-ObservedDocument $rE
            $got = Normalize-DocText $obs.Text
            $hasSet = $got -like '*set via ValuePattern*'
            Add-Check -Item '10' -Name 'set_value value is visible in the document afterwards' -Ok $hasSet `
                -Detail ('got="' + $got + '"') -Exchange @($rE.Exchange)
            $script:LastKnownBuffer = $got
        }
    } else {
        $script:LastKnownBuffer = 'replaced'
    }
}

# ---------------------------------------------------------------------------------------------
# Best-effort cleanup of our tab when a user Notepad session was already running
# ---------------------------------------------------------------------------------------------
function Close-OurTabIfSharedSession {
    if (@($script:PreexistingNotepadPids).Count -eq 0) {
        Write-Note 'Notepad was not running before the test; the instance is ours and will be killed (no tab cleanup needed).'
        return
    }
    try {
        $r = Request-MainState -Text -DocText -TimeoutMs 15000
        if (-not (Test-RpcOk $r)) { Write-Note 'tab cleanup skipped: cannot observe Notepad window'; return }
        $els = Get-TreeElements (Get-StateTree $r)
        $tabsBefore = (Find-TreeElements $els { param($e) $e.Type -eq 'TabItem' }).Count
        $doc = Find-DocumentElement $els
        if ($null -eq $doc) { Write-Note 'tab cleanup skipped: document element not found'; return }
        # Safety: only clean up if the active buffer is the one our tests produced.
        $obs = Get-ObservedDocument $r
        $buf = Normalize-DocText $obs.Text
        $known = @('replaced', 'set via ValuePattern', ($script:Text1 + $script:ZhText))
        $recognized = $false
        foreach ($k in $known) { if ($buf -ceq $k) { $recognized = $true; break } }
        if (-not $recognized) {
            Write-Note ('tab cleanup skipped: active buffer is not our test buffer ("' + $buf.Substring(0, [Math]::Min(40, $buf.Length)) + '")')
            return
        }
        $click = Send-Rpc -Method 'click' -Params ([ordered]@{ state_id = $script:MainStateId; element_index = $doc.Index })
        if (-not (Test-RpcOk $click)) { Write-Note 'tab cleanup skipped: could not focus document'; return }
        [void](Send-Rpc -Method 'press_key' -Params ([ordered]@{ state_id = $script:MainStateId; key = 'Control_L+a' }))
        [void](Send-Rpc -Method 'press_key' -Params ([ordered]@{ state_id = $script:MainStateId; key = 'Delete' }))
        for ($i = 0; $i -lt 25; $i++) {
            $u = Send-Rpc -Method 'press_key' -Params ([ordered]@{ state_id = $script:MainStateId; key = 'Control_L+z' })
            if (-not (Test-RpcOk $u)) { break }
        }
        Start-Sleep -Milliseconds 300
        $r2 = Request-MainState -Text -DocText -TimeoutMs 15000
        if (-not (Test-RpcOk $r2)) { Write-Note 'tab cleanup skipped: re-observe failed'; return }
        $buf2 = Normalize-DocText (Get-ObservedDocument $r2).Text
        if ($buf2.Length -ne 0) { Write-Note 'tab cleanup skipped: buffer not pristine after undo; leaving tab open'; return }
        $listBefore = Send-Rpc -Method 'list_windows' -Params ([ordered]@{ visible_only = $true; include_minimized = $true; max = 200 })
        $idsBefore = Get-WindowIdSet (Get-RpcResult $listBefore)
        $cw = Send-Rpc -Method 'press_key' -Params ([ordered]@{ state_id = $script:MainStateId; key = 'Control_L+w' })
        if (-not (Test-RpcOk $cw)) { Write-Note 'tab cleanup: Ctrl+W failed; leaving tab open'; return }
        Start-Sleep -Milliseconds 700
        # cancel a possible "save changes?" prompt and detect whether the tab closed
        $listR = Send-Rpc -Method 'list_windows' -Params ([ordered]@{ visible_only = $true; include_minimized = $true; max = 200 })
        if (Test-RpcOk $listR) {
            foreach ($w in @(Get-Prop (Get-RpcResult $listR) 'windows' @())) {
                $wid = [long](Get-Prop $w 'window_id' 0)
                if ($idsBefore.Contains($wid)) { continue }
                if ([int](Get-Prop $w 'process_id' 0) -ne $script:MainNotepadPid) { continue }
                Write-Note ('tab cleanup: a prompt appeared after Ctrl+W (window_id=' + $wid + ' title=[' + (Get-Prop $w 'title' '') + ']); cancelling it')
                $rP = Send-Rpc -Method 'get_window_state' -Params ([ordered]@{ window_id = $wid; include_screenshot = $false; include_text = $false })
                if (Test-RpcOk $rP) {
                    [void](Send-Rpc -Method 'press_key' -Params ([ordered]@{ state_id = (Get-StateString $rP); key = 'Escape' }))
                }
                return
            }
        }
        $r3 = Request-MainState -Text
        if (Test-RpcOk $r3) {
            $tabsAfter = (Find-TreeElements (Get-TreeElements (Get-StateTree $r3)) { param($e) $e.Type -eq 'TabItem' }).Count
            if ($tabsAfter -lt $tabsBefore) { Write-Note ('tab cleanup: closed our tab in the shared Notepad instance (tabs {0} -> {1})' -f $tabsBefore, $tabsAfter) }
            else { Write-Note 'tab cleanup: Ctrl+W did not close the tab (left open, unsaved buffer was empty)' }
        }
    } catch {
        Write-Note ('tab cleanup failed: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------------------------
# Checklist 11: 30 sequential requests + shutdown
# ---------------------------------------------------------------------------------------------
function Invoke-Checklist11-Shutdown {
    $script:CurrentItem = '11'
    Close-OurTabIfSharedSession
    $script:CurrentItem = '11'

    $latencies = New-Object System.Collections.ArrayList
    $allOk = $true
    $failedPing = $null
    $pingSw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le 30; $i++) {
        $p = Send-Rpc -Method 'ping' -TimeoutMs 10000
        if (-not (Test-RpcOk $p)) { $allOk = $false; $failedPing = $p; break }
        [void]$latencies.Add([long]$p.Ms)
    }
    $pingSw.Stop()
    $total = $latencies.Count
    $avg = 0; $min = 0; $max = 0
    if ($total -gt 0) {
        $avg = [int](($latencies | Measure-Object -Average).Average)
        $min = [int](($latencies | Measure-Object -Minimum).Minimum)
        $max = [int](($latencies | Measure-Object -Maximum).Maximum)
    }
    Add-Timing 'ping_warm_min' $min
    Add-Timing 'ping_warm_avg' $avg
    Add-Timing 'ping_warm_max' $max
    $exchange = $null
    if ($null -ne $failedPing) { $exchange = @($failedPing.Exchange) }
    Add-Check -Item '11' -Name ('helper survives 30 sequential ping requests (count={0}, avg={1}ms min={2}ms max={3}ms)' -f $total, $avg, $min, $max) -Ok $allOk `
        -Detail 'a ping failed mid-loop' -Exchange $exchange

    $sh = Send-Rpc -Method 'shutdown' -TimeoutMs 15000
    Add-Check -Item '11' -Name 'shutdown returns ok:true' -Ok (Test-RpcOk $sh) `
        -Detail ((Get-RpcErrorCode $sh) + ' ' + (Get-RpcErrorMessage $sh)) -Exchange @($sh.Exchange)
    $script:ShutdownDone = $true
    $exited = $false
    try { $exited = $script:Proc.WaitForExit(8000) } catch { $exited = $script:Proc.HasExited }
    if ($exited) {
        $script:HelperExited = $true
        $script:HelperExitCode = $script:Proc.ExitCode
    }
    Add-Check -Item '11' -Name 'helper process exits after shutdown' -Ok $exited -Detail 'process still running 8s after shutdown'
    Add-Check -Item '11' -Name ('helper exit code is 0 (got ' + $script:HelperExitCode + ')') -Ok ($exited -and $script:HelperExitCode -eq 0) `
        -Detail ('exit code=' + $script:HelperExitCode)
    if ($exited) {
        try {
            $task = $script:Proc.StandardOutput.ReadLineAsync()
            if ($task.Wait(1500)) {
                $extra = $task.Result
                Add-Check -Item '11' -Name 'no extra stdout lines after the shutdown response' -Ok ($null -eq $extra) -Detail ('extra line: ' + $extra)
            }
        } catch { }
    }
}

# ---------------------------------------------------------------------------------------------
# Suite driver / summary
# ---------------------------------------------------------------------------------------------
function Invoke-TestSuite {
    Write-Line ''
    Write-Line '=== DSH computer use helper - protocol tests ==='
    Write-Line ('helper  : ' + $script:AgentPath)
    Write-Line ('started : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Line ('run dir : ' + $script:RunDir)
    Write-Line ''
    Assert-EncodingSelfCheck
    Invoke-Checklist1-Ping
    Invoke-SetPolicy
    Invoke-Checklist2-LaunchNotepad
    Invoke-Checklist3-CaptureAndTree
    Invoke-Checklist4-TypeText
    Invoke-Checklist5-SelectReplace
    Invoke-Checklist6-SaveDialog
    Invoke-Checklist7-ForbiddenKey
    Invoke-Checklist8-StaleState
    Invoke-Checklist9-ActivateCoordinate
    Invoke-Checklist10-ScrollCursorSetValue
    Invoke-Checklist11-Shutdown
}

function Save-ReportFile {
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('DSH computer use helper - test report')
    [void]$lines.Add('helper  : ' + $script:AgentPath)
    [void]$lines.Add('finished: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    [void]$lines.Add('')
    [void]$lines.Add('--- checks ---')
    foreach ($c in $script:Checks) {
        $st = 'PASS'
        if (-not $c.Ok) { $st = 'FAIL' }
        [void]$lines.Add(('{0} [{1}] {2} ({3} ms) {4}' -f $st, $c.Item, $c.Name, $c.Ms, $c.Detail))
    }
    [void]$lines.Add('')
    [void]$lines.Add('--- timings (ms) ---')
    foreach ($k in $script:Timings.Keys) { [void]$lines.Add(('{0} = {1}' -f $k, $script:Timings[$k])) }
    [void]$lines.Add(('helper_requests = ' + $script:RequestCount))
    [void]$lines.Add('')
    [void]$lines.Add('--- notes ---')
    foreach ($n in $script:ThreadNotes) { [void]$lines.Add($n) }
    if ($null -ne $script:FatalError) { [void]$lines.Add('FATAL: ' + $script:FatalError) }
    [void]$lines.Add('')
    [void]$lines.Add('--- last JSONL exchanges ---')
    foreach ($x in $script:LastExchanges) {
        [void]$lines.Add('> ' + $x.request)
        [void]$lines.Add('< ' + $x.response)
    }
    try {
        [System.IO.File]::WriteAllLines($script:ReportPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Write-Summary {
    Write-Line ''
    Write-Line '=== SUMMARY ==='
    $currentIdx = -1
    for ($i = 0; $i -lt $script:ChecklistItems.Count; $i++) {
        if ($script:ChecklistItems[$i].Id -eq $script:CurrentItem) { $currentIdx = $i; break }
    }
    foreach ($item in $script:ChecklistItems) {
        $idx = -1
        for ($i = 0; $i -lt $script:ChecklistItems.Count; $i++) { if ($script:ChecklistItems[$i].Id -eq $item.Id) { $idx = $i; break } }
        $itemChecks = @()
        if ($script:ChecksByItem.ContainsKey($item.Id)) { $itemChecks = @($script:ChecksByItem[$item.Id]) }
        if ($itemChecks.Count -eq 0) {
            if ($idx -gt $currentIdx) {
                Write-Line ('SKIP item {0} - {1}' -f $item.Id, $item.Name)
                [void]$script:SkippedItems.Add($item.Id)
            } else {
                Write-Line ('SKIP item {0} - {1} (no checks ran)' -f $item.Id, $item.Name)
                [void]$script:SkippedItems.Add($item.Id)
            }
            continue
        }
        $failed = @($itemChecks | Where-Object { -not $_.Ok })
        if ($failed.Count -eq 0) {
            Write-Line ('PASS item {0} - {1} ({2} checks)' -f $item.Id, $item.Name, $itemChecks.Count)
        } else {
            Write-Line ('FAIL item {0} - {1} ({2}/{3} checks passed)' -f $item.Id, $item.Name, ($itemChecks.Count - $failed.Count), $itemChecks.Count)
            foreach ($f in $failed) { Write-Line ('       failed: ' + $f.Name + ' :: ' + $f.Detail) }
        }
    }
    # non-checklist checks (item 0 / X)
    $extra = @($script:Checks | Where-Object { $script:ChecklistItems.Id -notcontains $_.Item })
    if ($extra.Count -gt 0) {
        $failedExtra = @($extra | Where-Object { -not $_.Ok })
        Write-Line ('{0} extras ({1}/{2} passed)' -f $(if ($failedExtra.Count -eq 0) { 'PASS' } else { 'FAIL' }), ($extra.Count - $failedExtra.Count), $extra.Count)
        foreach ($f in $failedExtra) { Write-Line ('       failed: [' + $f.Item + '] ' + $f.Name + ' :: ' + $f.Detail) }
    }
    Write-Line ''
    Write-Line 'Timings (ms):'
    foreach ($k in $script:Timings.Keys) { Write-Line ('  {0,-38} {1}' -f $k, $script:Timings[$k]) }
    Write-Line ('helper requests sent: ' + $script:RequestCount)
    if ($script:PreexistingNotepadPids.Count -gt 0) { Write-Line ('pre-existing notepad pids (not killed): ' + ($script:PreexistingNotepadPids -join ',')) }
    if ($null -ne $script:FatalError) { Write-Line ('FATAL/ABORT: ' + $script:FatalError) }
    Write-Line ('transcript : ' + $script:TranscriptPath)
    if (Test-Path -LiteralPath $script:StderrPath) { Write-Line ('helper err : ' + $script:StderrPath) }
    $total = $script:Checks.Count
    $passed = $total - $script:FailCount
    Write-Line ''
    Write-Line ('RESULT: {0}/{1} checks passed, {2} failed, {3} skipped items' -f $passed, $total, $script:FailCount, $script:SkippedItems.Count)
    if ($script:FailCount -eq 0 -and $null -eq $script:FatalError -and $script:SkippedItems.Count -eq 0) {
        Write-Line 'ALL CHECKLIST ITEMS PASSED'
    }
    Save-ReportFile
    Write-Line ('report     : ' + $script:ReportPath)
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------
$script:LastKnownBuffer = ''
$script:LastStateRpc = $null
$script:LastDialogList = $null
$script:FatalError = $null
$exitCode = 1
try {
    if (-not (Test-Path -LiteralPath $script:AgentPath)) {
        $script:FatalError = 'helper script not found: ' + $script:AgentPath
        Write-Line ('FATAL: ' + $script:FatalError)
    } else {
        $script:PreexistingNotepadPids = @(Get-Process notepad -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
        Start-Helper
        Invoke-TestSuite
    }
} catch {
    if ($_.Exception -is [CuTestAbort]) {
        $script:FatalError = 'ABORT: ' + $_.Exception.Message
    } else {
        $script:FatalError = 'UNEXPECTED: ' + $_.Exception.Message
        Write-Line ('       stack: ' + $_.ScriptStackTrace)
    }
} finally {
    try { Stop-HelperProcess } catch { Write-Line ('       cleanup(helper) error: ' + $_.Exception.Message) }
    $keep = ($KeepHelperAliveOnFailure -and ((-not [string]::IsNullOrEmpty([string]$script:FatalError)) -or ($script:FailCount -gt 0)))
    if ($keep) {
        Write-Line 'cleanup: -KeepHelperAliveOnFailure set and the run failed; leaving helper/notepad running for debugging'
    } else {
        try { Stop-TestNotepad } catch { Write-Line ('       cleanup(notepad) error: ' + $_.Exception.Message) }
    }
}

Write-Summary
if ($script:DesktopUnavailable) {
    Write-Line 'EXIT 2: interactive desktop is locked or on a secure desktop; UI automation was not exercised.'
    exit 2
}
if ((-not [string]::IsNullOrEmpty([string]$script:FatalError)) -or ($script:FailCount -gt 0) -or ($script:SkippedItems.Count -gt 0)) { exit 1 }
exit 0


