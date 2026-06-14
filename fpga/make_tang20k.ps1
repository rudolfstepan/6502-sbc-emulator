<#
.SYNOPSIS
    Builds the Tang Primer 20K bitstream using GowinEDA gw_sh.

.PARAMETER Program
    After a successful build, flash the bitstream to the board via openFPGALoader.

.PARAMETER Clean
    Delete impl/ and tmp/ before building (forces full resynthesis).

.EXAMPLE
    .\make_tang20k.ps1
    .\make_tang20k.ps1 -Clean
    .\make_tang20k.ps1 -Program
#>
param(
    [switch]$Program,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$ScriptDir   = $PSScriptRoot
$BoardDir    = Join-Path $ScriptDir 'boards\tang_primer_20k'
$ProjectDir  = Join-Path $BoardDir  'project'
$Bitstream   = Join-Path $ProjectDir 'impl\pnr\tang_sbc.fs'

# Locate gw_sh — check PATH first, then common install location
$GwSh = (Get-Command gw_sh -ErrorAction SilentlyContinue)?.Source
if (-not $GwSh) {
    $GwSh = 'C:\Gowin\Gowin_V1.9.8.08\IDE\bin\gw_sh.exe'
    if (-not (Test-Path $GwSh)) {
        Write-Error "gw_sh not found on PATH and not at '$GwSh'. Add GowinEDA bin/ to PATH or install to the default location."
    }
}

if ($Clean) {
    Write-Host "Cleaning impl/ and tmp/ ..."
    Remove-Item -Recurse -Force (Join-Path $ProjectDir 'impl') -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $ProjectDir 'tmp')  -ErrorAction SilentlyContinue
}

Write-Host "Building Tang Primer 20K bitstream ..."
Write-Host "  gw_sh : $GwSh"
Write-Host "  script: $ProjectDir\build.tcl"

Push-Location $ProjectDir
try {
    & $GwSh build.tcl
    if ($LASTEXITCODE -ne 0) {
        Write-Error "gw_sh exited with code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

if (-not (Test-Path $Bitstream)) {
    Write-Error "Build succeeded but bitstream not found: $Bitstream"
}

Write-Host "Bitstream: $Bitstream"

if ($Program) {
    $Loader = (Get-Command openFPGALoader -ErrorAction SilentlyContinue)?.Source
    if (-not $Loader) {
        Write-Error "openFPGALoader not found on PATH."
    }
    Write-Host "Programming board ..."
    & $Loader -b tang_primer_20k $Bitstream
    if ($LASTEXITCODE -ne 0) {
        Write-Error "openFPGALoader exited with code $LASTEXITCODE"
    }
    Write-Host "Done."
}
