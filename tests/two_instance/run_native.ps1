param([int]$Seconds=100,[string]$Out=(Join-Path $PSScriptRoot '..\artifacts\native'),
  [ValidateSet('wild','capture','trainer','gym','reconnect','switch','reserve','items','single','solo','busy','reinforce','race','controls')][string]$Scenario='wild',
  [switch]$FixtureTeams,[switch]$SeparateMaps,[int]$Port=0,
  # A ROM, o save de partida (opcional com -State) e o perfil de endereços gerado pela ferramenta
  [string]$Rom='',[string]$Save='',[string]$Profile='',
  # estado do emulador já no mapa (jogo novo criado por novo_jogo.ps1); com ele o save é opcional
  [string]$State='',
  # janelas visíveis (desenho por OpenGL como no uso real) e velocidade como a do jogador (0 = sem limite)
  [switch]$Visible,[int]$Fps=240,
  # convidado sem nenhum Pokémon (jogo novo), anfitrião com o time de teste
  [switch]$GuestEmpty,
  # quadros parados no menu da batalha antes de o piloto automático agir
  [int]$Idle=0,
  # vaga do emulador: '' usa runtime\host e runtime\guest; '-2', '-3'... dão pastas próprias a testes em paralelo
  [string]$Slot='')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$Out=[IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force -Path $Out | Out-Null
if($Port -eq 0) { $Port=Get-Random -Minimum 20000 -Maximum 39000 }
if(-not $Rom) { throw 'Informe a ROM: -Rom <arquivo .gba>' }
if(-not $Save) { $Save=[IO.Path]::ChangeExtension($Rom,'.sav') }
$Rom=[IO.Path]::GetFullPath($Rom);$Save=[IO.Path]::GetFullPath($Save)
if(-not (Test-Path -LiteralPath $Rom)) { throw "ROM ausente: $Rom" }
if(-not $State -and -not (Test-Path -LiteralPath $Save)) { throw "Save ausente: $Save (o teste precisa de um save já no mapa, com Pokémon)" }
if($State) { $State=[IO.Path]::GetFullPath($State) }
$emulator=Get-ChildItem -LiteralPath (Join-Path $root 'tools\mgba-dev') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'mGBA.exe') } |
  Sort-Object Name -Descending | Select-Object -First 1
# Vigia: às vezes um mGBA trava logo ao abrir (a interface para de responder e o jogo para junto, antes de qualquer
# script do modo Duplas rodar). O registro de cada lado é escrito pelo menos a cada 600 quadros; se um deles ficar
# 20 s sem mudar com o processo aberto, a tentativa é descartada e o cenário recomeça do zero (até 3 tentativas).
# Uma falha do modo Duplas não é mascarada: nela os dois emuladores seguem rodando e escrevendo.
$tentativas=3
for($tentativa=1;$tentativa -le $tentativas;$tentativa++) {
  $processes=@();$travou=$null
  try {
    foreach($role in @('host','guest')) {
      # Pasta fixa do emulador: o Firewall do Windows guarda a permissão pelo caminho do executável.
      $folder=Join-Path $root "tests\artifacts\runtime\$role$Slot"
      New-Item -ItemType Directory -Force -Path $folder | Out-Null
      $exe=Join-Path $folder 'mGBA.exe'
      if(-not (Test-Path -LiteralPath $exe)) { New-Item -ItemType HardLink -Path $exe -Target (Join-Path $emulator.FullName 'mGBA.exe') | Out-Null }
      # a ROM da vez (troca quando é outra) e uma cópia nova do save a cada rodada
      $game=Join-Path $folder 'jogo.gba'
      $src=Get-Item -LiteralPath $Rom
      if(-not (Test-Path -LiteralPath $game) -or (Get-Item -LiteralPath $game).Length -ne $src.Length -or
         (Get-FileHash -LiteralPath $game -Algorithm MD5).Hash -ne (Get-FileHash -LiteralPath $Rom -Algorithm MD5).Hash) {
        Remove-Item -LiteralPath $game -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $Rom -Destination $game
      }
      $privateSave=Join-Path $folder 'jogo.sav'
      if(Test-Path -LiteralPath $Save) { Copy-Item -LiteralPath $Save -Destination $privateSave -Force }
      else { Remove-Item -LiteralPath $privateSave -Force -ErrorAction SilentlyContinue }
      Copy-Item -LiteralPath (Join-Path $root 'vendor\gba-pk\GBA-PK_Multiplayer.lua') -Destination (Join-Path $folder 'GBA-PK_Multiplayer.lua') -Force
      New-Item -ItemType File -Force -Path (Join-Path $folder 'portable.ini') | Out-Null
      @('ip=127.0.0.1',"port=$Port",'mode=Coop',$(if($role -eq 'host'){'friendcode=PHX1';'partner=PHX2'}else{'friendcode=PHX2';'partner=PHX1'})) |
        Set-Content -LiteralPath (Join-Path $folder 'GBA-PK_Multiplayer.ini') -Encoding ascii
      $data=Join-Path $Out "$role-dados"
      New-Item -ItemType Directory -Force -Path $data | Out-Null
      $entry=Join-Path $Out "$role.lua"
      $script=Join-Path $PSScriptRoot 'native_autoplay.lua'
      $vendor=Join-Path $folder 'GBA-PK_Multiplayer.lua'
      $body=@(
        "COOP_ROLE='$role'",
        "COOP_SCENARIO='$Scenario'",
        "DP_NATIVE_PORT=$($Port+1)",
        "DP_BIND_ADDR='127.0.0.1'",
        "DP_NATIVE_BIND='127.0.0.1'",
        "DP_DEBUG_NET=true",
        $(if($Profile){ "DP_PROFILE=[[$(([IO.Path]::GetFullPath($Profile)).Replace('\','/'))]]" } else { '-- perfil padrão (FireRed 1.0)' }),
        "COOP_FIXTURE_TEAMS=$($FixtureTeams.IsPresent.ToString().ToLowerInvariant())",
        "COOP_GUEST_EMPTY=$($GuestEmpty.IsPresent.ToString().ToLowerInvariant())",
        $(if($Idle){ "COOP_IDLE=$Idle" } else { "-- sem pausa no menu" }),
        "COOP_SEPARATE_MAPS=$($SeparateMaps.IsPresent.ToString().ToLowerInvariant())",
        "COOP_OUT=[[$($Out.Replace('\','/'))]]",
        "COOP_DATA=[[$($data.Replace('\','/'))]]",
        "COOP_GBAPK=[[$($vendor.Replace('\','/'))]]",
        "dofile([[$($script.Replace('\','/'))]])"
      )
      [IO.File]::WriteAllLines($entry,[string[]]$body,(New-Object System.Text.UTF8Encoding($false)))
      # visível: só a velocidade, com a sincronização padrão do mGBA, como nos atalhos dos pacotes
      $arguments=if($Visible){ @('-C',"fpsTarget=$Fps",'--script',('"'+$entry+'"')) }
        else { @('-C',"fpsTarget=$Fps",'-C','audioSync=0','-C','videoSync=0','--script',('"'+$entry+'"')) }
      if($State) { $arguments+=@('-t',('"'+$State+'"')) }
      $arguments+=('"'+(Join-Path $folder 'jogo.gba')+'"')
      # minimizada, nunca escondida: com a janela escondida (Hidden) a interface do mGBA às vezes congela de vez e leva o
      # emulador junto (medido: 3 de 16 travaram com quatro testes em paralelo; minimizadas, nenhuma de 24)
      $p=Start-Process -FilePath (Join-Path $folder 'mGBA.exe') -ArgumentList $arguments -WorkingDirectory $folder -WindowStyle $(if($Visible){'Normal'}else{'Minimized'}) -PassThru
      $processes+=$p
      if($role -eq 'host') { Start-Sleep -Seconds 2 }
    }
    $inicio=Get-Date
    while(((Get-Date)-$inicio).TotalSeconds -lt $Seconds) {
      Start-Sleep -Seconds 2
      if(($processes | Where-Object { $_.HasExited }).Count -gt 0) { break }
      if(((Get-Date)-$inicio).TotalSeconds -lt 15) { continue }
      foreach($role in @('host','guest')) {
        $log=Join-Path $Out "$role.log"
        $parado=if(Test-Path -LiteralPath $log){ ((Get-Date)-(Get-Item -LiteralPath $log).LastWriteTime).TotalSeconds } else { 999 }
        if($parado -ge 20) { $travou=$role }
      }
      if($travou) { break }
    }
  } finally {
    foreach($process in $processes) { if(-not $process.HasExited) { Stop-Process -Id $process.Id -Force } }
  }
  if(-not $travou -or $tentativa -eq $tentativas) { break }
  Start-Sleep -Seconds 1
  $nota="tentativa $tentativa descartada: o mGBA do $travou travou (registro parado), recomeçando"
  Get-ChildItem -LiteralPath $Out -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  Add-Content -LiteralPath (Join-Path (Split-Path $Out) 'reinicios.log') -Value "$(Split-Path $Out -Leaf): $nota" -Encoding utf8
  Write-Output $nota
  $Port=Get-Random -Minimum 20000 -Maximum 39000
}
foreach($role in @('host','guest')) {
  $log=Join-Path $Out "$role.log"
  if(Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 16 }
  else { Write-Output "$role : nenhum log produzido" }
}
