# Fetch the parsec.exe (plus the app-local VC++ CRT DLLs) matching this
# plugin's version from the GitHub Release on daseinlabs/parsec into -Dest,
# sha256-verified against the release's manifest.json. parsec.cmd calls this
# when the binary is missing, and at SessionStart so an installed binary
# OLDER than the plugin is upgraded (a marketplace plugin update brings its
# binary along). Same version or newer: nothing happens. Failure leaves any
# existing binary in place; parsec.cmd runs it regardless.
#
# PARSEC_RELEASE_BASE overrides the release URL base (mirrors the GitHub
# layout: download/<tag>/<asset> and latest/download/<asset>); same variable
# as install.ps1.
param([string]$PluginRoot, [string]$Dest)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Core([string]$v) { [version](($v -split '-')[0]) }   # "0.3.0-rc.1" -> 0.3.0

$want = $null
try { $want = (Get-Content (Join-Path $PluginRoot '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version } catch {}
if (Test-Path $Dest) {
    $have = $null
    try { $have = ((& $Dest --version) -split ' ')[-1] } catch {}
    if ($have) {
        if (-not $want) { exit 0 }
        try { if ((Core $have) -ge (Core $want)) { exit 0 } } catch { exit 0 }
    }
    # Older than the plugin, or does not run: fetch the plugin's version.
}

$base = if ($env:PARSEC_RELEASE_BASE) { $env:PARSEC_RELEASE_BASE } else { 'https://github.com/daseinlabs/parsec/releases' }
$url = if ($want) { "$base/download/v$want" } else { "$base/latest/download" }
$dir = Split-Path $Dest
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$manifest = $null
try { $manifest = Invoke-RestMethod -Uri "$url/manifest.json" -UseBasicParsing } catch {}

function Fetch([string]$Name, [string]$Out) {
    $tmp = "$Out.parsec-tmp"
    Invoke-WebRequest -Uri "$url/$Name" -OutFile $tmp -UseBasicParsing
    $expected = if ($manifest -and $manifest.assets) { $manifest.assets.$Name } else { $null }
    if ($expected) {
        $actual = (Get-FileHash -Algorithm SHA256 $tmp).Hash.ToLowerInvariant()
        if ($actual -ne $expected.ToLowerInvariant()) {
            Remove-Item -Force $tmp
            throw "sha256 mismatch for ${Name}: expected $expected, got $actual"
        }
    }
    # rename() replaces an existing file on Windows; one locked by a RUNNING
    # proxy fails here and the caller keeps what it has.
    Move-Item -Force $tmp $Out
}

[Console]::Error.WriteLine("parsec: fetching $(if ($want) { $want } else { 'latest' }) (win-x64) from $url")
# The loader only searches next to the exe, so the CRT lands in the same dir.
$dlls = if ($manifest -and $manifest.assets) {
    $manifest.assets.PSObject.Properties.Name | Where-Object { $_ -like '*.dll' }
} else {
    @('msvcp140.dll', 'msvcp140_1.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
}
foreach ($d in $dlls) { Fetch $d (Join-Path $dir $d) }
Fetch 'parsec-win-x64.exe' $Dest
& $Dest --version | Out-Null
