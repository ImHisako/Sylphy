param(
    [ValidateSet('debug', 'release')]
    [string]$Profile = 'release'
)

$manifestPath = Join-Path $PSScriptRoot 'core\Cargo.toml'
$buildArguments = @('build', '--locked', '--manifest-path', $manifestPath, '--features', 'veilid,signal-ratchet')

if ($Profile -eq 'release') {
    $buildArguments += '--release'
}

& cargo @buildArguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$targetDirectory = if ($Profile -eq 'release') { 'release' } else { 'debug' }
$artifact = Join-Path $PSScriptRoot "core\target\$targetDirectory\sylphy_core.dll"
if (-not (Test-Path -LiteralPath $artifact)) {
    Write-Error "Artifact nativo non trovato: $artifact"
    exit 1
}
Write-Output "Core nativo Sylphy Windows pronto: $artifact"
