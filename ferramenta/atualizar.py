"""Atualização automática pelas releases do GitHub e volta para a versão anterior.

Uma release publica Duplas-<versão>.zip (a pasta do app inteira) e Duplas-<versão>.zip.sha256.
Atualizar: baixa, confere o SHA-256, guarda a versão em uso em versoes/<versão> e põe a nova no lugar.
Voltar: troca a versão em uso pela guardada. Nos dois casos os dados de quem usa ficam onde estão: pacotes/ (jogos, saves
e progresso), ferramenta/trabalho/ (ROMs analisadas), tests/artifacts/ e preferencias.json. Os pacotes passam a usar os
scripts da versão que ficou (pacote.atualizar_scripts).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sys
import threading
import time
import urllib.request
import zipfile
from pathlib import Path

import pacote as Pk

ROOT = Pk.ROOT
REPO = 'Ericklucenaa/duplas-coop'
API = os.environ.get('DUPLAS_API', 'https://api.github.com')   # trocado só nos testes
PREFS = ROOT / 'preferencias.json'
VERSOES = ROOT / 'versoes'
TEMP = ROOT / '.atualizacao'
GUARDAR = 2   # versões anteriores guardadas
# o que é do app (troca a cada versão); o resto da pasta é de quem usa
DO_APP = ['Duplas.exe', 'ferramenta', 'src', 'tests', 'tools', 'vendor', 'iniciar-demo.ps1', 'testar-duas-instancias.ps1',
          'Abrir Duplas (Python).bat', 'versao.json', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md']
# dados de quem usa que moram dentro de pastas do app
DADOS_DENTRO = ['ferramenta/trabalho', 'tests/artifacts']
L = Pk.L


def versao_atual(raiz: Path = ROOT) -> str:
    try:
        return json.loads((raiz / 'versao.json').read_text(encoding='utf-8'))['versao']
    except (OSError, ValueError, KeyError):
        return '0.0.0'   # cópia de desenvolvimento (sem versao.json)


def _numeros(versao: str) -> tuple:
    """(maior, menor, correção): "0.1" vale o mesmo que "0.1.0", e "0.1.1" é mais nova que os dois."""
    numeros = [int(n) for n in re.findall(r'\d+', versao)[:3]]
    return tuple(numeros + [0] * (3 - len(numeros)))


def mais_nova(a: str, b: str) -> bool:
    return _numeros(a) > _numeros(b)


def ler_prefs() -> dict:
    try:
        return json.loads(PREFS.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def gravar_prefs(**valores) -> dict:
    prefs = ler_prefs()
    prefs.update(valores)
    PREFS.write_text(json.dumps(prefs, ensure_ascii=False, indent=1), encoding='utf-8')
    return prefs


def _pedir(url: str, timeout: int = 15):
    req = urllib.request.Request(url, headers={'User-Agent': 'Duplas-updater', 'Accept': 'application/vnd.github+json'})
    return urllib.request.urlopen(req, timeout=timeout)


def verificar() -> dict:
    """Situação para a tela: versão em uso, a mais nova publicada e se dá para voltar."""
    atual = versao_atual()
    out = {'atual': atual, 'anterior': versao_anterior(), 'nova': None, 'notas': '', 'tem_atualizacao': False,
           'ignorada': False, 'erro': None}
    try:
        # a lista inteira, não /releases/latest: esse ignora as versões beta (pré-lançamento) e quem está na beta
        # nunca receberia atualização
        with _pedir(f'{API}/repos/{REPO}/releases?per_page=30') as r:
            todas = [x for x in json.loads(r.read().decode('utf-8')) if not x.get('draft')]
    except Exception as e:   # sem internet, GitHub fora do ar: o app segue normal
        out['erro'] = str(e)[:200]
        return out
    if not todas:
        return out
    rel = max(todas, key=lambda x: _numeros(str(x.get('tag_name', ''))))
    nova = str(rel.get('tag_name', '')).lstrip('vV')
    zipe = next((a for a in rel.get('assets', []) if a.get('name', '').endswith('.zip')), None)
    soma = next((a for a in rel.get('assets', []) if a.get('name', '').endswith('.zip.sha256')), None)
    out.update(nova=nova, notas=rel.get('body') or '', pagina=rel.get('html_url', ''))
    if zipe and mais_nova(nova, atual):
        out['tem_atualizacao'] = True
        out['ignorada'] = ler_prefs().get('ignorar_versao') == nova
        _release['zip'] = zipe['browser_download_url']
        _release['sha256'] = soma['browser_download_url'] if soma else None
        _release['versao'] = nova
        _release['tamanho'] = zipe.get('size') or 0
    return out


_release: dict = {}
estado = {'fase': 'parado', 'progresso': 0, 'erro': None, 'versao': None}   # para a tela acompanhar
_trava = threading.Lock()


def _ocupado() -> dict | None:
    if any(t.get('rodando') for t in Pk._testes.values()):
        return L('A compatibility test is running. Wait for it to finish and try again.',
                 'Um teste de compatibilidade está rodando. Espere terminar e tente de novo.',
                 'Hay una prueba de compatibilidad en curso. Espera a que termine e inténtalo de nuevo.')
    return None


def _mover(origem: Path, destino: Path) -> None:
    destino.parent.mkdir(parents=True, exist_ok=True)
    os.replace(origem, destino) if origem.is_file() else origem.rename(destino)


def _trocar(nova: Path, guardar_em: Path) -> None:
    """Põe a pasta `nova` no lugar do app em uso, guardando o app em uso em `guardar_em`. Tudo ou nada."""
    if guardar_em.exists():
        shutil.rmtree(guardar_em)
    guardar_em.mkdir(parents=True)
    feitos = []          # (de, para) já movidos, para desfazer
    dados = TEMP / 'dados'
    shutil.rmtree(dados, ignore_errors=True)
    try:
        for rel in DADOS_DENTRO:                       # dados de quem usa saem do caminho
            if (ROOT / rel).exists():
                _mover(ROOT / rel, dados / rel)
                feitos.append((ROOT / rel, dados / rel))
        for nome in DO_APP:                            # app em uso vai para guardar_em
            if (ROOT / nome).exists():
                _mover(ROOT / nome, guardar_em / nome)
                feitos.append((ROOT / nome, guardar_em / nome))
        for nome in DO_APP:                            # app novo entra
            if (nova / nome).exists():
                _mover(nova / nome, ROOT / nome)
                feitos.append((nova / nome, ROOT / nome))
        for rel in DADOS_DENTRO:                       # dados de volta, dentro do app novo
            if (dados / rel).exists():
                _mover(dados / rel, ROOT / rel)
                feitos.append((dados / rel, ROOT / rel))
    except OSError:
        for de, para in reversed(feitos):
            try:
                _mover(para, de)
            except OSError:
                pass
        raise


def _limpar_guardadas() -> None:
    if not VERSOES.exists():
        return
    guardadas = sorted((p for p in VERSOES.iterdir() if p.is_dir()), key=lambda p: p.stat().st_mtime, reverse=True)
    for velha in guardadas[GUARDAR:]:
        shutil.rmtree(velha, ignore_errors=True)


def versao_anterior() -> str | None:
    """A versão guardada mais recente (a que estava antes desta)."""
    if not VERSOES.exists():
        return None
    guardadas = sorted((p for p in VERSOES.iterdir() if (p / 'versao.json').exists()), key=lambda p: p.stat().st_mtime,
                       reverse=True)
    atual = versao_atual()
    for p in guardadas:
        if mais_nova(atual, versao_atual(p)):   # só versões mais antigas (a deixada ao voltar fica guardada, mas não conta)
            return versao_atual(p)
    return None


def _baixar(url: str, destino: Path, total: int) -> None:
    feito = 0
    with _pedir(url, timeout=60) as r, open(destino, 'wb') as f:
        while True:
            bloco = r.read(256 * 1024)
            if not bloco:
                break
            f.write(bloco)
            feito += len(bloco)
            estado['progresso'] = int(feito * 100 / total) if total else 0


def _atualizar() -> None:
    versao = _release['versao']
    try:
        estado.update(fase='baixando', progresso=0, erro=None, versao=versao)
        shutil.rmtree(TEMP, ignore_errors=True)
        TEMP.mkdir(parents=True)
        arquivo = TEMP / f'Duplas-{versao}.zip'
        _baixar(_release['zip'], arquivo, _release.get('tamanho', 0))
        estado['fase'] = 'conferindo'
        if _release.get('sha256'):
            with _pedir(_release['sha256']) as r:
                esperado = r.read().decode('utf-8').split()[0].strip().lower()
            if hashlib.sha256(arquivo.read_bytes()).hexdigest() != esperado:
                raise RuntimeError('sha256')
        nova = TEMP / 'nova'
        with zipfile.ZipFile(arquivo) as z:
            for nome in z.namelist():   # nada fora da pasta (zip malicioso)
                if nome.startswith(('/', '\\')) or '..' in Path(nome).parts:
                    raise RuntimeError('zip')
            z.extractall(nova)
        if versao_atual(nova) != versao or not (nova / 'ferramenta').exists():
            raise RuntimeError('conteudo')
        estado['fase'] = 'instalando'
        _trocar(nova, VERSOES / versao_atual())
        _limpar_guardadas()
        Pk.atualizar_scripts()
        gravar_prefs(ignorar_versao=None)
        shutil.rmtree(TEMP, ignore_errors=True)
        estado.update(fase='pronto', progresso=100)
    except Exception as e:
        estado.update(fase='erro', erro=_explicar(e))
        shutil.rmtree(TEMP, ignore_errors=True)


def _explicar(e: Exception) -> dict:
    if isinstance(e, OSError):
        return L('Could not replace the app files. Close the games opened by Duplas and try again.',
                 'Não deu para trocar os arquivos do app. Feche os jogos abertos pelo Duplas e tente de novo.',
                 'No se pudieron reemplazar los archivos de la app. Cierra los juegos abiertos por Duplas e inténtalo de nuevo.')
    if str(e) in ('sha256', 'zip', 'conteudo'):
        return L('The downloaded file is damaged. Nothing was changed; try again later.',
                 'O arquivo baixado veio com defeito. Nada foi alterado; tente de novo mais tarde.',
                 'El archivo descargado está dañado. No se cambió nada; inténtalo más tarde.')
    return L(f'Could not download the update ({e}). Nothing was changed.',
             f'Não deu para baixar a atualização ({e}). Nada foi alterado.',
             f'No se pudo descargar la actualización ({e}). No se cambió nada.')


def iniciar_atualizacao() -> dict:
    with _trava:
        if estado['fase'] in ('baixando', 'conferindo', 'instalando'):
            return estado
        motivo = _ocupado()
        if motivo:
            raise Pk.Erro(motivo)
        if not _release.get('zip'):
            verificar()
        if not _release.get('zip'):
            raise Pk.Erro(L('No update available.', 'Nenhuma atualização disponível.', 'No hay actualizaciones disponibles.'))
        estado.update(fase='baixando', progresso=0, erro=None)
        threading.Thread(target=_atualizar, daemon=True).start()
        return estado


def voltar() -> dict:
    """Troca a versão em uso pela anterior guardada e marca a versão deixada para não perguntar de novo."""
    with _trava:
        motivo = _ocupado()
        if motivo:
            raise Pk.Erro(motivo)
        anterior = versao_anterior()
        if not anterior:
            raise Pk.Erro(L('There is no previous version saved on this PC.', 'Não há versão anterior guardada neste PC.',
                            'No hay una versión anterior guardada en este PC.'))
        deixada = versao_atual()
        origem = max((p for p in VERSOES.iterdir() if versao_atual(p) == anterior), key=lambda p: p.stat().st_mtime)
        provisoria = TEMP / 'voltar'
        shutil.rmtree(provisoria, ignore_errors=True)
        _mover(origem, provisoria)
        try:
            _trocar(provisoria, VERSOES / deixada)
        except OSError as e:
            _mover(provisoria, origem)
            raise Pk.Erro(_explicar(e))
        shutil.rmtree(TEMP, ignore_errors=True)
        Pk.atualizar_scripts()
        gravar_prefs(ignorar_versao=deixada)
        estado.update(fase='pronto', progresso=100, erro=None, versao=anterior)
        return {'versao': anterior, 'deixada': deixada}


def reiniciar() -> bool:
    """Abre o app de novo (já na versão nova) e fecha este. Só no Duplas.exe; rodando pelo Python, avisa na tela."""
    exe = ROOT / 'Duplas.exe'
    if not getattr(sys, 'frozen', False) or not exe.exists():
        return False

    def depois():
        time.sleep(0.8)   # a resposta da requisição sai antes
        import subprocess
        # O Duplas.exe (PyInstaller) roda dentro de um "job" do Windows: um processo aberto daqui nasceria no mesmo job e
        # seria encerrado junto com este (no 2º reinício seguido o app novo morria ou ficava sem resposta). Quem cria o
        # app novo é o serviço WMI do Windows: ele nasce independente, como se a pessoa tivesse aberto o Duplas.exe.
        def aspas(texto):
            return str(texto).replace("'", "''")
        criar = (f"$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments "
                 f"@{{CommandLine='\"{aspas(exe)}\"'; CurrentDirectory='{aspas(ROOT)}'}}; exit $r.ReturnValue")
        try:
            r = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command', criar], timeout=30,
                               creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            if r.returncode != 0:
                raise OSError(r.returncode)
        except (OSError, subprocess.SubprocessError):
            fora_do_job = 0x01000000 | 0x00000008 | 0x00000200   # BREAKAWAY_FROM_JOB | DETACHED_PROCESS | NEW_PROCESS_GROUP
            subprocess.Popen([str(exe)], cwd=str(ROOT), creationflags=fora_do_job, close_fds=True)
        os._exit(0)
    threading.Thread(target=depois, daemon=True).start()
    return True
