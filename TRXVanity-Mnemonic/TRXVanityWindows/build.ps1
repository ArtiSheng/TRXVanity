[CmdletBinding()]
param(
    [string]$VisualStudioPath = '',
    [switch]$Clean,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$windowsRoot = $PSScriptRoot
$repositoryRoot = Split-Path -Parent $windowsRoot
$engineRoot = Join-Path $windowsRoot 'Engine'
$appRoot = Join-Path $windowsRoot 'App'
$cudaMnemonicRoot = Join-Path $repositoryRoot 'Vendor\CUDA_Mnemonic_Recovery'
$opensslRoot = Join-Path $repositoryRoot 'Vendor\OpenSSL'
$opensslDllSource = Join-Path $opensslRoot 'libcrypto-3-x64.dll'
$expectedOpenSslSha256 = '0330B5F558996F297D687E1A2B2FCC2CACF883B16BAEF74AAEF35285D7C1231C'
if (-not (Test-Path -LiteralPath $opensslDllSource -PathType Leaf)) {
    throw 'The bundled OpenSSL CPU accelerator is missing.'
}
$actualOpenSslSha256 = (Get-FileHash -LiteralPath $opensslDllSource -Algorithm SHA256).Hash
if ($actualOpenSslSha256 -ne $expectedOpenSslSha256) {
    throw "The bundled OpenSSL CPU accelerator failed its SHA-256 integrity check: $actualOpenSslSha256"
}
$buildRoot = Join-Path $windowsRoot 'build'
$objectRoot = Join-Path $buildRoot 'obj'

if ($Clean) {
    if (Test-Path -LiteralPath $buildRoot) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force
    }
    $legacyDist = Join-Path $windowsRoot 'dist'
    if (Test-Path -LiteralPath $legacyDist) {
        Remove-Item -LiteralPath $legacyDist -Recurse -Force
    }
}

New-Item -ItemType Directory -Force $objectRoot | Out-Null

$vsPath = $VisualStudioPath
if ([string]::IsNullOrWhiteSpace($vsPath)) {
    $vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vsWhere -PathType Leaf) {
        $vsPath = & $vsWhere -latest -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
    }
}
if ([string]::IsNullOrWhiteSpace($vsPath)) {
    # Support a self-contained Build Tools tree next to the repository, such
    # as Q:\VSBuildTools\2022 beside Q:\TRXVanity. This keeps CI/developer
    # machines from depending on a registered system-wide VS installation.
    $portableCandidate = Join-Path (Split-Path -Parent $repositoryRoot) 'VSBuildTools\2022'
    if (Test-Path -LiteralPath (Join-Path $portableCandidate 'VC\Auxiliary\Build\vcvars64.bat')) {
        $vsPath = $portableCandidate
    }
}
if ([string]::IsNullOrWhiteSpace($vsPath)) {
    throw 'Visual Studio Build Tools with the MSVC x64 component was not found.'
}
$vsPath = (Resolve-Path -LiteralPath $vsPath).Path
$vcVars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcVars -PathType Leaf)) {
    throw "vcvars64.bat was not found below VisualStudioPath: $vsPath"
}

$environmentLines = & $env:ComSpec /s /c "`"$vcVars`" >nul && set"
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to load the MSVC x64 build environment.'
}
foreach ($line in $environmentLines) {
    $separator = $line.IndexOf('=')
    if ($separator -gt 0) {
        $name = $line.Substring(0, $separator)
        $value = $line.Substring($separator + 1)
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}
if ([string]::IsNullOrWhiteSpace($env:WindowsSdkDir) `
    -or -not (Test-Path -LiteralPath $env:WindowsSdkDir -PathType Container)) {
    throw 'The selected Build Tools installation is missing the Windows 10/11 SDK component.'
}

$cl = (Get-Command cl.exe -ErrorAction Stop).Source
$link = (Get-Command link.exe -ErrorAction Stop).Source
$lib = (Get-Command lib.exe -ErrorAction Stop).Source
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    throw '.NET Framework 4.8 x64 C# compiler is unavailable.'
}

$cudaRoot = ''
if (-not [string]::IsNullOrWhiteSpace($env:CUDA_PATH) `
    -and (Test-Path -LiteralPath (Join-Path $env:CUDA_PATH 'bin\nvcc.exe'))) {
    $cudaRoot = $env:CUDA_PATH
}
if ([string]::IsNullOrWhiteSpace($cudaRoot)) {
    $cudaBase = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA'
    if (Test-Path -LiteralPath $cudaBase -PathType Container) {
        $cudaRoot = Get-ChildItem -LiteralPath $cudaBase -Directory |
            Where-Object {
                $_.Name -match '^v\d+(?:\.\d+)*$' -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'bin\nvcc.exe') -PathType Leaf)
            } |
            Sort-Object @{ Expression = { [version]$_.Name.Substring(1) }; Descending = $true } |
            Select-Object -First 1 -ExpandProperty FullName
    }
}
if ([string]::IsNullOrWhiteSpace($cudaRoot)) {
    throw 'CUDA Toolkit with nvcc was not found.'
}
$cudaRoot = (Resolve-Path -LiteralPath $cudaRoot).Path
$nvcc = Join-Path $cudaRoot 'bin\nvcc.exe'
if (-not (Test-Path -LiteralPath $nvcc -PathType Leaf)) {
    throw "nvcc was not found below CUDA Toolkit: $cudaRoot"
}

$supportedCudaCodes = @(& $nvcc --list-gpu-code 2>$null)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query the CUDA architectures supported by nvcc.'
}
$nativeCudaArchitectures = @('75', '86', '89')
foreach ($architecture in $nativeCudaArchitectures) {
    if ($supportedCudaCodes -notcontains "sm_$architecture") {
        throw "The selected CUDA Toolkit cannot build the required sm_$architecture RTX kernel."
    }
}
if ($supportedCudaCodes -contains 'sm_120') {
    $nativeCudaArchitectures += '120'
}
$forwardPtxArchitecture = if ($nativeCudaArchitectures -contains '120') {
    '120'
} else {
    # CUDA 12.6 cannot emit Blackwell cubins. Embedding compute_89 PTX keeps
    # the package forward-compatible so an RTX 50-series driver can JIT it.
    '89'
}
$cudaCompileCodeFlags = @()
$cudaLinkCodeFlags = @()
foreach ($architecture in $nativeCudaArchitectures) {
    $cudaCompileCodeFlags += "--generate-code=arch=compute_$architecture,code=lto_$architecture"
    $cudaLinkCodeFlags += "--generate-code=arch=compute_$architecture,code=sm_$architecture"
}
$cudaCompileCodeFlags += "--generate-code=arch=compute_$forwardPtxArchitecture,code=compute_$forwardPtxArchitecture"
$cudaLinkCodeFlags += "--generate-code=arch=compute_$forwardPtxArchitecture,code=compute_$forwardPtxArchitecture"
Write-Host "CUDA targets: $($nativeCudaArchitectures | ForEach-Object { 'sm_' + $_ }) + compute_$forwardPtxArchitecture PTX"

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Program,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit code $LASTEXITCODE): $Program"
    }
}

$secpInclude = Join-Path $repositoryRoot 'Vendor\secp256k1\include'
$secpSource = Join-Path $repositoryRoot 'Vendor\secp256k1\src'
$optimizationFlags = @(
    '/O2',       # Maximize speed while retaining standards-compliant FP behavior.
    '/Ob3',      # Allow the most aggressive automatic inlining under LTCG.
    '/Oi', '/Ot',
    '/GL',       # Whole-program optimization; consumed by /LTCG at link time.
    '/Gw', '/Gy', '/GF'
)
$commonC = @(
    '/nologo', '/c', '/MT', '/DNDEBUG', '/TC'
) + $optimizationFlags + @(
    "/I$secpInclude", "/I$secpSource"
)

Invoke-Native $cl ($commonC + @(
    "/Fo$(Join-Path $objectRoot 'secp256k1.obj')",
    (Join-Path $secpSource 'secp256k1.c')
))
Invoke-Native $cl ($commonC + @(
    "/Fo$(Join-Path $objectRoot 'precomputed_ecmult.obj')",
    (Join-Path $secpSource 'precomputed_ecmult.c')
))
Invoke-Native $cl ($commonC + @(
    "/Fo$(Join-Path $objectRoot 'precomputed_ecmult_gen.obj')",
    (Join-Path $secpSource 'precomputed_ecmult_gen.c')
))

$cppSources = @(
    (Join-Path $engineRoot 'crypto.cpp'),
    (Join-Path $engineRoot 'match_plan.cpp'),
    (Join-Path $engineRoot 'mnemonic.cpp'),
    (Join-Path $engineRoot 'mnemonic_engine.cpp'),
    (Join-Path $engineRoot 'openssl_pbkdf2.cpp'),
    (Join-Path $engineRoot 'main.cpp')
)
$cppObjects = @()
foreach ($source in $cppSources) {
    $object = Join-Path $objectRoot (([IO.Path]::GetFileNameWithoutExtension($source)) + '.obj')
    Invoke-Native $cl (@(
        '/nologo', '/c', '/MT', '/DNDEBUG', '/EHsc',
        '/std:c++17', '/permissive-', '/Zc:__cplusplus', '/Zc:inline', '/utf-8', '/W3'
    ) + $optimizationFlags + @(
        "/I$engineRoot", "/I$secpInclude",
        "/Fo$object", $source
    ))
    $cppObjects += $object
}

$cudaCompileFlags = @(
    '--compile', '--std=c++17', '-O3', '--use_fast_math',
    '--relocatable-device-code=true',
    '--threads=0',
    '-Xcompiler=/MT', '-Xcompiler=/EHsc', '-Xcompiler=/utf-8',
    "-I$engineRoot", "-I$cudaMnemonicRoot"
) + $cudaCompileCodeFlags
$cudaObject = Join-Path $objectRoot 'mnemonic_cuda.obj'
Invoke-Native $nvcc ($cudaCompileFlags + @(
    '-o', $cudaObject,
    (Join-Path $engineRoot 'mnemonic_cuda.cu')
))
$cudaSecpObject = Join-Path $objectRoot 'mnemonic_cuda_secp256k1.obj'
Invoke-Native $nvcc ($cudaCompileFlags + @(
    '-o', $cudaSecpObject,
    (Join-Path $cudaMnemonicRoot 'third_party\secp256k1\secp256k1.cu')
))
$cudaDeviceLinkObject = Join-Path $objectRoot 'mnemonic_cuda_device_link.obj'
Invoke-Native $nvcc (@(
    '--device-link', '--dlink-time-opt', '--relocatable-ptx',
    '-Xcompiler=/MT',
    '-o', $cudaDeviceLinkObject,
    $cudaObject, $cudaSecpObject
) + $cudaLinkCodeFlags)

$engineExe = Join-Path $buildRoot 'trxvanity-gpu.exe'
$nativeObjects = @(
    (Join-Path $objectRoot 'secp256k1.obj'),
    (Join-Path $objectRoot 'precomputed_ecmult.obj'),
    (Join-Path $objectRoot 'precomputed_ecmult_gen.obj'),
    $cudaObject,
    $cudaSecpObject,
    $cudaDeviceLinkObject
) + $cppObjects
Invoke-Native $link (@(
    '/nologo', '/LTCG', '/INCREMENTAL:NO', '/SUBSYSTEM:CONSOLE', '/MACHINE:X64',
    '/OPT:REF', '/OPT:ICF=8', '/DYNAMICBASE', '/NXCOMPAT', '/HIGHENTROPYVA',
    "/OUT:$engineExe"
) + $nativeObjects + @(
    (Join-Path $cudaRoot 'lib\x64\cudart_static.lib'),
    (Join-Path $cudaRoot 'lib\x64\cudadevrt.lib'),
    'bcrypt.lib', 'advapi32.lib', 'user32.lib', 'shell32.lib'
))

$appExe = Join-Path $buildRoot 'TRXVanity.exe'
Invoke-Native $csc @(
    '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
    '/langversion:5', '/codepage:65001',
    "/win32manifest:$(Join-Path $appRoot 'app.manifest')",
    "/appconfig:$(Join-Path $appRoot 'App.config')",
    "/out:$appExe",
    '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll', '/reference:System.Security.dll',
    (Join-Path $appRoot 'Program.cs'),
    (Join-Path $appRoot 'AppHeartbeat.cs'),
    (Join-Path $appRoot 'BackupCrypto.cs'),
    (Join-Path $appRoot 'BackupUploader.cs'),
    (Join-Path $appRoot 'BackupSettingsForm.cs'),
    (Join-Path $appRoot 'HistoryStore.cs'),
    (Join-Path $appRoot 'MainForm.cs')
)
Copy-Item -LiteralPath (Join-Path $appRoot 'App.config') -Destination ($appExe + '.config') -Force

$decryptExe = Join-Path $buildRoot 'TRXVanityBackupDecrypt.exe'
Invoke-Native $csc @(
    '/nologo', '/target:exe', '/platform:x64', '/optimize+',
    '/langversion:5', '/codepage:65001',
    '/main:TRXVanity.WindowsApp.BackupDecryptProgram',
    "/out:$decryptExe",
    '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Security.dll',
    (Join-Path $appRoot 'BackupCrypto.cs'),
    (Join-Path $appRoot 'BackupDecrypt.cs')
)

Copy-Item -LiteralPath (Join-Path $cudaMnemonicRoot 'assets\wordlists\bip39-en.txt') `
    -Destination (Join-Path $buildRoot 'bip39-english.txt') -Force
Copy-Item -LiteralPath $opensslDllSource `
    -Destination (Join-Path $buildRoot 'libcrypto-3-x64.dll') -Force

$licenseOutput = Join-Path $buildRoot 'ThirdPartyLicenses'
New-Item -ItemType Directory -Force $licenseOutput | Out-Null
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'ThirdPartyLicenses\libsecp256k1-MIT.txt') -Destination $licenseOutput -Force
Copy-Item -LiteralPath (Join-Path $cudaMnemonicRoot 'LICENSE.txt') `
    -Destination (Join-Path $licenseOutput 'CUDA-Mnemonic-Recovery-Apache-2.0.txt') -Force
Copy-Item -LiteralPath (Join-Path $opensslRoot 'LICENSE.txt') `
    -Destination (Join-Path $licenseOutput 'OpenSSL-Apache-2.0.txt') -Force

if (-not $SkipTests) {
    & $decryptExe --self-test
    if ($LASTEXITCODE -ne 0) {
        throw "AES backup self-test failed (exit code $LASTEXITCODE)."
    }

    # One known candidate still exercises the complete CUDA PBKDF2 and
    # derivation path while keeping build-time validation short.
    & $engineExe --self-test --batch-size 128
    if ($LASTEXITCODE -ne 0) {
        throw "GPU self-test failed (exit code $LASTEXITCODE)."
    }
}

Write-Host "Build completed: $appExe"
