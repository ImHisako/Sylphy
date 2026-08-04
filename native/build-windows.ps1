param(
    [ValidateSet('debug', 'release')]
    [string]$Profile = 'release'
)

$manifestPath = Join-Path $PSScriptRoot 'core\Cargo.toml'
$buildArguments = @('build', '--manifest-path', $manifestPath, '--features', 'veilid')

if ($Profile -eq 'release') {
    $buildArguments += '--release'
}

& cargo @buildArguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
