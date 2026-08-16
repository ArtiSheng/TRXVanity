#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        throw 'Run this script from an elevated Windows PowerShell window.'
    }

    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs `
        -ArgumentList $arguments -PassThru -Wait
    exit $process.ExitCode
}

$displayClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$candidates = @(
    # The display class also contains a protected "Properties" subkey on some
    # Windows installations. It is not an adapter entry, so skip inaccessible
    # children instead of aborting the entire repair.
    foreach ($adapterKey in Get-ChildItem -LiteralPath $displayClass -ErrorAction SilentlyContinue) {
        $adapter = Get-ItemProperty -LiteralPath $adapterKey.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $adapter) {
            continue
        }

        $isNvidia = ([string]$adapter.ProviderName -match 'NVIDIA') `
            -or ([string]$adapter.DriverDesc -match 'NVIDIA')
        if (-not $isNvidia) {
            continue
        }

        foreach ($driverPath in @($adapter.OpenCLDriverName)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$driverPath) `
                    -and (Test-Path -LiteralPath $driverPath -PathType Leaf)) {
                [pscustomobject]@{
                    Architecture = '64-bit'
                    DriverPath = [string]$driverPath
                }
            }
        }

        foreach ($driverPath in @($adapter.OpenCLDriverNameWow)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$driverPath) `
                    -and (Test-Path -LiteralPath $driverPath -PathType Leaf)) {
                [pscustomobject]@{
                    Architecture = '32-bit'
                    DriverPath = [string]$driverPath
                }
            }
        }
    }
)

$driver64 = $candidates |
    Where-Object { $_.Architecture -eq '64-bit' } |
    Select-Object -First 1
$driver32 = $candidates |
    Where-Object { $_.Architecture -eq '32-bit' } |
    Select-Object -First 1

if ($null -eq $driver64) {
    throw 'The installed NVIDIA 64-bit OpenCL driver was not found.'
}
if ($null -eq $driver32) {
    throw 'The installed NVIDIA 32-bit OpenCL driver was not found.'
}

$registrations = @(
    [pscustomobject]@{
        RegistryKey = 'HKLM:\SOFTWARE\Khronos\OpenCL\Vendors'
        DriverPath = $driver64.DriverPath
    },
    [pscustomobject]@{
        RegistryKey = 'HKLM:\SOFTWARE\WOW6432Node\Khronos\OpenCL\Vendors'
        DriverPath = $driver32.DriverPath
    }
)

foreach ($registration in $registrations) {
    New-Item -Path $registration.RegistryKey -Force | Out-Null
    New-ItemProperty -LiteralPath $registration.RegistryKey `
        -Name $registration.DriverPath -PropertyType DWord -Value 0 -Force | Out-Null

    $key = Get-Item -LiteralPath $registration.RegistryKey
    if ($key.GetValueKind($registration.DriverPath) -ne [Microsoft.Win32.RegistryValueKind]::DWord `
            -or $key.GetValue($registration.DriverPath) -ne 0) {
        throw "Failed to verify OpenCL ICD registration: $($registration.DriverPath)"
    }

    Write-Host "Registered $($registration.DriverPath)" -ForegroundColor Green
}

Write-Host 'OpenCL registry repair completed. A Windows restart is not required.' -ForegroundColor Green
