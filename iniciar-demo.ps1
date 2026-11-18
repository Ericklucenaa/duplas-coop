param(
  [ValidateSet('host','guest')][string]$Role = 'host',
  [string]$HostIP = '127.0.0.1',
  [int]$Port = 4096,
  [string]$DemoRoot = (Join-Path $PSScriptRoot 'demo'),
  # idioma dos avisos no jogo (en, pt, es). Vazio = o do arquivo idioma.txt da pasta do pacote (padrão: en)
  [ValidateSet('','en','pt','es')][string]$Idioma = '',
  [string]$Rom = '',
  [string]$Save = '',
  # perfil de endereços gerado pela ferramenta para esta ROM (vazio = FireRed 1.0 EUA)
  [string]$Profile = '',
  [switch]$AutoConnect,
  [switch]$PrepareOnly,
  # Os dois jogadores no mesmo PC: escuta só em 127.0.0.1 (o Firewall do Windows não pergunta nada)
  [switch]$LocalOnly,
  # velocidade do jogo (1 = normal, 3 = três vezes). 0 = a do arquivo velocidade.txt da pasta do pacote (padrão 3)
  [double]$Velocidade = 0
)
$ErrorActionPreference = 'Stop'
if (-not $Rom) { throw 'Informe a ROM: -Rom <arquivo .gba>.' }
if (-not $Save) { $Save = [IO.Path]::ChangeExtension($Rom, '.sav') }
if (-not $Idioma) {
  $Idioma = 'en'
  foreach ($arquivo in @((Join-Path $PSScriptRoot '..\idioma.txt'), (Join-Path $PSScriptRoot 'idioma.txt'))) {
    if (Test-Path -LiteralPath $arquivo) {
      $lido = (Get-Content -LiteralPath $arquivo -TotalCount 1).Trim().ToLowerInvariant()
      if ($lido -in @('en','pt','es')) { $Idioma = $lido }
      break
    }
  }
}
$runtime = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'tools\mgba-dev') -Directory |
  Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'mGBA.exe') } |
  Sort-Object Name -Descending | Select-Object -First 1
if (-not $runtime) { throw 'O mGBA de desenvolvimento não está em tools\mgba-dev.' }
if (-not (Test-Path -LiteralPath $Rom)) { throw "ROM ausente: $Rom" }
$destination = Join-Path $DemoRoot $Role
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$data = Join-Path $destination 'dados'
New-Item -ItemType Directory -Force -Path $data | Out-Null
foreach ($file in Get-ChildItem -LiteralPath $runtime.FullName -File) {
  $target = Join-Path $destination $file.Name
  if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $file.FullName -Destination $target }
}
# versões antigas chamavam o jogo da pasta de PhoenixRising.*: o save e o jogo passam para jogo.* sem perder nada
foreach ($ext in '.sav', '.gba') {
  $antigo = Join-Path $destination ('PhoenixRising' + $ext); $novo = Join-Path $destination ('jogo' + $ext)
  if ((Test-Path -LiteralPath $antigo) -and -not (Test-Path -LiteralPath $novo)) { Move-Item -LiteralPath $antigo -Destination $novo }
}
$game = Join-Path $destination 'jogo.gba'
# a ROM da pasta acompanha a do pacote (troca quando o arquivo de origem é outro)
if (-not (Test-Path -LiteralPath $game) -or (Get-Item -LiteralPath $game).Length -ne (Get-Item -LiteralPath $Rom).Length) {
  Copy-Item -LiteralPath $Rom -Destination $game -Force
}
$privateSave = Join-Path $destination 'jogo.sav'
if ((Test-Path -LiteralPath $Save) -and -not (Test-Path -LiteralPath $privateSave)) {
  Copy-Item -LiteralPath $Save -Destination $privateSave
}
$vendor = Join-Path $destination 'GBA-PK_Multiplayer.lua'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'vendor\gba-pk\GBA-PK_Multiplayer.lua') -Destination $vendor
$localCode = if ($Role -eq 'host') { 'PHX1' } else { 'PHX2' }
$peerCode = if ($Role -eq 'host') { 'PHX2' } else { 'PHX1' }
$ini = Join-Path $destination 'GBA-PK_Multiplayer.ini'
if (-not (Test-Path -LiteralPath $ini)) {
  @("ip=$HostIP", "port=$Port", "mode=Coop", "friendcode=$localCode", "partner=$peerCode") |
    Set-Content -LiteralPath $ini -Encoding ascii
}
function Lua-String([string]$value) {
  # JSON quoting is Lua compatible for these controlled paths; reject Lua's
  # long-string delimiter before using the path form below.
  if ($value.Contains(']]')) { throw 'Caminho com delimitador Lua não permitido.' }
  return '[[' + $value.Replace('\','/') + ']]'
}
$entry = Join-Path $PSScriptRoot 'src\iniciar-coop-nativo.lua'
$boot = Join-Path $destination 'iniciar.lua'
$body = @()
if ($Profile) { $body += "DP_PROFILE=$(Lua-String ([IO.Path]::GetFullPath($Profile)))" }
if ($LocalOnly) { $body += @("DP_BIND_ADDR='127.0.0.1'", "DP_NATIVE_BIND='127.0.0.1'") }
$body += @(
  "DP_LANG='$Idioma'",
  "DP_GBAPK=$(Lua-String $vendor)",
  "DP_DATA=$(Lua-String $data)",
  "dofile($(Lua-String $entry))"
)
if ($AutoConnect) {
  $body += @(
    # conectar é bloqueante (anfitrião ainda fechado = ~2 s de emulador parado no Windows): o convidado tenta a cada
    # 300 quadros, nunca a cada quadro
    "local f=0; local started=false; local nextTry=0",
    "callbacks:add('frame',function() f=f+1; if f>180 and f>=nextTry and DP and DP.Runtime and DP.Free() and not started then",
    "MPIni.mode='Coop';MPIni.code='$localCode';MPIni.partner='$peerCode'",
    $(if ($Role -eq 'host') { "host();started=true" } else { "nextTry=f+300;connect();if DPConnected() then started=true end" }),
    "end end)"
  )
}
[IO.File]::WriteAllLines($boot,[string[]]$body,(New-Object System.Text.UTF8Encoding($false)))
if ($PrepareOnly) { Write-Output $destination; return }
# Velocidade fixa desde a abertura: alternar a aceleração (Tab) com o parceiro conectado pode travar as duas janelas,
# então ela é escolhida antes de abrir e as teclas de acelerar ficam desligadas nestas janelas.
if ($Velocidade -le 0) {
  $Velocidade = 3
  foreach ($arquivo in @((Join-Path $PSScriptRoot '..\velocidade.txt'), (Join-Path $PSScriptRoot 'velocidade.txt'))) {
    if (Test-Path -LiteralPath $arquivo) {
      $linha = Get-Content -LiteralPath $arquivo | Where-Object { $_ -match '^\s*[0-9]' } | Select-Object -First 1
      if ($linha -and $linha.Trim() -match '^([0-9]+([.,][0-9]+)?)') {
        $Velocidade = [double]::Parse($Matches[1].Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
      }
      break
    }
  }
}
$Velocidade = [Math]::Min(10, [Math]::Max(1, $Velocidade))
$qt = Join-Path $destination 'qt.ini'
$qtTexto = if (Test-Path -LiteralPath $qt) { [IO.File]::ReadAllText($qt) } else { '' }
$qtTexto = [regex]::Replace($qtTexto, '(?ms)^\[shortcutKey\].*?(?=^\[|\z)', '')
$qtTexto = ($qtTexto.Trim() + "`r`n`r`n[shortcutKey]`r`nholdFastForward=`r`nfastForward=`r`n").TrimStart()
[IO.File]::WriteAllText($qt, $qtTexto, (New-Object System.Text.UTF8Encoding($false)))
$arguments = @('-C', ('fpsTarget=' + [Math]::Round(60 * $Velocidade)), '--script', ('"' + $boot + '"'))
$checkpoint = Join-Path $data 'ultimo-estado.ss0'
if (Test-Path -LiteralPath $checkpoint) { $arguments += @('-t', ('"' + $checkpoint + '"')) }
$arguments += ('"' + $game + '"')
$process = Start-Process -FilePath (Join-Path $destination 'mGBA.exe') -ArgumentList $arguments -WorkingDirectory $destination -PassThru
# Faixa de avisos sobre a janela do jogo (fecha sozinha junto com o mGBA)
$notice = Join-Path $data 'aviso.txt'
Set-Content -LiteralPath $notice -Value '' -NoNewline -Encoding utf8
$overlay = Join-Path $PSScriptRoot 'tools\aviso-overlay.ps1'
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $overlay + '"'),'-ProcessId',$process.Id,'-File',('"' + $notice + '"')) | Out-Null
$papel = @{ en = @{ host = 'Host'; guest = 'Partner' }; pt = @{ host = 'Anfitrião'; guest = 'Parceiro' }; es = @{ host = 'Anfitrión'; guest = 'Compañero' } }[$Idioma][$Role]
$frase = @{ en = "$papel started (speed ${Velocidade}x). Private save: $privateSave"
  pt = "$papel iniciado (velocidade ${Velocidade}x). Save particular: $privateSave"
  es = "$papel iniciado (velocidad ${Velocidade}x). Partida privada: $privateSave" }[$Idioma]
Write-Output $frase
