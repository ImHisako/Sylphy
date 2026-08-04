param(
    [ValidateSet('debug', 'release')]
    [string]$Profile = 'release'
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $PSScriptRoot 'core\Cargo.toml'
$jniLibrariesPath = Join-Path $projectRoot 'android\app\src\main\jniLibs'
$buildArguments = @(
    'ndk',
    '-t', 'armeabi-v7a',
    '-t', 'arm64-v8a',
    '-t', 'x86_64',
    '-o', $jniLibrariesPath,
    'build',
    '--manifest-path', $manifestPath,
    '--features', 'veilid'
)

if ($Profile -eq 'release') {
    $buildArguments += '--release'
}

& cargo @buildArguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
