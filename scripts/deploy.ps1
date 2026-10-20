<#
.SYNOPSIS
  Copies the TradeCopier MQL5 sources into each portable MT5 install and compiles them.

  By default it updates every account added in the dashboard (accounts.json),
  so accounts created with "Add account" get new builds too.

.EXAMPLE
  .\scripts\deploy.ps1
  .\scripts\deploy.ps1 -Mt5Root D:\MT5 -Terminals Master,Follower1
#>
param(
    [string]   $Mt5Root   = "D:\MT5",
    [string[]] $Terminals = @()    # folder names under Mt5Root, or full paths
)

$ErrorActionPreference = "Stop"
$src = Join-Path (Split-Path $PSScriptRoot -Parent) "MQL5"
$common = Join-Path $env:APPDATA "MetaQuotes\Terminal\Common\Files\TradeCopier"
$failed = $false
$built = $null    # first terminal that compiled cleanly: source for the build cache

$dataOf = @{}   # attached normal installs keep MQL5 under %APPDATA% (data_dir)
if (-not $Terminals) {
    $registry = Join-Path $common "accounts.json"
    $Terminals = if (Test-Path $registry) {
        foreach ($a in (Get-Content $registry -Raw | ConvertFrom-Json)) { if ($a.data_dir) { $dataOf[$a.dir] = $a.data_dir }; $a.dir }
    } else { @("Master", "Follower1", "Follower2") }
}

foreach ($t in $Terminals) {
    $home5    = if ([IO.Path]::IsPathRooted($t)) { $t } else { Join-Path $Mt5Root $t }
    $editor   = Join-Path $home5 "MetaEditor64.exe"
    $portable = -not $dataOf[$t]
    $data     = if ($portable) { $home5 } else { $dataOf[$t] }
    if (-not (Test-Path $editor)) { Write-Warning "$t - MetaEditor64.exe not found in $home5, skipped"; continue }

    foreach ($dir in "Include\TradeCopier", "Experts\TradeCopier") {
        $dst = Join-Path $data "MQL5\$dir"
        New-Item -ItemType Directory -Force $dst | Out-Null
        Copy-Item (Join-Path $src "$dir\*") $dst -Recurse -Force
    }

    foreach ($ea in Get-ChildItem (Join-Path $data "MQL5\Experts\TradeCopier\*.mq5")) {
        $log = [IO.Path]::ChangeExtension($ea.FullName, ".log")
        Remove-Item $log -ErrorAction SilentlyContinue
        $editorArgs = @("/compile:`"$($ea.FullName)`"", "/log:`"$log`"")
        if ($portable) { $editorArgs = @("/portable") + $editorArgs }
        Start-Process -FilePath $editor -Wait -WindowStyle Hidden -ArgumentList $editorArgs

        $text   = if (Test-Path $log) { Get-Content $log -Raw -Encoding Unicode } else { "" }
        $result = [regex]::Match($text, "(\d+) errors?, (\d+) warnings?")
        if ($result.Success -and $result.Groups[1].Value -eq "0") {
            Write-Host ("{0,-20} {1,-22} OK ({2} warnings)" -f (Split-Path $home5 -Leaf), $ea.Name, $result.Groups[2].Value) -ForegroundColor Green
            if (-not $built) { $built = Join-Path $data "MQL5\Experts\TradeCopier" }
        } else {
            $failed = $true
            Write-Host ("{0,-20} {1,-22} FAILED" -f (Split-Path $home5 -Leaf), $ea.Name) -ForegroundColor Red
            $text -split "`r?`n" | Where-Object { $_ -match "error|warning" } | ForEach-Object { Write-Host "    $_" }
        }
    }
}

if ($failed) { exit 1 }

# Keep the dashboard's build cache current: "Add account" installs these .ex5 files.
if ($built) {
    $build = Join-Path $common "build"
    New-Item -ItemType Directory -Force $build | Out-Null
    Copy-Item "$built\*.ex5" $build -Force
    Write-Host "Build cache updated ($build)"
}
