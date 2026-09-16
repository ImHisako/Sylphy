param(
    [ValidateSet('debug', 'release')]
    [string]$Profile = 'release',
    [switch]$CleanupOnly
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$nativeCorePath = Join-Path $PSScriptRoot 'core'
$jniLibrariesPath = Join-Path $projectRoot 'android\app\src\main\jniLibs'

function Remove-UnneededNativeLibraries {
    foreach ($abi in @('armeabi-v7a', 'arm64-v8a', 'x86_64')) {
        $abiPath = Join-Path $jniLibrariesPath $abi
        if (Test-Path -LiteralPath $abiPath) {
            Get-ChildItem -LiteralPath $abiPath -Filter '*.so' |
                Where-Object Name -ne 'libsylphy_core.so' |
                Remove-Item -Force
        }
    }
}

if ($CleanupOnly) {
    Remove-UnneededNativeLibraries
    exit 0
}

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
    '--locked',
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
    $runningOnWindows = ($env:OS -eq 'Windows_NT') -or
        (Get-Variable IsWindows -ErrorAction SilentlyContinue -ValueOnly)
    $useGnuHost = $runningOnWindows -and
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
    $metadata = @(
        'abi=13'
        'libsignal=signalapp/libsignal@v0.102.1'
        "profile=$Profile"
    )
    [string[]]$sourceFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $nativeCorePath 'src') -Recurse -File -Filter '*.rs'
        Get-Item -LiteralPath (Join-Path $nativeCorePath 'Cargo.toml')
        Get-Item -LiteralPath (Join-Path $nativeCorePath 'Cargo.lock')
    ) | ForEach-Object {
        $_.FullName.Substring($nativeCorePath.Length + 1).Replace('\', '/')
    }
    # Match Kotlin's ordinal ordering, including punctuation (groups.rs must
    # precede groups_tests.rs). Sort-Object uses culture-dependent collation.
    [Array]::Sort($sourceFiles, [StringComparer]::Ordinal)
    $sourceHashes = ($sourceFiles | ForEach-Object {
        (Get-FileHash -LiteralPath (Join-Path $nativeCorePath $_) -Algorithm SHA256).Hash.ToLowerInvariant()
    }) -join ''
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $sourceDigest = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($sourceHashes))
        $metadata += 'source.sha256=' + (($sourceDigest | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha256.Dispose()
    }
    Remove-UnneededNativeLibraries
    foreach ($abi in @('armeabi-v7a', 'arm64-v8a', 'x86_64')) {
        $library = Join-Path (Join-Path $jniLibrariesPath $abi) 'libsylphy_core.so'
        if (-not (Test-Path -LiteralPath $library)) {
            throw "Missing native library after build: $library"
        }
        $hash = (Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant()
        $metadata += "$abi.sha256=$hash"
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $jniLibrariesPath 'sylphy-core.properties'),
        (($metadata -join "`n") + "`n"),
        [System.Text.Encoding]::ASCII
    )
}
finally {
    Pop-Location
}
