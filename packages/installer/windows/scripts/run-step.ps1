# Run one post-install step for Setup, with the three things Inno's Exec
# cannot give a hidden child:
#
#   • an EOF on stdin (<NUL) — a child that prompts (a CLI's first-run
#     question, a "continue? [y/N]") gets "no input" at once instead of waiting forever
#     on a console nobody can see. That wait is what a wizard stuck on its
#     last page looks like: Setup pumps messages while it waits, so the
#     window stays alive, but the step never returns;
#   • a deadline — WaitForExit on the child's OWN handle (never -Wait, which
#     also waits for every descendant, and `parsec up --restart` leaves a
#     detached supervisor behind by design), then the whole tree is killed
#     and 124 comes back, so the Finished page can name the step;
#   • a log — stdout/stderr go to -Log (files, not pipes: a grandchild that
#     inherits a pipe would hold it open past the step, and a tray that
#     println!s into a closed pipe dies). The log is the diagnosis when a
#     user reports "it hung".
#
# Exit code: the child's, or 124 on timeout, or 125 if it could not start.
param(
    [Parameter(Mandatory)][string]$Exe,
    [string]$Arguments = "",
    [int]$TimeoutSec = 120,
    [string]$Log = ""
)
# Stop, not Continue: Setup hides this script's own stderr, so an error that
# is merely printed is an error nobody sees. Every failure must reach $Log.
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

if (-not $Log) { $Log = Join-Path $env:TEMP "parsec-step.log" }
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path $Log -Value "[$stamp] step: $Exe $Arguments (timeout ${TimeoutSec}s)"

# Output to files, never pipes (see above), and via cmd.exe's own redirection
# rather than Start-Process -RedirectStandard*: with redirection Windows
# PowerShell's Start-Process runs CreateProcess itself and hands back a
# Process object looked up BY ID, so once the child exits there is no
# handle left to read ExitCode from (null — v0.2.12's second CI run, with
# the redirected output empty as well). [Diagnostics.Process]::Start keeps
# the handle; cmd /S /C does `<NUL` (EOF on stdin) and the two file
# redirects, then exits with the child's code. The scratch files sit next
# to $Log, a directory this script has just proven it can write.
$scratch = Split-Path -Parent $Log
$tag = "step-$PID-" + [IO.Path]::GetRandomFileName()
$stdout = Join-Path $scratch "$tag.out"
$stderr = Join-Path $scratch "$tag.err"
try {
    # /S: strip the outer quotes, keep every inner one verbatim.
    $inner = '"' + $Exe + '"'
    if ($Arguments) { $inner += ' ' + $Arguments }
    $inner += ' <NUL >"' + $stdout + '" 2>"' + $stderr + '"'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot "System32\cmd.exe"
    $psi.Arguments = '/S /C "' + $inner + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Get-Location).Path
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p) {
        Add-Content -Path $Log -Value "  could not start (no process object)"
        exit 125
    }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        Add-Content -Path $Log -Value "  TIMEOUT after ${TimeoutSec}s - killing pid $($p.Id) and its children"
        # No 2>&1: under ErrorActionPreference=Stop, Windows PowerShell turns a
        # native command's redirected stderr into a terminating error.
        try { & taskkill.exe /T /F /PID $p.Id | Out-Null } catch {}
        $code = 124
    }
    else {
        $p.WaitForExit()
        $code = $p.ExitCode
        if ($null -eq $code) {
            Add-Content -Path $Log -Value "  exit code unavailable - treating as failure"
            $code = 1
        }
    }
    foreach ($f in $stdout, $stderr) {
        $text = Get-Content -Raw -ErrorAction SilentlyContinue $f
        if ($text) { Add-Content -Path $Log -Value ($text.TrimEnd() -replace '(?m)^', '  ') }
    }
    Add-Content -Path $Log -Value "  exit $code"
    exit $code
}
catch {
    # Anything above that was not caught on purpose: name it and fail the
    # step rather than exit 0 by falling off the end.
    Add-Content -Path $Log -Value "  runner error: $_"
    Add-Content -Path $Log -Value ("  " + ($_.ScriptStackTrace -replace '(?m)^', '  ').TrimStart())
    exit 125
}
finally {
    foreach ($f in $stdout, $stderr) {
        if (Test-Path $f) { Remove-Item -Force -ErrorAction SilentlyContinue $f }
    }
}
