# Abre as duas instâncias do modo Duplas no mesmo PC, já pareadas, para testar jogando.
# Cada uma recebe uma cópia nova do seu save original (o save original não é alterado). O que existia nas pastas
# demo\host e demo\guest (saves e dados de sessões anteriores) vai para demo\backup-<data> antes.
# Uso: powershell -ExecutionPolicy Bypass -File testar-duas-instancias.ps1 -Rom <jogo.gba> [-ManterSaves] [-Idioma en|pt|es]
param([switch]$ManterSaves, [ValidateSet('','en','pt','es')][string]$Idioma = '', [string]$Rom = '', [string]$Save = '', [string]$Profile = '',
  [double]$Velocidade = 0)
$ErrorActionPreference = 'Stop'
$demo = Join-Path $PSScriptRoot 'demo'
# fecha só as janelas de teste anteriores (coop\demo); o mGBA do pacote do jogo não é tocado
Get-Process mGBA -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($demo, [StringComparison]::OrdinalIgnoreCase) } |
  ForEach-Object { "Fechando a janela de teste anterior (PID $($_.Id))"; Stop-Process -Id $_.Id -Force }
Start-Sleep -Seconds 1
if (-not $ManterSaves) {
  $backup = Join-Path $demo ('backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  foreach ($role in 'host', 'guest') {
    $folder = Join-Path $demo $role
    if (-not (Test-Path -LiteralPath $folder)) { continue }
    $target = Join-Path $backup $role
    foreach ($item in 'jogo.sav', 'PhoenixRising.sav', 'dados', 'GBA-PK_Multiplayer.ini') {
      $path = Join-Path $folder $item
      if (Test-Path -LiteralPath $path) {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Move-Item -LiteralPath $path -Destination (Join-Path $target $item)
      }
    }
  }
  if (Test-Path -LiteralPath $backup) { "Sessão anterior guardada em $backup" }
}
$launcher = Join-Path $PSScriptRoot 'iniciar-demo.ps1'
$extra = @{}
if ($Idioma) { $extra.Idioma = $Idioma }
if ($Rom) { $extra.Rom = $Rom }
if ($Save) { $extra.Save = $Save }
if ($Profile) { $extra.Profile = $Profile }
if ($Velocidade -gt 0) { $extra.Velocidade = $Velocidade }   # as duas janelas sempre na mesma velocidade
& $launcher -Role host -AutoConnect -LocalOnly @extra
Start-Sleep -Seconds 4
& $launcher -Role guest -HostIP 127.0.0.1 -AutoConnect -LocalOnly @extra
$lang = $Idioma
if (-not $lang) {
  $lang = 'en'
  $arquivo = Join-Path $PSScriptRoot '..\idioma.txt'
  if (Test-Path -LiteralPath $arquivo) { $lido = (Get-Content -LiteralPath $arquivo -TotalCount 1).Trim().ToLowerInvariant(); if ($lido -in @('en','pt','es')) { $lang = $lido } }
}
''
@{ en = 'Two mGBA windows are open: host and partner. They connect by themselves in a few seconds. Play in the window in front; the other one keeps running.'
   pt = 'Duas janelas do mGBA abertas: anfitrião e parceiro. Elas se conectam sozinhas em alguns segundos. Jogue na janela da frente; a outra continua rodando.'
   es = 'Dos ventanas de mGBA abiertas: anfitrión y compañero. Se conectan solas en unos segundos. Juega en la ventana de delante; la otra sigue funcionando.' }[$lang]
