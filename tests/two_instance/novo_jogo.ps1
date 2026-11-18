# Cria um estado de jogo novo já no mapa para uma ROM sem save (para o teste de compatibilidade).
# Uso: novo_jogo.ps1 -Rom <rom.gba> -Profile <perfil.lua> -Out <estado.ss0> [-Seconds 600]
param([Parameter(Mandatory)][string]$Rom,[Parameter(Mandatory)][string]$Profile,[Parameter(Mandatory)][string]$Out,[int]$Seconds=600,[string]$Slot='')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$Rom=[IO.Path]::GetFullPath($Rom);$Profile=[IO.Path]::GetFullPath($Profile);$Out=[IO.Path]::GetFullPath($Out)
$folder=Join-Path $root "tests\artifacts\runtime\novo$Slot"   # -Slot '-2', '-3'...: pasta própria para testes em paralelo
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$emulator=Get-ChildItem -LiteralPath (Join-Path $root 'tools\mgba-dev') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'mGBA.exe') } | Sort-Object Name -Descending | Select-Object -First 1
$exe=Join-Path $folder 'mGBA.exe'
if(-not (Test-Path -LiteralPath $exe)) { New-Item -ItemType HardLink -Path $exe -Target (Join-Path $emulator.FullName 'mGBA.exe') | Out-Null }
$game=Join-Path $folder 'jogo.gba'
Copy-Item -LiteralPath $Rom -Destination $game -Force
Remove-Item -LiteralPath (Join-Path $folder 'jogo.sav') -Force -ErrorAction SilentlyContinue   # jogo novo: sem save
Copy-Item -LiteralPath (Join-Path $root 'vendor\gba-pk\GBA-PK_Multiplayer.lua') -Destination (Join-Path $folder 'GBA-PK_Multiplayer.lua') -Force
New-Item -ItemType File -Force -Path (Join-Path $folder 'portable.ini') | Out-Null
$log=[IO.Path]::ChangeExtension($Out,'.log')
Remove-Item -LiteralPath $Out,$log -Force -ErrorAction SilentlyContinue
$entry=Join-Path $folder 'novo.lua'
$body=@(
  "NOVO_OUT=[[$($Out.Replace('\','/'))]]",
  "NOVO_LOG=[[$($log.Replace('\','/'))]]",
  "DP_PROFILE=[[$($Profile.Replace('\','/'))]]",
  "DP_GBAPK=[[$((Join-Path $folder 'GBA-PK_Multiplayer.lua').Replace('\','/'))]]",
  "DP_DATA=[[$($folder.Replace('\','/'))]]",
  "dofile([[$((Join-Path $PSScriptRoot 'novo_jogo.lua').Replace('\','/'))]])"
)
# sem BOM: o mGBA não aceita script que começa com BOM
[IO.File]::WriteAllLines($entry,[string[]]$body,(New-Object System.Text.UTF8Encoding($false)))
$p=Start-Process -FilePath $exe -ArgumentList @('-C','fpsTarget=600','-C','audioSync=0','-C','videoSync=0','--script',('"'+$entry+'"'),('"'+$game+'"')) -WorkingDirectory $folder -WindowStyle Minimized -PassThru   # escondida, a interface do mGBA pode congelar
try {
  for($t=0;$t -lt $Seconds;$t+=3) { Start-Sleep -Seconds 3; if(Test-Path -LiteralPath $Out) { Start-Sleep 1; break }; if($p.HasExited) { break } }
} finally { if(-not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
if(Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 6 }
if(Test-Path -LiteralPath $Out) { "estado: $Out" } else { 'sem estado: o jogo não chegou livre ao mapa no tempo' }
