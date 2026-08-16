[CmdletBinding()]
param(
    [string]$Engine = '',
    [ValidateRange(0.25, 3600.0)]
    [double]$SecondsPerRun = 5.0,
    [ValidateRange(0.0, 3600.0)]
    [double]$WarmupSeconds = 2.0,
    [ValidateRange(1, 30)]
    [int]$Runs = 3,
    [string]$Suffix = '9999999999',
    [uint64]$InverseMultiple = 0,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$invariant = [Globalization.CultureInfo]::InvariantCulture

if ([string]::IsNullOrWhiteSpace($Engine)) {
    $Engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\trxvanity-gpu.exe'
}
if (-not (Test-Path -LiteralPath $Engine -PathType Leaf)) {
    throw "Engine executable was not found: $Engine"
}
$enginePath = (Resolve-Path -LiteralPath $Engine).Path

$alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
if ($Suffix.Length -lt 1 -or $Suffix.Length -gt 10) {
    throw 'Suffix must contain 1 to 10 TRON Base58 characters.'
}
foreach ($character in $Suffix.ToCharArray()) {
    if ($alphabet.IndexOf($character) -lt 0) {
        throw "Suffix contains a non-Base58 character: $character"
    }
}
if ($InverseMultiple -ne 0 -and $InverseMultiple % 256 -ne 0) {
    throw 'InverseMultiple must be zero (automatic) or a multiple of 256.'
}

function Get-GpuTelemetry {
    $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        return $null
    }
    $lines = @(& $nvidiaSmi.Source `
        '--query-gpu=temperature.gpu,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,utilization.gpu' `
        '--format=csv,noheader,nounits' 2>$null)
    $nvidiaSmiExitCode = $LASTEXITCODE
    if ($nvidiaSmiExitCode -ne 0 -or $lines.Count -eq 0) {
        return $null
    }
    $line = $lines[0]
    $fields = @($line -split ',' | ForEach-Object { $_.Trim() })
    if ($fields.Count -lt 6) {
        return $null
    }
    try {
        return [pscustomobject]@{
            TemperatureC = [double]::Parse($fields[0], $invariant)
            PowerW = [double]::Parse($fields[1], $invariant)
            PowerLimitW = [double]::Parse($fields[2], $invariant)
            GraphicsClockMHz = [int]::Parse($fields[3], $invariant)
            MemoryClockMHz = [int]::Parse($fields[4], $invariant)
            UtilizationPercent = [int]::Parse($fields[5], $invariant)
        }
    } catch [FormatException] {
        return $null
    }
}

$arguments = '--server'
if ($InverseMultiple -ne 0) {
    $arguments += " --inverse-multiple $InverseMultiple"
}
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $enginePath
$startInfo.Arguments = $arguments
$startInfo.WorkingDirectory = Split-Path -Parent $enginePath
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true

$engineProcess = [Diagnostics.Process]::new()
$engineProcess.StartInfo = $startInfo
if (-not $engineProcess.Start()) {
    throw 'Unable to start the GPU engine.'
}

function Read-EngineLine {
    $line = $engineProcess.StandardOutput.ReadLine()
    if ($null -eq $line) {
        $diagnostic = $engineProcess.StandardError.ReadToEnd()
        throw "GPU engine exited unexpectedly ($($engineProcess.ExitCode)): $diagnostic"
    }
    if ($line.StartsWith("RESULT`t", [StringComparison]::Ordinal)) {
        Write-Verbose 'RESULT <private result redacted>'
    } else {
        Write-Verbose $line
    }
    return $line
}

function Invoke-SearchSample {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Duration,
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        [Parameter(Mandatory = $true)]
        [int]$Run
    )

    $engineProcess.StandardInput.WriteLine("START`t`t$Suffix")
    $engineProcess.StandardInput.Flush()
    $stopSent = $false
    $lastAttempts = [uint64]0
    $lastSpeed = 0.0
    $lastElapsed = 0.0
    $telemetry = $null

    while ($true) {
        $fields = (Read-EngineLine) -split "`t"
        switch ($fields[0]) {
            'PROGRESS' {
                if ($fields.Count -lt 4) {
                    throw 'The engine emitted a malformed PROGRESS line.'
                }
                if (-not $stopSent) {
                    $lastAttempts = [uint64]::Parse($fields[1], $invariant)
                    $lastSpeed = [double]::Parse($fields[2], $invariant)
                    $lastElapsed = [double]::Parse($fields[3], $invariant)
                    if ($lastElapsed -ge $Duration) {
                        # Capture telemetry while the GPU is known to be busy,
                        # then stop. Freeze this PROGRESS frame so nvidia-smi
                        # latency and buffered shutdown progress cannot enter
                        # the reported measurement.
                        $telemetry = Get-GpuTelemetry
                        $engineProcess.StandardInput.WriteLine('STOP')
                        $engineProcess.StandardInput.Flush()
                        $stopSent = $true
                    }
                }
            }
            'RESULT' {
                # Never echo a private key if the astronomically unlikely
                # benchmark suffix happens to match.
                throw 'The benchmark suffix unexpectedly produced a result; choose another 10-character suffix.'
            }
            'ERROR' {
                throw ($fields -join "`t")
            }
            'STOPPED' {
                if (-not $stopSent -or $lastElapsed -le 0.0) {
                    throw 'The engine stopped before producing a measurement.'
                }
                return [pscustomobject]@{
                    Kind = $Kind
                    Run = $Run
                    AttemptsPerSecond = $lastSpeed
                    Attempts = $lastAttempts
                    ElapsedSeconds = $lastElapsed
                    Gpu = $telemetry
                }
            }
        }
    }
}

$startedAt = [DateTimeOffset]::Now
$samples = [Collections.Generic.List[object]]::new()
$deviceName = ''
$laneCount = [uint64]0

try {
    while ($true) {
        $line = Read-EngineLine
        $fields = $line -split "`t"
        if ($fields[0] -eq 'READY') {
            if ($fields.Count -ge 3) {
                $deviceName = $fields[1]
                $laneCount = [uint64]::Parse($fields[2], $invariant)
            }
            break
        }
        if ($fields[0] -eq 'ERROR') {
            throw $line
        }
    }

    Write-Output "READY`t$deviceName`t$laneCount"

    if ($WarmupSeconds -gt 0.0) {
        [void](Invoke-SearchSample -Duration $WarmupSeconds -Kind 'warmup' -Run 0)
    }

    for ($run = 1; $run -le $Runs; ++$run) {
        $sample = Invoke-SearchSample -Duration $SecondsPerRun -Kind 'measurement' -Run $run
        $samples.Add($sample)
        $gpuText = if ($null -eq $sample.Gpu) {
            'gpu-telemetry-unavailable'
        } else {
            [string]::Format(
                $invariant,
                '{0:F1}W/{1:F1}W {2}MHz {3}%',
                $sample.Gpu.PowerW,
                $sample.Gpu.PowerLimitW,
                $sample.Gpu.GraphicsClockMHz,
                $sample.Gpu.UtilizationPercent)
        }
        Write-Output ([string]::Format(
            $invariant,
            "BENCHMARK`t{0}`t{1:F3}`t{2}`t{3:F3}`t{4}",
            $run,
            $sample.AttemptsPerSecond,
            $sample.Attempts,
            $sample.ElapsedSeconds,
            $gpuText))
    }

    $engineProcess.StandardInput.WriteLine('EXIT')
    $engineProcess.StandardInput.Flush()
    if (-not $engineProcess.WaitForExit(10000)) {
        throw 'GPU engine did not exit within 10 seconds.'
    }
} finally {
    if (-not $engineProcess.HasExited) {
        $engineProcess.Kill()
        $engineProcess.WaitForExit()
    }
    $engineProcess.Dispose()
}

$orderedSpeeds = @($samples | ForEach-Object { [double]$_.AttemptsPerSecond } | Sort-Object)
$mean = [double](($orderedSpeeds | Measure-Object -Average).Average)
if ($orderedSpeeds.Count % 2 -eq 1) {
    $median = $orderedSpeeds[[int][Math]::Floor($orderedSpeeds.Count / 2)]
} else {
    $upper = [int]($orderedSpeeds.Count / 2)
    $median = ($orderedSpeeds[$upper - 1] + $orderedSpeeds[$upper]) / 2.0
}
$sumSquares = 0.0
foreach ($speed in $orderedSpeeds) {
    $sumSquares += [Math]::Pow($speed - $mean, 2.0)
}
$standardDeviation = [Math]::Sqrt($sumSquares / $orderedSpeeds.Count)
$summary = [pscustomobject]@{
    MedianAttemptsPerSecond = $median
    MeanAttemptsPerSecond = $mean
    MinimumAttemptsPerSecond = $orderedSpeeds[0]
    MaximumAttemptsPerSecond = $orderedSpeeds[-1]
    StandardDeviation = $standardDeviation
    RelativeStandardDeviationPercent = if ($mean -gt 0.0) {
        100.0 * $standardDeviation / $mean
    } else {
        0.0
    }
}

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$operatingSystem = Get-CimInstance Win32_OperatingSystem
$nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
$gpuIdentity = $null
if ($nvidiaSmi) {
    $gpuIdentity = @(& $nvidiaSmi.Source `
        '--query-gpu=name,driver_version,memory.total,power.limit' `
        '--format=csv,noheader,nounits' 2>$null)
}
$kernelHashes = @()
$kernelDirectory = Join-Path (Split-Path -Parent $enginePath) 'kernels'
if (Test-Path -LiteralPath $kernelDirectory -PathType Container) {
    $kernelHashes = @(Get-ChildItem -LiteralPath $kernelDirectory -File -Filter '*.cl' |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        })
}
$buildInfoPath = Join-Path (Split-Path -Parent $enginePath) 'build-info.txt'
$buildInfo = if (Test-Path -LiteralPath $buildInfoPath -PathType Leaf) {
    @(Get-Content -LiteralPath $buildInfoPath | ForEach-Object { [string]$_ })
} else {
    @()
}
$activePowerScheme = (& powercfg.exe /getactivescheme 2>$null | Select-Object -First 1)
$report = [pscustomobject]@{
    SchemaVersion = 1
    StartedAt = $startedAt.ToString('o')
    Engine = $enginePath
    EngineSha256 = (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash
    BuildInfo = $buildInfo
    KernelHashes = $kernelHashes
    Device = $deviceName
    LaneCount = $laneCount
    InverseMultiple = $InverseMultiple
    Suffix = $Suffix
    SecondsPerRun = $SecondsPerRun
    WarmupSeconds = $WarmupSeconds
    Runs = $Runs
    Cpu = if ($cpu) { $cpu.Name } else { $null }
    LogicalProcessors = if ($cpu) { $cpu.NumberOfLogicalProcessors } else { $null }
    OperatingSystem = if ($operatingSystem) {
        "$($operatingSystem.Caption) $($operatingSystem.Version)"
    } else {
        $null
    }
    PowerScheme = $activePowerScheme
    NvidiaGpu = $gpuIdentity
    Samples = @($samples)
    Summary = $summary
}

Write-Output ([string]::Format(
    $invariant,
    "SUMMARY`tmedian={0:F3}`tmean={1:F3}`tmin={2:F3}`tmax={3:F3}`trsd={4:F3}%",
    $summary.MedianAttemptsPerSecond,
    $summary.MeanAttemptsPerSecond,
    $summary.MinimumAttemptsPerSecond,
    $summary.MaximumAttemptsPerSecond,
    $summary.RelativeStandardDeviationPercent))

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputParent = Split-Path -Parent $OutputPath
    if ($outputParent -and -not (Test-Path -LiteralPath $outputParent)) {
        New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Output "REPORT`t$((Resolve-Path -LiteralPath $OutputPath).Path)"
}
