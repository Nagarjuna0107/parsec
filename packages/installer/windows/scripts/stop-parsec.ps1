# Stop what holds parsec.exe open before Setup swaps it, or before the
# uninstaller deletes it. A verbatim port of Stop-ParsecProxy / Stop-ParsecTray
# in scripts/install.ps1 (the source of truth for this dance):
#
#   • the proxy gets an identity-checked, graceful /shutdown — never a kill,
#     never a foreign process on the port;
#   • the tray is matched on its COMMAND LINE (`tray run`), because a proxy,
#     an MCP server and the tray are all parsec.exe and only the tray is ours
#     to stop here.
#
# Writes "tray-was-running" to -Out when it stopped a tray, so Setup can bring
# it back on the new binary. Never fails: an upgrade must not abort because
# something could not be stopped — Setup probes the file lock itself.
param(
    [Parameter(Mandatory)][string]$ParsecHome,
    [string]$Out = ""
)
$ErrorActionPreference = "Continue"
$PSNativeCommandUseErrorActionPreference = $false

function Stop-ParsecProxy {
    $port = 8082
    $statePath = Join-Path $ParsecHome "setup_state.json"
    if (Test-Path $statePath) {
        try {
            $st = Get-Content -Raw $statePath | ConvertFrom-Json
            if ($st.port -gt 0) { $port = $st.port }
        }
        catch {}
    }
    try {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2
        if ("$($h.service)" -ne "parsec-proxy") { return }
    }
    catch { return } # nothing listening, or not ours -- nothing to stop
    try {
        Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/shutdown" -TimeoutSec 2 | Out-Null
        Write-Host "stopped the running parsec proxy on port $port"
    }
    catch {
        Write-Host "shutdown request to port $port errored - checking whether it exits anyway"
    }
    for ($i = 0; $i -lt 40; $i++) {
        try { Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 1 | Out-Null }
        catch { return } # connection refused = really gone
        Start-Sleep -Milliseconds 100
    }
    Write-Warning "the proxy on port $port acknowledged shutdown but is still listening"
}

function Stop-ParsecTray {
    $stopped = $false
    try { $procs = Get-CimInstance Win32_Process -Filter "Name = 'parsec.exe'" -ErrorAction Stop }
    catch { return $false }
    foreach ($p in $procs) {
        if (-not ($p.CommandLine -and $p.CommandLine -match '\btray\s+run\b')) { continue }
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        $stopped = $true
    }
    if ($stopped) {
        Write-Host "stopped the running parsec tray (it holds parsec.exe open)"
        Start-Sleep -Milliseconds 300
    }
    return $stopped
}

Stop-ParsecProxy
$tray = Stop-ParsecTray
if ($Out) {
    if ($tray) { Set-Content -Path $Out -Value "tray-was-running" }
    else { Set-Content -Path $Out -Value "" }
}
exit 0
