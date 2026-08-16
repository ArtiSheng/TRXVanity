[CmdletBinding()]
param(
    [ValidateSet('Release')]
    [string]$Configuration = 'Release',
    [ValidateSet('Compatible', 'AVX2')]
    [string]$CpuTarget = 'Compatible',
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$')]
    [string]$OutputName = 'dist',
    [switch]$Clean,
    [switch]$SkipTests,
    [switch]$FullGpuSelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$windowsRoot = $PSScriptRoot
$repositoryRoot = Split-Path -Parent $windowsRoot
$engineRoot = Join-Path $windowsRoot 'Engine'
$appRoot = Join-Path $windowsRoot 'App'
$buildRoot = Join-Path $windowsRoot 'build'
$protectedOutputNames = @(
    'App', 'Engine', 'build', 'tools',
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)
if ($protectedOutputNames -contains $OutputName) {
    throw "OutputName '$OutputName' is reserved by the source tree."
}
$variantName = ('{0}-{1}' -f $OutputName, $CpuTarget).ToLowerInvariant()
$objectRoot = Join-Path $buildRoot ("obj-$variantName")
$distRoot = Join-Path $windowsRoot $OutputName

if ($Clean) {
    # Build variants are intentionally isolated. Cleaning one benchmark build
    # must not remove another process's objects or measurements.
    if (Test-Path -LiteralPath $objectRoot) {
        Remove-Item -LiteralPath $objectRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $distRoot) {
        Remove-Item -LiteralPath $distRoot -Recurse -Force
    }
}

New-Item -ItemType Directory -Force $objectRoot, $distRoot | Out-Null

$vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vsWhere)) {
    throw 'Visual Studio Build Tools is not installed: vswhere.exe was not found.'
}
$vsPath = & $vsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    throw 'Visual Studio Build Tools is missing the MSVC x64 C++ component.'
}
$vcVars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcVars)) {
    throw "vcvars64.bat was not found: $vcVars"
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

$cl = (Get-Command cl.exe -ErrorAction Stop).Source
$link = (Get-Command link.exe -ErrorAction Stop).Source
$lib = (Get-Command lib.exe -ErrorAction Stop).Source
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    throw '.NET Framework 4.8 x64 C# compiler is unavailable.'
}

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

$openClImportLibrary = Join-Path $objectRoot 'OpenCL.lib'
Invoke-Native $lib @(
    '/nologo', '/machine:x64',
    "/def:$(Join-Path $engineRoot 'OpenCL.def')",
    "/out:$openClImportLibrary"
)

$secpInclude = Join-Path $repositoryRoot 'Vendor\secp256k1\include'
$secpSource = Join-Path $repositoryRoot 'Vendor\secp256k1\src'
$optimizationFlags = @(
    '/O2',       # Maximize speed while retaining standards-compliant FP behavior.
    '/Ob3',      # Allow the most aggressive automatic inlining under LTCG.
    '/Oi', '/Ot',
    '/GL',       # Whole-program optimization; consumed by /LTCG at link time.
    '/Gw', '/Gy', '/GF'
)
$cpuFlags = @()
if ($CpuTarget -eq 'AVX2') {
    # This opt-in build is for modern x64 CPUs. The default remains compatible
    # with every x64 processor supported by Windows 11.
    $cpuFlags = @('/arch:AVX2', '/favor:INTEL64')
}
$commonC = @(
    '/nologo', '/c', '/MT', '/DNDEBUG', '/TC'
) + $optimizationFlags + $cpuFlags + @(
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
    (Join-Path $engineRoot 'opencl_engine.cpp'),
    (Join-Path $engineRoot 'main.cpp'),
    (Join-Path $engineRoot 'third_party\profanity2\precomp.cpp')
)
$cppObjects = @()
foreach ($source in $cppSources) {
    $object = Join-Path $objectRoot (([IO.Path]::GetFileNameWithoutExtension($source)) + '.obj')
    if ($source.EndsWith('third_party\profanity2\precomp.cpp', [StringComparison]::OrdinalIgnoreCase)) {
        $object = Join-Path $objectRoot 'profanity_precomp.obj'
    }
    Invoke-Native $cl (@(
        '/nologo', '/c', '/MT', '/DNDEBUG', '/EHsc',
        '/std:c++17', '/permissive-', '/Zc:__cplusplus', '/Zc:inline', '/utf-8', '/W3'
    ) + $optimizationFlags + $cpuFlags + @(
        "/I$engineRoot", "/I$secpInclude",
        "/Fo$object", $source
    ))
    $cppObjects += $object
}

$engineExe = Join-Path $distRoot 'trxvanity-gpu.exe'
$nativeObjects = @(
    (Join-Path $objectRoot 'secp256k1.obj'),
    (Join-Path $objectRoot 'precomputed_ecmult.obj'),
    (Join-Path $objectRoot 'precomputed_ecmult_gen.obj')
) + $cppObjects
Invoke-Native $link (@(
    '/nologo', '/LTCG', '/INCREMENTAL:NO', '/SUBSYSTEM:CONSOLE', '/MACHINE:X64',
    '/OPT:REF', '/OPT:ICF=8', '/DYNAMICBASE', '/NXCOMPAT', '/HIGHENTROPYVA',
    "/OUT:$engineExe"
) + $nativeObjects + @($openClImportLibrary, 'bcrypt.lib'))

$appExe = Join-Path $distRoot 'TRXVanity.exe'
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

$decryptExe = Join-Path $distRoot 'TRXVanityBackupDecrypt.exe'
Invoke-Native $csc @(
    '/nologo', '/target:exe', '/platform:x64', '/optimize+',
    '/langversion:5', '/codepage:65001',
    '/main:TRXVanity.WindowsApp.BackupDecryptProgram',
    "/out:$decryptExe",
    '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Security.dll',
    (Join-Path $appRoot 'BackupCrypto.cs'),
    (Join-Path $appRoot 'BackupDecrypt.cs')
)

$kernelOutput = Join-Path $distRoot 'kernels'
New-Item -ItemType Directory -Force $kernelOutput | Out-Null
Copy-Item -LiteralPath (Join-Path $engineRoot 'kernels\keccak.cl') -Destination $kernelOutput -Force
Copy-Item -LiteralPath (Join-Path $engineRoot 'kernels\profanity.cl') -Destination $kernelOutput -Force
Copy-Item -LiteralPath (Join-Path $engineRoot 'kernels\tron.cl') -Destination $kernelOutput -Force

$licenseOutput = Join-Path $distRoot 'ThirdPartyLicenses'
New-Item -ItemType Directory -Force $licenseOutput | Out-Null
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'ThirdPartyLicenses\libsecp256k1-MIT.txt') -Destination $licenseOutput -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'ThirdPartyLicenses\profanity2-MIT.txt') -Destination $licenseOutput -Force

if (-not $SkipTests) {
    & $decryptExe --self-test
    if ($LASTEXITCODE -ne 0) {
        throw "AES backup self-test failed (exit code $LASTEXITCODE)."
    }

    $selfTestArguments = @('--self-test')
    if (-not $FullGpuSelfTest) {
        # A small fixed batch validates the CPU/GPU result path without
        # allocating the production auto-sized multi-gigabyte lane buffers.
        $selfTestArguments += @('--inverse-multiple', '16384')
    }
    & $engineExe @selfTestArguments
    if ($LASTEXITCODE -ne 0) {
        throw "GPU self-test failed (exit code $LASTEXITCODE)."
    }
}

Write-Host "Build completed ($CpuTarget): $appExe"
