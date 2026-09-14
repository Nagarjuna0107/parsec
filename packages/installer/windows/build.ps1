# Build the Windows installer: parsec-<version>-windows-x64-setup.exe
#
#   packages\installer\windows\build.ps1 -Version 0.2.8 -BinDir target\release
#       [-OutDir DIR]
#       [-SigningEndpoint URI -SigningAccount NAME -SigningProfile NAME -DlibPath PATH]
#
# Needs Inno Setup 6.5+ (ISCC.exe on PATH or in its default install dir;
# windows-latest runners ship 6.7). Signing is opt-in and uses Azure Artifact
# Signing (formerly Trusted Signing): the private key never leaves Microsoft,
# signtool talks to the service through Azure.CodeSigning.Dlib.dll from the
# Microsoft.ArtifactSigning.Client NuGet package (was Microsoft.Trusted.Signing.Client before the rename). All four signing parameters
# are required together. Credentials come from DefaultAzureCredential — in CI
# that is the `az login` session azure/login sets up via GitHub OIDC; locally
# an `az login` as a user with the Certificate Profile Signer role works too.
# parsec.exe is Authenticode-signed first, then Inno's SignTool directive
# signs Setup and the embedded uninstaller with the same command.
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$BinDir,
    [string]$OutDir = (Join-Path $PSScriptRoot "..\..\..\target\installer"),
    [string]$SigningEndpoint = "",
    [string]$SigningAccount = "",
    [string]$SigningProfile = "",
    [string]$DlibPath = ""
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$BinDir = (Resolve-Path $BinDir).Path
foreach ($f in "parsec.exe", "msvcp140.dll", "msvcp140_1.dll", "vcruntime140.dll", "vcruntime140_1.dll") {
    if (-not (Test-Path (Join-Path $BinDir $f))) { throw "missing $f in $BinDir" }
}
# The binary's own version is the source of truth (release.yml enforces the
# same on the tag side): an installer that lies about its contents would
# blind every later upgrade comparison.
$reported = & (Join-Path $BinDir "parsec.exe") --version
if ($LASTEXITCODE) { throw "parsec.exe --version failed ($LASTEXITCODE)" }
if (-not ($reported -match "\b$([regex]::Escape($Version))\b")) {
    throw "parsec.exe reports '$reported' but -Version is $Version"
}

$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $iscc) {
    $iscc = Get-ChildItem "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue
}
if (-not $iscc) { throw "ISCC.exe not found (install Inno Setup 6)" }
$iscc = if ($iscc.Path) { $iscc.Path } else { $iscc.FullName }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

$args = @("/DVersion=$Version", "/DBinDir=$BinDir", "/O$OutDir", "/Q")
$signing = $SigningEndpoint -and $SigningAccount -and $SigningProfile -and $DlibPath
if ($SigningEndpoint -or $SigningAccount -or $SigningProfile -or $DlibPath) {
    if (-not $signing) { throw "signing needs all of -SigningEndpoint, -SigningAccount, -SigningProfile, -DlibPath" }
}
$signtool = $null
if ($signing) {
    $DlibPath = (Resolve-Path $DlibPath).Path
    # The dlib needs signtool 10.0.22621 or newer; pick the newest SDK present.
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Directory.Parent.Name) } | Select-Object -Last 1
    if (-not $signtool) { throw "signtool.exe not found (Windows 10/11 SDK)" }
    # metadata.json tells the dlib which account/profile to sign with. The
    # excluded credential types are the ones that only exist inside Azure or
    # need a desktop; without the list DefaultAzureCredential probes each one
    # (ManagedIdentity alone is a multi-second timeout per file).
    $metadata = Join-Path ([IO.Path]::GetTempPath()) "parsec-signing-$PID.json"
    @{
        Endpoint                  = $SigningEndpoint
        CodeSigningAccountName    = $SigningAccount
        CertificateProfileName    = $SigningProfile
        ExcludeCredentials        = @(
            "ManagedIdentityCredential", "SharedTokenCacheCredential",
            "VisualStudioCredential", "VisualStudioCodeCredential",
            "AzurePowerShellCredential", "AzureDeveloperCliCredential",
            "InteractiveBrowserCredential"
        )
    } | ConvertTo-Json | Set-Content -Path $metadata -Encoding ascii
    # Inno's SignTool command: $q stands for a double quote and $f for the
    # file. Literal quotes inside the /S parameter must NOT be used — ISCC's
    # argument parser splits on them ("You may not specify more than one
    # script filename"), and pwsh would escape them as \" on top of that.
    $common = "sign /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib `$q$DlibPath`$q /dmdf `$q$metadata`$q"
    & $signtool.FullName sign /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib $DlibPath /dmdf $metadata (Join-Path $BinDir "parsec.exe")
    if ($LASTEXITCODE) { throw "signtool failed on parsec.exe ($LASTEXITCODE)" }
    # `$q` and `$f` must reach ISCC literally: Inno substitutes them.
    $args += "/DSign=1"
    $args += "/Sparsecsign=`$q$($signtool.FullName)`$q $common `$f"
    Write-Host "signing enabled: $SigningAccount/$SigningProfile via $SigningEndpoint"
} else {
    Write-Host "note: unsigned (no signing parameters) - SmartScreen will warn"
}

try {
    & $iscc @args (Join-Path $PSScriptRoot "parsec.iss")
    if ($LASTEXITCODE) { throw "ISCC failed ($LASTEXITCODE)" }
} finally {
    if ($signing) { Remove-Item $metadata -Force -ErrorAction SilentlyContinue }
}
$out = Join-Path $OutDir "parsec-$Version-windows-x64-setup.exe"
if (-not (Test-Path $out)) { throw "expected output missing: $out" }
if ($signing) {
    # Inno's SignTool directive failing is only a warning in some
    # configurations; an unsigned Setup after a "signed" build must not ship.
    foreach ($f in (Join-Path $BinDir "parsec.exe"), $out) {
        & $signtool.FullName verify /pa /q $f
        if ($LASTEXITCODE) { throw "signature verification failed for $f ($LASTEXITCODE)" }
    }
    Write-Host "verified Authenticode signatures on parsec.exe and Setup"
}
Write-Host "built $out"
Get-FileHash -Algorithm SHA256 $out | Format-List Hash, Path
