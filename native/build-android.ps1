param(
    [ValidateSet('debug', 'release')]
    [string]$Profile = 'release'
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$nativeCorePath = Join-Path $PSScriptRoot 'core'
$jniLibrariesPath = Join-Path $projectRoot 'android\app\src\main\jniLibs'
$buildArguments = @(
    'ndk',
    '-t', 'armeabi-v7a',
    '-t', 'arm64-v8a',
    '-t', 'x86_64',
    '-o', $jniLibrariesPath,
    'build',
    '--features', 'veilid,signal-ratchet'
)

if ($Profile -eq 'release') {
    $buildArguments += '--release'
}

Push-Location $nativeCorePath
try {
    & cargo @buildArguments
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}
