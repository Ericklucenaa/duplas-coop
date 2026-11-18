# Publica uma versão nova do Duplas: testes, Duplas.exe, zip da release, commit, tag e release no GitHub.
# Quem já tem o Duplas recebe a pergunta "Deseja atualizar?" na próxima vez que abrir o app.
#
# Uso:  powershell -ExecutionPolicy Bypass -File publicar.ps1 -Versao 0.1.1 -Notas "O que mudou nesta versão"
#       Versões 0.x.y saem como beta (pré-lançamento no GitHub); a partir de 1.0.0, como versão estável.
#       -SoMontar   monta o zip em release\ sem publicar nada (para conferir antes)
# Precisa: gh (logado), Python com pyinstaller, pywebview e lupa, e o mGBA de desenvolvimento em tools\mgba-dev.
param(
  [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Versao,
  [string]$Notas = '',
  [switch]$SoMontar
)
$ErrorActionPreference = 'Stop'
$raiz = $PSScriptRoot
Set-Location $raiz

$emulador = Get-ChildItem -LiteralPath (Join-Path $raiz 'tools\mgba-dev') -Directory -ErrorAction SilentlyContinue |
  Where-Object { Test-Path (Join-Path $_.FullName 'mGBA.exe') } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $emulador) { throw 'Coloque o mGBA de desenvolvimento (a pasta com o mGBA.exe) em tools\mgba-dev' }
$anterior = (Get-Content -LiteralPath (Join-Path $raiz 'versao.json') -Raw | ConvertFrom-Json).versao
if (-not $SoMontar) {
  # tag sem release = publicação anterior que falhou no fim: dá para rodar de novo com o mesmo número
  if (git tag -l "v$Versao") { gh release view "v$Versao" *> $null; if ($LASTEXITCODE -eq 0) { throw "A versão $Versao já foi publicada. Use um número maior." } }
  if ([version]$Versao -lt [version]$anterior) { throw "A versão $Versao é menor que a atual ($anterior)." }
}
if (-not $SoMontar -and (git status --porcelain)) { throw 'Há alterações sem commit. Faça o commit antes de publicar.' }

Write-Output '1/5 testes'
python -m pytest tests/unit -q -p no:cacheprovider
if ($LASTEXITCODE -ne 0) { throw 'Os testes falharam: nada foi publicado.' }

[IO.File]::WriteAllText((Join-Path $raiz 'versao.json'), "{`n `"versao`": `"$Versao`"`n}`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Output '2/5 Duplas.exe'
$saida = Join-Path $raiz 'release'
Remove-Item -LiteralPath $saida -Recurse -Force -ErrorAction SilentlyContinue
python -m PyInstaller (Join-Path $raiz 'build-app\Duplas.spec') --noconfirm --distpath (Join-Path $saida 'exe') --workpath (Join-Path $saida 'build') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'O PyInstaller falhou.' }

Write-Output '3/5 pasta da release'
$pasta = Join-Path $saida "Duplas-$Versao"
New-Item -ItemType Directory -Force -Path $pasta | Out-Null
Copy-Item -LiteralPath (Join-Path $saida 'exe\Duplas.exe') -Destination $pasta
foreach ($item in 'src', 'vendor') { Copy-Item -LiteralPath (Join-Path $raiz $item) -Destination $pasta -Recurse }
robocopy (Join-Path $raiz 'ferramenta') (Join-Path $pasta 'ferramenta') /E /XD trabalho __pycache__ /NFL /NDL /NJH /NJS | Out-Null
robocopy (Join-Path $raiz 'tests\two_instance') (Join-Path $pasta 'tests\two_instance') /E /XD __pycache__ /NFL /NDL /NJH /NJS | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $pasta 'tools\mgba-dev') | Out-Null
Copy-Item -LiteralPath (Join-Path $raiz 'tools\aviso-overlay.ps1') -Destination (Join-Path $pasta 'tools')
# nome curto (mGBA-<build>): dentro de um pacote o caminho completo não pode passar de 260 caracteres no Windows
$curto = if ($emulador.Name -match 'win64-(\d+)-') { "mGBA-$($Matches[1])" } else { 'mGBA' }
robocopy $emulador.FullName (Join-Path $pasta "tools\mgba-dev\$curto") /E /XF mgba-sdl.exe nointro.dat /NFL /NDL /NJH /NJS | Out-Null
foreach ($f in 'iniciar-demo.ps1', 'testar-duas-instancias.ps1', 'versao.json', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md') {
  Copy-Item -LiteralPath (Join-Path $raiz $f) -Destination $pasta
}
$proibidos = Get-ChildItem -LiteralPath $pasta -Recurse -File | Where-Object { $_.Extension -match '^\.(gba|sav|ss\d|sgm)$' }
if ($proibidos) { throw "A release não pode levar jogos ou saves: $($proibidos.FullName -join ', ')" }

Write-Output '4/5 zip'
$zip = Join-Path $saida "Duplas-$Versao.zip"
# zip com barras normais nos caminhos (o Compress-Archive do PowerShell 5.1 pode gravar barras invertidas)
python -c "import sys,zipfile,pathlib; p=pathlib.Path(sys.argv[1]); z=zipfile.ZipFile(sys.argv[2],'w',zipfile.ZIP_DEFLATED,compresslevel=9); [z.write(f,f.relative_to(p).as_posix()) for f in sorted(p.rglob('*')) if f.is_file()]; z.close()" $pasta $zip
if ($LASTEXITCODE -ne 0) { throw 'Não deu para montar o zip.' }
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zip.sha256", "$hash  Duplas-$Versao.zip`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("   {0} ({1:N1} MB)" -f $zip, ((Get-Item $zip).Length / 1MB))
if ($SoMontar) {
  [IO.File]::WriteAllText((Join-Path $raiz 'versao.json'), "{`n `"versao`": `"$anterior`"`n}`n", (New-Object System.Text.UTF8Encoding($false)))
  Write-Output 'Montado (nada publicado).'
  return
}

Write-Output '5/5 GitHub'
if (git status --porcelain versao.json) {   # na primeira publicação a versão já está no arquivo
  git add versao.json
  git commit -m "Versão $Versao" | Out-Null
}
if (-not (git tag -l "v$Versao")) { git tag "v$Versao" }
git push origin HEAD --tags
if ($LASTEXITCODE -ne 0) { throw 'Não deu para enviar ao GitHub (git push).' }
if (-not $Notas) { $Notas = "Duplas $Versao" }
# as notas vão por arquivo: o PowerShell 5.1 repassa mal ao gh um texto de várias linhas que começam com "-"
$arquivoNotas = Join-Path $saida 'notas.md'
[IO.File]::WriteAllText($arquivoNotas, $Notas, (New-Object System.Text.UTF8Encoding($false)))
# enquanto a versão começar com 0 (0.x.y) o projeto está em beta: a release sai marcada como pré-lançamento
$argumentos = @('release', 'create', "v$Versao", $zip, "$zip.sha256", '--notes-file', $arquivoNotas)
if ($Versao.StartsWith('0.')) { $argumentos += @('--title', "Duplas $Versao (beta)", '--prerelease') }
else { $argumentos += @('--title', "Duplas $Versao") }
& gh @argumentos
if ($LASTEXITCODE -ne 0) { throw "O GitHub recusou a release (gh saiu com $LASTEXITCODE). A tag v$Versao já foi enviada: rode de novo depois de corrigir." }
Write-Output "Publicado: Duplas $Versao"
