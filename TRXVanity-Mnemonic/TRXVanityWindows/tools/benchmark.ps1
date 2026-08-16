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
    [ValidateSet('rtx5070', 'rtx4090', 'smart')]
    [string]$Profile = 'smart',
    [ValidateRange(0, 4194304)]
    [uint32]$BatchSize = 0,
    [ValidateRange(-1, 256)]
    [int]$CpuWorkers = -1,
    [ValidateSet(0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 480, 512)]
    [int]$CudaBlockSize = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$invariant = [Globalization.CultureInfo]::InvariantCulture

if ([string]::IsNullOrWhiteSpace($Engine)) {
    $Engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'build\trxvanity-gpu.exe'
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

$arguments = "--server --profile $Profile"
if ($BatchSize -ne 0) {
    $arguments += " --batch-size $BatchSize"
}
if ($CpuWorkers -ge 0) {
    $arguments += " --cpu-workers $CpuWorkers"
}
if ($CudaBlockSize -gt 0) {
    $arguments += " --cuda-block-size $CudaBlockSize"
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
        Write-Verbose 'RESULT <mnemonic result redacted>'
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
    $lastGpuAttempts = [uint64]0
    $lastCpuAttempts = [uint64]0
    $lastSpeed = 0.0
    $lastElapsed = 0.0
    $lastBatchSize = [uint64]0
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
                    if ($fields.Count -ge 9) {
                        $lastBatchSize = [uint64]::Parse($fields[6], $invariant)
                        $lastGpuAttempts = [uint64]::Parse($fields[7], $invariant)
                        $lastCpuAttempts = [uint64]::Parse($fields[8], $invariant)
                    }
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
                # Never echo a mnemonic if the astronomically unlikely
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
                    GpuAttempts = $lastGpuAttempts
                    CpuAttempts = $lastCpuAttempts
                    ElapsedSeconds = $lastElapsed
                    TunedBatchSize = $lastBatchSize
                    Gpu = $telemetry
                }
            }
        }
    }
}

$samples = [Collections.Generic.List[object]]::new()
$deviceName = ''
$batchCapacity = [uint64]0
$activeProfile = ''
$cpuWorkerCount = [uint32]0
$activeBatchSize = [uint64]0
$cudaBlockSize = [uint32]0
$cudaAddressBlockSize = [uint32]0
$kernelMode = ''

try {
    while ($true) {
        $line = Read-EngineLine
        $fields = $line -split "`t"
        if ($fields[0] -eq 'READY') {
            if ($fields.Count -ge 3) {
                $deviceName = $fields[1]
                $batchCapacity = [uint64]::Parse($fields[2], $invariant)
                if ($fields.Count -ge 9) {
                    $activeProfile = $fields[3]
                    $cpuWorkerCount = [uint32]::Parse($fields[4], $invariant)
                    $activeBatchSize = [uint64]::Parse($fields[5], $invariant)
                    $cudaBlockSize = [uint32]::Parse($fields[6], $invariant)
                    $cudaAddressBlockSize = [uint32]::Parse($fields[7], $invariant)
                    $kernelMode = $fields[8]
                }
            }
            break
        }
        if ($fields[0] -eq 'ERROR') {
            throw $line
        }
    }

    Write-Output "READY`t$deviceName`t$batchCapacity`t$activeProfile`t$cpuWorkerCount`t$activeBatchSize`t$cudaBlockSize/$cudaAddressBlockSize`t$kernelMode"

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
            "BENCHMARK`t{0}`t{1:F3}`t{2}`t{3:F3}`tbatch={4}`t{5}",
            $run,
            $sample.AttemptsPerSecond,
            $sample.Attempts,
            $sample.ElapsedSeconds,
            $sample.TunedBatchSize,
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

Write-Output ([string]::Format(
    $invariant,
    "SUMMARY`tmedian={0:F3}`tmean={1:F3}`tmin={2:F3}`tmax={3:F3}`trsd={4:F3}%",
    $summary.MedianAttemptsPerSecond,
    $summary.MeanAttemptsPerSecond,
    $summary.MinimumAttemptsPerSecond,
    $summary.MaximumAttemptsPerSecond,
    $summary.RelativeStandardDeviationPercent))
