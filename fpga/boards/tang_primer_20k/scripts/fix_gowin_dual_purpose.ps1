param(
  [string]$ProjectDir = (Resolve-Path (Join-Path $PSScriptRoot "..\project")).Path
)

$ErrorActionPreference = "Stop"

$gprj = Join-Path $ProjectDir "tang_sbc.gprj"
$synPrj = Join-Path $ProjectDir "impl\gwsynthesis\tang_sbc.prj"
$pnrCmd = Join-Path $ProjectDir "impl\pnr\cmd.do"
$devCfg = Join-Path $ProjectDir "impl\pnr\device.cfg"
$procCfg = Join-Path $ProjectDir "impl\project_process_config.json"

function Update-TextFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][scriptblock]$Edit
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "skip missing $Path"
    return
  }

  $text = Get-Content -LiteralPath $Path -Raw
  $newText = & $Edit $text
  if ($newText -ne $text) {
    Set-Content -LiteralPath $Path -Value $newText -NoNewline
    Write-Host "updated $Path"
  } else {
    Write-Host "ok $Path"
  }
}

if (-not (Test-Path -LiteralPath $devCfg)) {
  throw "Missing $devCfg. Run Gowin synthesis first so P&R files are generated, then run this script before Place & Route."
}

Update-TextFile $gprj {
  param($text)
  $text -replace '<Device name="GW2A-18" pn="GW2A-LV18PG256C8/I7">gw2a18-002</Device>',
                 '<Device name="GW2A-18C" pn="GW2A-LV18PG256C8/I7">gw2a18c-011</Device>'
}

Update-TextFile $synPrj {
  param($text)
  $text -replace 'Device id="GW2A-18"', 'Device id="GW2A-18C"'
}

Update-TextFile $pnrCmd {
  param($text)
  $text -replace '-p GW2A-18-PBGA256-8', '-p GW2A-18C-PBGA256-8'
}

Update-TextFile $devCfg {
  param($text)
  $text = $text -replace 'set SSPI regular_io = false', 'set SSPI regular_io = true'
  $text -replace 'set MSPI regular_io = false', 'set MSPI regular_io = true'
}

Update-TextFile $procCfg {
  param($text)
  $text = $text -replace '"SSPI"\s*:\s*false', '"SSPI" : true'
  $text -replace '"MSPI"\s*:\s*false', '"MSPI" : true'
}

Write-Host ""
Select-String -LiteralPath $devCfg -Pattern "SSPI|MSPI"
Select-String -LiteralPath $pnrCmd -Pattern "GW2A"
Write-Host "Gowin dual-purpose pin fixup complete."
