<#
.SYNOPSIS
  Copies the TradeCopier MQL5 sources into each portable MT5 install and compiles them.

.EXAMPLE
  .\scripts\deploy.ps1
  .\scripts\deploy.ps1 -Mt5Root D:\MT5 -Terminals Master,Follower1
#>
param(
    [string]   $Mt5Root   = "D:\MT5",
    [string[]] $Terminals = @("Master", "Follower1", "Follower2")
)

$ErrorActionPreference = "Stop"
$src = Join-Path (Split-Path $PSScriptRoot -Parent) "MQL5"
$failed = $false

foreach ($t in $Terminals) {
    $home5  = Join-Path $Mt5Root $t
    $editor = Join-Path $home5 "MetaEditor64.exe"
    if (-not (Test-Path $editor)) { Write-Warning "$t - MetaEditor64.exe not found in $home5, skipped"; continue }

    foreach ($dir in "Include\TradeCopier", "Experts\TradeCopier") {
        $dst = Join-Path $home5 "MQL5\$dir"
        New-Item -ItemType Directory -Force $dst | Out-Null
        Copy-Item (Join-Path $src "$dir\*") $dst -Recurse -Force
    }

    foreach ($ea in Get-ChildItem (Join-Path $home5 "MQL5\Experts\TradeCopier\*.mq5")) {
        $log = [IO.Path]::ChangeExtension($ea.FullName, ".log")
        Remove-Item $log -ErrorAction SilentlyContinue
        Start-Process -FilePath $editor -Wait -WindowStyle Hidden `
            -ArgumentList "/portable", "/compile:`"$($ea.FullName)`"", "/log:`"$log`""

        $text   = if (Test-Path $log) { Get-Content $log -Raw -Encoding Unicode } else { "" }
        $result = [regex]::Match($text, "(\d+) errors?, (\d+) warnings?")
        if ($result.Success -and $result.Groups[1].Value -eq "0") {
            Write-Host ("{0,-10} {1,-22} OK ({2} warnings)" -f $t, $ea.Name, $result.Groups[2].Value) -ForegroundColor Green
        } else {
            $failed = $true
            Write-Host ("{0,-10} {1,-22} FAILED" -f $t, $ea.Name) -ForegroundColor Red
            $text -split "`r?`n" | Where-Object { $_ -match "error|warning" } | ForEach-Object { Write-Host "    $_" }
        }
    }
}

if ($failed) { exit 1 }

# Keep the dashboard's build cache current: "Add account" installs these .ex5 files.
$build = Join-Path $env:APPDATA "MetaQuotes\Terminal\Common\Files\TradeCopier\build"
$first = Join-Path $Mt5Root "$($Terminals[0])\MQL5\Experts\TradeCopier"
if (-not $failed -and (Test-Path "$first\CopierFollower.ex5")) {
    New-Item -ItemType Directory -Force $build | Out-Null
    Copy-Item "$first\*.ex5" $build -Force
}
