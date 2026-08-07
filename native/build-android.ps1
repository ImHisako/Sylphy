param(
    [ValidateSet('debug', 'release')]
    [string]$Profile = 'release'
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$nativeCorePath = Join-Path $PSScriptRoot 'core'
$jniLibrariesPath = Join-Path $projectRoot 'android\app\src\main\jniLibs'

if (-not $env:ANDROID_HOME -and -not $env:ANDROID_SDK_ROOT) {
    $defaultAndroidSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path -LiteralPath $defaultAndroidSdk) {
        $env:ANDROID_HOME = $defaultAndroidSdk
        $env:ANDROID_SDK_ROOT = $defaultAndroidSdk
    }
}
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
    # Android builds still execute host-side Rust build scripts. On Windows,
    # use the installed GNU host toolchain when MSVC Build Tools/link.exe are
    # absent; the produced Android libraries are identical NDK targets.
    $gnuToolchain = 'stable-x86_64-pc-windows-gnu'
    $useGnuHost = $IsWindows -and
        -not (Get-Command link.exe -ErrorAction SilentlyContinue) -and
        ((& rustup toolchain list) -match [regex]::Escape($gnuToolchain))
    if ($useGnuHost) {
        & cargo "+$gnuToolchain" @buildArguments
    }
    else {
        & cargo @buildArguments
    }
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}
