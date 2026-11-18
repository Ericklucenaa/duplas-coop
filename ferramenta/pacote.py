"""Monta o pacote pronto para jogar a partir de uma ROM analisada e roda o teste de compatibilidade.

pacotes/<nome>/
  atalhos .bat e o LEIA-ME no idioma do app (inglês, português ou espanhol) · velocidade.txt · idioma.txt
  jogo/<nome>.gba  (cópia; a ROM enviada nunca é alterada)   jogo/<nome>.sav (se houver)
  coop/            scripts do modo Duplas, perfil.lua desta ROM, pacote.json, GBA-PK e o mGBA de desenvolvimento

Todo texto que vai para a tela sai nos três idiomas ({'en','pt','es'}): a interface mostra o do idioma escolhido.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path(os.environ.get('DUPLAS_RAIZ') or Path(__file__).resolve().parents[1])
PACOTES = ROOT / 'pacotes'
IDIOMAS = ('en', 'pt', 'es')
IDIOMA_PADRAO = 'en'


def L(en: str, pt: str, es: str) -> dict:
    """Texto para a tela nos três idiomas."""
    return {'en': en, 'pt': pt, 'es': es}


class Erro(ValueError):
    """Erro mostrado ao usuário, nos três idiomas."""

    def __init__(self, textos: dict):
        super().__init__(textos['en'])
        self.textos = textos


def idioma_valido(idioma: str | None) -> str:
    return idioma if idioma in IDIOMAS else IDIOMA_PADRAO


# o que cada recurso precisa do perfil (para o relatório de compatibilidade)
RECURSOS = [
    ('rede', L('Network and partner on the map', 'Rede e parceiro no mapa', 'Red y compañero en el mapa'), []),
    ('campanha', L("The pair's bag, money, story and Pokédex", 'Bolsa, dinheiro, história e Pokédex da dupla',
                   'Mochila, dinero, historia y Pokédex de la pareja'),
     ['saveBlock1Ptr', 'saveBlock2Ptr', 'itemsTable']),
    ('batalha', L('Double battle (two wild Pokémon, both players, each with their own Pokémon)',
                  'Batalha em dupla (dois selvagens, os dois jogadores, cada um com o próprio Pokémon)',
                  'Combate doble (dos salvajes, los dos jugadores, cada uno con su propio Pokémon)'), [
        'readKeysR1', 'cb2InitBattle', 'cb2Overworld', 'cb2EndWildBattle', 'encounterKindHook', 'fishingHook',
        'battleReplenish', 'battleEnemyCount', 'battleSkipRoutine', 'partyOtCheck', 'partyMenuHook', 'ctrlRunCommand',
        'ctrlActionInput', 'ctrlTargetInput', 'ctrlMoveInput', 'battleCloseParty', 'textController', 'controllersTable',
        'commandsTable', 'wildHeaders', 'gMain', 'rngValue', 'controllerFuncs', 'party', 'partyCount', 'enemyParty',
        'enemyPartyCount', 'battleTypeFlags', 'battleBufferA', 'battleBufferB', 'activeBattler', 'battlerPartyIndexes',
        'battleMons', 'attacker', 'target', 'absentFlags', 'battlescriptPtr', 'battleOutcome', 'storagePtr', 'cave']),
    ('reservas', L('Last unit of an item contested by both', 'Última unidade de item disputada pelos dois',
                   'Última unidad de un objeto disputada por los dos'), ['itemEffect', 'removeBagItem', 'itemsTable', 'cave']),
]
GBAPK_BASES = ('AXV', 'AXP', 'BPE', 'BPG', 'BPR')   # Ruby, Sapphire, Emerald, LeafGreen, FireRed (todas as línguas)
FAMILIAS_PRONTAS = {'FRLG', 'E', 'RS'}              # FireRed/LeafGreen, Emerald, Ruby/Sapphire
# Ruby/Sapphire guardam o save em endereço fixo (sem ponteiro)
TROCA_RS = {'saveBlock1Ptr': 'saveBlock1', 'saveBlock2Ptr': 'saveBlock2', 'storagePtr': 'storage'}

# cenários do teste de compatibilidade (não dependem de um jogo específico)
SUITE = [
    ('wild', 'wild', 160, [], L('Double wild encounter', 'Encontro selvagem em dupla', 'Encuentro salvaje doble')),
    ('controls', 'controls', 200, ['-FixtureTeams'], L('Each player commands their own Pokémon',
                                                       'Cada jogador comanda o próprio Pokémon', 'Cada jugador controla su propio Pokémon')),
    ('capture', 'capture', 180, ['-FixtureTeams'], L('A capture for each player, never duplicated',
                                                     'Captura para cada um, sem duplicar', 'Una captura para cada uno, sin duplicar')),
    ('trainer', 'trainer', 220, [], L('Trainer battle', 'Batalha contra treinador', 'Combate contra entrenador')),
    ('switch', 'switch', 240, ['-FixtureTeams'], L('Switching up to the 6th Pokémon in battle', 'Troca até o 6º Pokémon na batalha',
                                                   'Cambio hasta el 6.º Pokémon en combate')),
    ('items', 'items', 120, [], L('Shared bag in an item dispute', 'Bolsa compartilhada na disputa de itens',
                                  'Mochila compartida en la disputa de objetos')),
    ('race', 'race', 150, [], L('Last unit of a TM and a held item', 'Última unidade de TM e item segurado',
                                'Última unidad de una MT y objeto llevado')),
    ('single', 'single', 120, [], L('Single-player mode untouched', 'Modo individual intacto', 'Modo individual intacto')),
    ('solo', 'solo', 120, [], L('No partner: waiting and leaving with L+R+SELECT', 'Sem parceiro: espera e saída com L+R+SELECT',
                                'Sin compañero: espera y salida con L+R+SELECT')),
]
CENARIO_NOVO = L('Start a new game for the test', 'Começar um jogo novo para o teste', 'Empezar una partida nueva para la prueba')


def avaliar(analise: dict) -> list[dict]:
    """Recursos com estado ok / falta / sem_suporte, a partir do cabeçalho e do perfil resolvido."""
    cab, rel = analise['cabecalho'], analise['relatorio']
    familia = cab.get('familia')
    out = []
    for chave, titulo, nomes in RECURSOS:
        if chave == 'rede':
            ok = cab['codigo'][:3] in GBAPK_BASES
            out.append({'chave': chave, 'titulo': titulo, 'estado': 'ok' if ok else 'sem_suporte',
                        'detalhe': L('GBA-PK recognizes this game', 'GBA-PK reconhece este jogo', 'GBA-PK reconoce este juego') if ok
                        else L('not a 3rd-generation GBA game', 'jogo fora da 3ª geração de GBA', 'juego fuera de la 3.ª generación de GBA'),
                        'itens': []})
            continue
        if familia not in FAMILIAS_PRONTAS:
            out.append({'chave': chave, 'titulo': titulo, 'estado': 'sem_suporte',
                        'detalhe': L('this game does not have Duplas mode in this version of the tool',
                                     'este jogo ainda não tem o modo Duplas nesta versão da ferramenta',
                                     'este juego aún no tiene el modo Duplas en esta versión de la herramienta'), 'itens': []})
            continue
        if familia == 'RS':
            nomes = [TROCA_RS.get(n, n) for n in nomes]
        itens = [{'nome': n, 'valor': rel.get(n, {}).get('valor'), 'como': rel.get(n, {}).get('como', '')} for n in nomes]
        faltam = ', '.join(i['nome'] for i in itens if i['valor'] is None)
        out.append({'chave': chave, 'titulo': titulo, 'estado': 'ok' if not faltam else 'falta',
                    'detalhe': L('all points found', 'todos os pontos encontrados', 'todos los puntos encontrados') if not faltam
                    else L(f'not found: {faltam}', f'não encontrados: {faltam}', f'no encontrados: {faltam}'),
                    'itens': itens})
    return out


def pronto(recursos: list[dict]) -> bool:
    return all(r['estado'] == 'ok' for r in recursos)


def texto(valor, idioma: str) -> str:
    """Texto de um campo que pode vir nos três idiomas (ou só como texto, em resultados antigos)."""
    if isinstance(valor, dict):
        return valor.get(idioma) or valor.get(IDIOMA_PADRAO) or ''
    return str(valor or '')


# ------------------------------------------------------------------ arquivos do pacote no idioma do app
NOMES = {
    'en': {'host': 'Host game.bat', 'join': 'Join game.bat', 'local': 'Test on this PC.bat', 'leiame': 'README.txt'},
    'pt': {'host': 'Hospedar partida.bat', 'join': 'Entrar na partida.bat', 'local': 'Testar no mesmo PC.bat', 'leiame': 'LEIA-ME.txt'},
    'es': {'host': 'Crear partida.bat', 'join': 'Unirse a partida.bat', 'local': 'Probar en este PC.bat', 'leiame': 'LEEME.txt'},
}
BAT_TEXTOS = {
    'host': L('Opens the game as host. The first time, allow mGBA in the Windows Firewall prompt.',
              'Abre o jogo como anfitrião. Na primeira vez, permita o mGBA no aviso do Firewall do Windows.',
              'Abre el juego como anfitrión. La primera vez, permite mGBA en el aviso del Firewall de Windows.'),
    'join': L("Joins someone else's game (local network, Tailscale or ZeroTier).",
              'Entra na partida de outra pessoa (rede local, Tailscale ou ZeroTier).',
              'Entra en la partida de otra persona (red local, Tailscale o ZeroTier).'),
    'ip': L("Host's IP: ", 'IP de quem hospeda: ', 'IP del anfitrión: '),
    'local': L('Opens both windows on this PC, already paired, with copies of the save.',
               'Abre as duas janelas no mesmo PC, já pareadas, com cópias do save.',
               'Abre las dos ventanas en este PC, ya emparejadas, con copias de la partida.'),
}


def eh_pacote(pasta: Path) -> bool:
    """Pasta de pacote: tem coop/pacote.json (desde a versão com idiomas) ou o LEIA-ME de qualquer idioma."""
    if pasta.name.startswith('.') or not pasta.is_dir():
        return False
    return (pasta / 'coop' / 'pacote.json').exists() or any((pasta / n['leiame']).exists() for n in NOMES.values())


def ler_idioma(pacote: Path) -> str:
    try:
        return idioma_valido((pacote / 'idioma.txt').read_text(encoding='utf-8-sig').split()[0].lower())
    except (OSError, IndexError):
        return IDIOMA_PADRAO


def nome_bat_local(pacote: Path) -> Path:
    for idioma in (ler_idioma(pacote),) + IDIOMAS:
        caminho = pacote / NOMES[idioma]['local']
        if caminho.exists():
            return caminho
    raise Erro(L('This package has no "Test on this PC" shortcut.', 'Este pacote não tem o atalho "Testar no mesmo PC".',
                 'Este paquete no tiene el acceso "Probar en este PC".'))


VELOCIDADE_PADRAO = 3


def ler_velocidade(pacote: Path) -> int:
    """Velocidade do jogo gravada em velocidade.txt na pasta do pacote (o iniciar-demo.ps1 lê o mesmo arquivo)."""
    try:
        for linha in (pacote / 'velocidade.txt').read_text(encoding='utf-8-sig').splitlines():
            linha = linha.strip()
            if linha[:1].isdigit():
                return max(1, min(10, round(float(linha.split()[0].replace(',', '.')))))
    except (OSError, ValueError):
        pass
    return VELOCIDADE_PADRAO


VELOCIDADE_TEXTO = L(
    'Game speed: 1 = normal, 2 = twice as fast, 3 = three times... (1 to 10).\n'
    'Change the number on the first line and open the game again. When playing as a pair, both must use the same number.\n'
    "mGBA's fast-forward key (Tab) is off in Duplas mode: toggling speed with the partner connected can freeze both windows.",
    'Velocidade do jogo: 1 = normal, 2 = duas vezes, 3 = três vezes... (de 1 a 10).\n'
    'Troque o número da primeira linha e abra o jogo de novo. Jogando em dupla, os dois precisam usar o mesmo número.\n'
    'A tecla de acelerar do mGBA (Tab) fica desligada no modo Duplas: alternar a velocidade com o parceiro conectado pode '
    'travar as duas janelas.',
    'Velocidad del juego: 1 = normal, 2 = el doble, 3 = el triple... (de 1 a 10).\n'
    'Cambia el número de la primera línea y vuelve a abrir el juego. Jugando en pareja, los dos deben usar el mismo número.\n'
    'La tecla de acelerar de mGBA (Tab) está desactivada en el modo Duplas: cambiar la velocidad con el compañero conectado '
    'puede congelar las dos ventanas.')


def gravar_velocidade(pacote: Path, valor: int) -> int:
    valor = max(1, min(10, int(valor)))
    linhas = [str(valor), ''] + VELOCIDADE_TEXTO[ler_idioma(pacote)].split('\n')
    (pacote / 'velocidade.txt').write_text('\r\n'.join(linhas) + '\r\n', encoding='utf-8-sig', newline='')
    return valor


def nome_pasta(texto_nome: str) -> str:
    texto_nome = re.sub(r'[^\w\- ]+', '', texto_nome, flags=re.UNICODE).strip()
    return re.sub(r'\s+', ' ', texto_nome)[:48] or 'Game'


def _bat(caminho: Path, linhas: list[str]) -> None:
    caminho.write_bytes(('\r\n'.join(['@echo off', 'chcp 65001 >nul'] + linhas) + '\r\n').encode('utf-8'))


def _leiame(meta: dict, idioma: str, velocidade: int) -> list[str]:
    n, base, tem_save = NOMES[idioma], meta['base'], meta['tem_save']
    marca = {'ok': 'OK', 'falta': L('INCOMPLETE', 'INCOMPLETO', 'INCOMPLETO'), 'sem_suporte': L('UNSUPPORTED', 'SEM SUPORTE', 'SIN SOPORTE')}
    if idioma == 'pt':
        linhas = [f'Modo Duplas — {meta["nome"]}', '',
                  f'{n["host"]:<24} abre o jogo como anfitrião (permita o mGBA no Firewall na primeira vez).',
                  f'{n["join"]:<24} entra na partida de outra pessoa pelo IP dela.',
                  f'{n["local"]:<24} abre as duas janelas no mesmo computador.', '',
                  f'Coloque o seu save em jogo\\{base}.sav (mesmo nome do jogo). ' +
                  ('Este pacote já tem um.' if tem_save else 'Este pacote ainda não tem save: sem ele o jogo começa do zero.'),
                  f'Velocidade: o jogo abre {velocidade}x mais rápido. Para mudar, edite velocidade.txt (de 1 a 10) ou use o app '
                  'Duplas. Em dupla, os dois precisam usar a mesma velocidade.',
                  'O progresso de cada um fica em coop\\demo\\host ou coop\\demo\\guest.', '',
                  ('Na tela de título, escolha Continuar.' if tem_save else 'Na tela de título, comece um jogo novo.') +
                  ' Quando os dois estiverem no mapa, as janelas se conectam sozinhas.',
                  'Os avisos da batalha aparecem numa faixa sobre a janela do jogo e na aba Duplas de Ferramentas > Scripting.', '',
                  'Compatibilidade desta ROM:']
        rodape = 'GBA-PK-multiplayer: CC BY-NC 4.0 (uso não comercial), ver coop\\vendor\\gba-pk\\ATTRIBUTION.md'
    elif idioma == 'es':
        linhas = [f'Modo Duplas — {meta["nome"]}', '',
                  f'{n["host"]:<24} abre el juego como anfitrión (permite mGBA en el Firewall la primera vez).',
                  f'{n["join"]:<24} entra en la partida de otra persona con su IP.',
                  f'{n["local"]:<24} abre las dos ventanas en el mismo ordenador.', '',
                  f'Pon tu partida en jogo\\{base}.sav (mismo nombre que el juego). ' +
                  ('Este paquete ya tiene una.' if tem_save else 'Este paquete aún no tiene partida: sin ella el juego empieza de cero.'),
                  f'Velocidad: el juego abre {velocidad}x más rápido. Para cambiarla, edita velocidade.txt (de 1 a 10) o usa la '
                  'app Duplas. En pareja, los dos deben usar la misma velocidad.',
                  'El progreso de cada uno queda en coop\\demo\\host o coop\\demo\\guest.', '',
                  ('En la pantalla de título, elige Continuar.' if tem_save else 'En la pantalla de título, empieza una partida nueva.') +
                  ' Cuando los dos estén en el mapa, las ventanas se conectan solas.',
                  'Los avisos del combate aparecen en una franja sobre la ventana del juego y en la pestaña Duplas de '
                  'Herramientas > Scripting.', '',
                  'Compatibilidad de esta ROM:']
        rodape = 'GBA-PK-multiplayer: CC BY-NC 4.0 (uso no comercial), ver coop\\vendor\\gba-pk\\ATTRIBUTION.md'
    else:
        linhas = [f'Duplas mode — {meta["nome"]}', '',
                  f'{n["host"]:<24} opens the game as host (allow mGBA in the Firewall the first time).',
                  f"{n['join']:<24} joins someone else's game using their IP.",
                  f'{n["local"]:<24} opens both windows on the same computer.', '',
                  f'Put your save at jogo\\{base}.sav (same name as the game). ' +
                  ('This package already has one.' if tem_save else 'This package has no save yet: without one the game starts from scratch.'),
                  f'Speed: the game opens {velocidade}x faster. To change it, edit velocidade.txt (1 to 10) or use the Duplas '
                  'app. When playing as a pair, both must use the same speed.',
                  "Each player's progress is kept in coop\\demo\\host or coop\\demo\\guest.", '',
                  ('On the title screen, choose Continue.' if tem_save else 'On the title screen, start a new game.') +
                  ' When both players are on the map, the windows connect by themselves.',
                  'Battle notices appear on a strip over the game window and in the Duplas tab of Tools > Scripting.', '',
                  'Compatibility of this ROM:']
        rodape = 'GBA-PK-multiplayer: CC BY-NC 4.0 (non-commercial use), see coop\\vendor\\gba-pk\\ATTRIBUTION.md'
    for r in meta['recursos']:
        linhas.append(f'  [{texto(marca[r["estado"]], idioma)}] {texto(r["titulo"], idioma)} — {texto(r["detalhe"], idioma)}')
    return linhas + ['', rodape]


def escrever_textos(destino: Path, idioma: str) -> None:
    """Atalhos, LEIA-ME, velocidade.txt e idioma.txt no idioma escolhido (os dos outros idiomas saem)."""
    idioma = idioma_valido(idioma)
    meta = json.loads((destino / 'coop' / 'pacote.json').read_text(encoding='utf-8'))
    for outro, nomes in NOMES.items():
        if outro != idioma:
            for nome in nomes.values():
                (destino / nome).unlink(missing_ok=True)
    (destino / 'idioma.txt').write_text(idioma + '\r\n', encoding='utf-8')
    base, n = meta['base'], NOMES[idioma]
    args = f'-Rom "%~dp0jogo\\{base}.gba" -Save "%~dp0jogo\\{base}.sav" -Profile "%~dp0coop\\perfil.lua"'
    ps = 'powershell -NoProfile -ExecutionPolicy Bypass -File'
    _bat(destino / n['host'], [f'rem {BAT_TEXTOS["host"][idioma]}',
                               f'{ps} "%~dp0coop\\iniciar-demo.ps1" -Role host -AutoConnect {args}', 'pause'])
    _bat(destino / n['join'], [f'rem {BAT_TEXTOS["join"][idioma]}', f'set /p IP={BAT_TEXTOS["ip"][idioma]}',
                               f'{ps} "%~dp0coop\\iniciar-demo.ps1" -Role guest -HostIP %IP% -AutoConnect {args}', 'pause'])
    _bat(destino / n['local'], [f'rem {BAT_TEXTOS["local"][idioma]}',
                                f'{ps} "%~dp0coop\\testar-duas-instancias.ps1" {args}', 'pause'])
    velocidade = gravar_velocidade(destino, ler_velocidade(destino))
    (destino / n['leiame']).write_text('\r\n'.join(_leiame(meta, idioma, velocidade)) + '\r\n', encoding='utf-8-sig', newline='')


def copiar_scripts(coop: Path) -> None:
    """Scripts do modo Duplas, GBA-PK, emulador e lançadores desta versão da ferramenta dentro de coop/."""
    shutil.rmtree(coop / 'src', ignore_errors=True)
    shutil.copytree(ROOT / 'src', coop / 'src')
    (coop / 'vendor' / 'gba-pk').mkdir(parents=True, exist_ok=True)
    for f in ('GBA-PK_Multiplayer.lua', 'ATTRIBUTION.md', 'LICENSE.md'):
        if (ROOT / 'vendor' / 'gba-pk' / f).exists():
            shutil.copy2(ROOT / 'vendor' / 'gba-pk' / f, coop / 'vendor' / 'gba-pk' / f)
    # a pasta do emulador é achada pelo mGBA.exe dentro dela (nas releases ela tem nome curto, mGBA-<build>: o caminho
    # completo dentro de um pacote não pode passar do limite de 260 caracteres do Windows)
    emulador = sorted(d for d in (ROOT / 'tools' / 'mgba-dev').iterdir() if (d / 'mGBA.exe').exists())[-1]
    if not (coop / 'tools' / 'mgba-dev' / emulador.name).exists():
        shutil.rmtree(coop / 'tools' / 'mgba-dev', ignore_errors=True)
        shutil.copytree(emulador, coop / 'tools' / 'mgba-dev' / emulador.name,
                        ignore=shutil.ignore_patterns('mgba-sdl.exe', 'nointro.dat'))
    (coop / 'tools').mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'tools' / 'aviso-overlay.ps1', coop / 'tools' / 'aviso-overlay.ps1')
    for f in ('iniciar-demo.ps1', 'testar-duas-instancias.ps1'):
        shutil.copy2(ROOT / f, coop / f)


def montar(trabalho: Path, nome: str, perfil_lua: str, recursos: list[dict], idioma: str = IDIOMA_PADRAO) -> Path:
    destino = PACOTES / nome_pasta(nome)
    if destino.exists():
        shutil.rmtree(destino / 'coop', ignore_errors=True)
    jogo = destino / 'jogo'
    coop = destino / 'coop'
    jogo.mkdir(parents=True, exist_ok=True)
    base = nome_pasta(nome).replace(' ', '-')
    shutil.copy2(trabalho / 'rom.gba', jogo / f'{base}.gba')
    tem_save = (trabalho / 'save.sav').exists()
    if tem_save:
        shutil.copy2(trabalho / 'save.sav', jogo / f'{base}.sav')
    copiar_scripts(coop)
    (coop / 'perfil.lua').write_text(perfil_lua, encoding='utf-8')
    meta = {'nome': nome, 'base': base, 'tem_save': tem_save, 'recursos': recursos}
    (coop / 'pacote.json').write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding='utf-8')
    escrever_textos(destino, idioma)
    return destino


def pacotes() -> list[Path]:
    return sorted(p for p in PACOTES.iterdir() if eh_pacote(p)) if PACOTES.exists() else []


def garantir_meta(pacote: Path) -> bool:
    """Pacotes de versões antigas não têm coop/pacote.json: monta a partir do que está na pasta (o relatório de
    compatibilidade fica de fora do LEIA-ME, porque não foi guardado)."""
    arquivo = pacote / 'coop' / 'pacote.json'
    if arquivo.exists():
        return True
    rom = next((pacote / 'jogo').glob('*.gba'), None)
    if not rom or not (pacote / 'coop').exists():
        return False
    meta = {'nome': pacote.name, 'base': rom.stem, 'tem_save': rom.with_suffix('.sav').exists(), 'recursos': []}
    arquivo.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding='utf-8')
    return True


def trocar_idioma(idioma: str) -> None:
    """O app mudou de idioma: atalhos, LEIA-ME e avisos do jogo de todos os pacotes acompanham."""
    for pacote in pacotes():
        try:
            if garantir_meta(pacote):
                escrever_textos(pacote, idioma)
        except OSError:
            pass   # arquivo aberto em outro programa: fica para a próxima troca


def atualizar_scripts() -> list[str]:
    """Depois de atualizar (ou voltar) a ferramenta: os pacotes existentes passam a usar os scripts desta versão.
    O jogo, os saves e o progresso de cada um (coop/demo) não são tocados."""
    feitos = []
    for pacote in pacotes():
        coop = pacote / 'coop'
        if coop.exists():
            try:
                copiar_scripts(coop)
                feitos.append(pacote.name)
            except OSError:
                pass   # jogo aberto com o mGBA do pacote: fica para a próxima vez
    return feitos


# ------------------------------------------------------------------ teste de compatibilidade (em segundo plano)
_testes: dict[str, dict] = {}
# vagas do emulador: cada teste em andamento usa pastas próprias (runtime\host, runtime\host-2...), para vários pacotes
# poderem ser testados ao mesmo tempo sem um sobrescrever a ROM, o save e a configuração do outro
_vagas: set[int] = set()
_trava = threading.Lock()


def _pegar_vaga() -> int:
    with _trava:
        n = 1
        while n in _vagas:
            n += 1
        _vagas.add(n)
        return n


def _soltar_vaga(n: int) -> None:
    with _trava:
        _vagas.discard(n)


def _conferidor():
    import importlib.util
    spec = importlib.util.spec_from_file_location('check_native', ROOT / 'tests' / 'two_instance' / 'check_native.py')
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


def iniciar_teste(pacote: Path) -> str:
    jogo = pacote / 'jogo'
    rom = next(jogo.glob('*.gba'))
    save = rom.with_suffix('.sav')
    chave = pacote.name
    if chave in _testes and _testes[chave]['rodando']:
        return chave
    estado = {'rodando': True, 'pacote': pacote.name, 'inicio': time.time(),
              'cenarios': [{'id': s[0], 'titulo': s[4], 'estado': 'pendente', 'detalhe': ''} for s in SUITE]}
    _testes[chave] = estado
    sem_save = not save.exists()
    if sem_save:
        # sem save o teste começa um jogo novo sozinho e usa times de teste
        estado['cenarios'].insert(0, {'id': 'novo', 'titulo': CENARIO_NOVO, 'estado': 'pendente', 'detalhe': ''})
    sem_janela = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
    ps = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File']

    def rodar(vaga: list[str]):
        saida = pacote / 'teste'
        saida.mkdir(parents=True, exist_ok=True)
        (saida / 'reinicios.log').unlink(missing_ok=True)   # tentativas descartadas pelo vigia, só deste teste
        cenarios = estado['cenarios']
        origem = ['-Save', str(save)]
        if sem_save:
            passo, cenarios = cenarios[0], cenarios[1:]
            passo['estado'] = 'rodando'
            novo = saida / 'jogo-novo.ss0'
            for _ in range(2):   # segunda chance: o mGBA às vezes trava ao abrir, sem relação com a ROM
                subprocess.run(ps + [str(ROOT / 'tests' / 'two_instance' / 'novo_jogo.ps1'), '-Rom', str(rom),
                                     '-Profile', str(pacote / 'coop' / 'perfil.lua'), '-Out', str(novo)] + vaga,
                               capture_output=True, creationflags=sem_janela)
                if novo.exists():
                    break
            if not novo.exists():
                passo['estado'] = 'falhou'
                passo['detalhe'] = L('the new game did not reach the map in time', 'o jogo novo não chegou ao mapa a tempo',
                                     'la partida nueva no llegó al mapa a tiempo')
                for c in cenarios:
                    c['estado'] = 'pulado'
                    c['detalhe'] = L('no game on the map to test', 'sem jogo no mapa para testar', 'no hay partida en el mapa para probar')
                return
            passo['estado'] = 'passou'
            origem = ['-State', str(novo)]
        for c, (nome, cenario, segundos, extra, _) in zip(cenarios, SUITE):
            if sem_save and '-FixtureTeams' not in extra:
                extra = extra + ['-FixtureTeams']   # o jogo novo ainda não tem Pokémon
            c['estado'] = 'rodando'
            pasta = saida / nome
            shutil.rmtree(pasta, ignore_errors=True)
            cmd = ps + [str(ROOT / 'tests' / 'two_instance' / 'run_native.ps1'), '-Scenario', cenario, '-Seconds', str(segundos),
                        '-Out', str(pasta), '-Rom', str(rom), '-Profile', str(pacote / 'coop' / 'perfil.lua')] + origem + extra + vaga
            subprocess.run(cmd, capture_output=True, creationflags=sem_janela)
            try:
                _conferidor().check(pasta, cenario)
                c['estado'], c['detalhe'] = 'passou', ''
            except FileNotFoundError as e:   # um dos lados não chegou a gravar o resultado do cenário
                arq, onde = Path(e.filename or '?').name, f'teste\\{nome}'
                c['estado'] = 'falhou'
                c['detalhe'] = L(f'the scenario did not finish: {arq} is missing (see host.log and guest.log in {onde})',
                                 f'o cenário não chegou ao fim: faltou o arquivo {arq} (veja host.log e guest.log em {onde})',
                                 f'el escenario no terminó: falta el archivo {arq} (mira host.log y guest.log en {onde})')
            except AssertionError as e:   # o conferidor explica a falha na própria mensagem (nos três idiomas)
                c['estado'] = 'falhou'
                c['detalhe'] = e.args[0] if e.args and isinstance(e.args[0], dict) else str(e)[:300]
            except Exception as e:
                c['estado'], c['detalhe'] = 'falhou', (str(e) or e.__class__.__name__)[:300]

    def rodar_na_vaga():
        n = _pegar_vaga()
        try:
            rodar([] if n == 1 else ['-Slot', f'-{n}'])   # a vaga 1 é a pasta de sempre (já liberada no Firewall)
        except Exception as e:  # um erro inesperado não pode deixar o pacote "testando" para sempre
            for c in estado['cenarios']:
                if c['estado'] in ('pendente', 'rodando'):
                    c['estado'] = 'pulado'
                    c['detalhe'] = L(f'the test stopped: {e}'[:300], f'o teste parou: {e}'[:300], f'la prueba se detuvo: {e}'[:300])
        finally:
            _soltar_vaga(n)
            estado['rodando'] = False
            saida = pacote / 'teste'
            if saida.exists():
                (saida / 'resultado.json').write_text(json.dumps(estado, ensure_ascii=False, indent=1), encoding='utf-8')

    threading.Thread(target=rodar_na_vaga, daemon=True).start()
    return chave


NAO_ENCONTRADO = L('Package not found.', 'Pacote não encontrado.', 'Paquete no encontrado.')


def pasta_do_pacote(nome: str) -> Path:
    """Caminho de um pacote pelo nome vindo da tela, sem deixar sair da pasta pacotes."""
    destino = PACOTES / str(nome or '')
    if not nome or '/' in nome or '\\' in nome or nome.startswith('.') or not eh_pacote(destino):
        raise Erro(NAO_ENCONTRADO)
    if destino.resolve().parent != PACOTES.resolve():
        raise Erro(NAO_ENCONTRADO)
    return destino


def apagar(nome: str) -> None:
    """Apaga a pasta de um pacote. Primeiro renomeia (falha inteira se algo dentro está aberto, como o mGBA do
    pacote), depois remove: nunca deixa um pacote pela metade."""
    destino = pasta_do_pacote(nome)
    if nome in _testes and _testes[nome]['rodando']:
        raise Erro(L("This package's test is still running. Wait for it to finish before deleting.",
                     'O teste deste pacote ainda está rodando. Espere terminar para apagar.',
                     'La prueba de este paquete sigue en curso. Espera a que termine para borrarlo.'))
    lixo = PACOTES / f'.apagando-{nome}-{int(time.time())}'
    try:
        destino.rename(lixo)
    except OSError:
        raise Erro(L("Close this package's game windows (and its folder, if open) before deleting.",
                     'Feche as janelas do jogo deste pacote (e a pasta, se estiver aberta) antes de apagar.',
                     'Cierra las ventanas del juego de este paquete (y su carpeta, si está abierta) antes de borrarlo.'))
    shutil.rmtree(lixo, ignore_errors=True)
    _testes.pop(nome, None)


def estado_teste(chave: str) -> dict | None:
    if chave in _testes:
        return _testes[chave]
    arquivo = PACOTES / chave / 'teste' / 'resultado.json'
    if arquivo.exists():
        return json.loads(arquivo.read_text(encoding='utf-8'))
    return None
