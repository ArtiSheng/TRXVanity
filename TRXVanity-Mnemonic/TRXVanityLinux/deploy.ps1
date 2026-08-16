$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command py -ErrorAction SilentlyContinue
}
if (-not $python) {
    Write-Error "Need Python 3. Install it, then run: py -3 -m pip install -r requirements-deploy.txt"
    exit 2
}

if ($python.Name -eq "py.exe" -or $python.Name -eq "py") {
    & py -3 .\deploy.py
} else {
    & python3 .\deploy.py
}
exit $LASTEXITCODE
