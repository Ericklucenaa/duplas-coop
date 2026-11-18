"""Assinaturas de código para levar o modo Duplas a outras ROMs da 3ª geração.

O perfil padrão (src/dp_profile.lua) tem os endereços do FireRed 1.0. Para cada um, `construir` grava uma assinatura tirada
da ROM de referência; `resolver` procura as assinaturas em outra ROM e devolve o perfil dela.

- Rotina da ROM (endereço de código): bytes em volta do endereço, com as instruções BL mascaradas (o destino muda quando
  o código muda de lugar). Guarda a distância do início da assinatura até o endereço.
- Tabela da ROM ou endereço de memória: um trecho de código que carrega esse valor com LDR [pc]. Na ROM nova, acha o
  trecho, decodifica o LDR e lê o literal: o valor sai da própria ROM, mesmo que tenha mudado.
Sem endereço fixo: uma modificação que moveu rotinas continua funcionando enquanto o código delas for o mesmo.
"""
from __future__ import annotations

import json
import re
import struct
from pathlib import Path


import os
ROOT = Path(os.environ.get('DUPLAS_RAIZ') or Path(__file__).resolve().parents[1])
ROM_BASE = 0x08000000
META = {'name', 'family', 'gameCode', 'revision', 'cave'}
DERIVED = {'idle', 'spin', 'battleScript', 'callback2', 'savedCallback'}
CAVE_SIZE = 0x200
# lugares fixos de ROM usados pelo GBA-PK (não podem receber o espaço do modo Duplas)
GBAPK_SPOTS = [(0x08A7FC00, 0x400), (0x08A80000, 0x400)]


def perfil_padrao() -> dict:
    """Lê os endereços do próprio dp_profile.lua (fonte única), sem precisar de Lua: só a tabela inicial."""
    texto = (ROOT / 'src' / 'dp_profile.lua').read_text(encoding='utf-8')
    inicio = texto.index('local P={')
    tabela = texto[inicio:texto.index('\n}', inicio)]
    out = {}
    for nome, valor in re.findall(r"(\w+)=(0x[0-9a-fA-F]+|\d+|'[^']*')", tabela):
        out[nome] = valor[1:-1] if valor.startswith("'") else int(valor, 0)
    return out


def _mascara_bl(dados: bytes) -> list[bool]:
    """True = byte que vale na comparação. BL (duas meias-palavras 11110... 11111...) fica de fora."""
    vale = [True] * len(dados)
    i = 0
    while i + 3 < len(dados):
        h1 = dados[i] | dados[i + 1] << 8
        h2 = dados[i + 2] | dados[i + 3] << 8
        if (h1 & 0xF800) == 0xF000 and (h2 & 0xF800) == 0xF800:
            vale[i:i + 4] = [False] * 4
            i += 4
        else:
            if (h1 & 0xF800) == 0x4800:      # ldr rX,[pc,#n]: o registrador vale, a distância n não
                vale[i] = False
            i += 2
    return vale


def _regex(dados: bytes, vale: list[bool]) -> re.Pattern:
    partes = [re.escape(bytes([b])) if v else b'.' for b, v in zip(dados, vale)]
    return re.compile(b''.join(partes), re.DOTALL)


def _achados(rom: bytes, padrao: re.Pattern, alinhamento: int = 2) -> list[int]:
    out = []
    for m in padrao.finditer(rom):
        if m.start() % alinhamento == 0:
            out.append(m.start())
            if len(out) > 3:
                break
    return out


def _ldr_literal(rom: bytes, pos: int) -> int | None:
    """Thumb LDR Rd,[pc,#imm] em pos -> posição do literal na ROM (ou None)."""
    h = rom[pos] | rom[pos + 1] << 8
    if (h & 0xF800) != 0x4800:
        return None
    return ((pos + 4) & ~3) + (h & 0xFF) * 4


# ------------------------------------------------------------------ construção (a partir da ROM de referência)
def _assinatura_codigo(rom: bytes, alvo: int) -> dict | None:
    pos = alvo - ROM_BASE
    for antes, depois in ((16, 24), (24, 40), (40, 56), (64, 64)):
        ini = max(0, pos - antes)
        dados = rom[ini:pos + depois]
        vale = _mascara_bl(dados)
        if sum(vale) < 16:
            continue
        if len(_achados(rom, _regex(dados, vale))) == 1:
            return {'tipo': 'codigo', 'bytes': dados.hex(), 'vale': ''.join('1' if v else '0' for v in vale),
                    'deslocamento': pos - ini}
    return None


def _assinaturas_literal(rom: bytes, valor: int, limite: int = 3) -> list[dict]:
    """Trechos de código que carregam `valor` por LDR [pc]."""
    alvo = struct.pack('<I', valor)
    out = []
    for m in re.finditer(re.escape(alvo), rom):
        lit = m.start()
        if lit % 4 or lit > 0x01000000:
            continue
        # LDR Rd,[pc,#imm] alcança até 1020 bytes à frente
        for ldr in range(max(0, lit - 1020), lit, 2):
            if _ldr_literal(rom, ldr) != lit:
                continue
            for antes, depois in ((12, 2), (20, 2), (32, 2), (32, 18), (48, 34), (64, 48)):
                ini = ldr - antes
                if ini < 0 or ldr + depois > lit:
                    continue
                dados = rom[ini:ldr + depois]
                vale = _mascara_bl(dados)
                if sum(vale) < 10:
                    continue
                if len(_achados(rom, _regex(dados, vale))) == 1:
                    out.append({'tipo': 'literal', 'bytes': dados.hex(),
                                'vale': ''.join('1' if v else '0' for v in vale), 'ldr': ldr - ini})
                    break
            if len(out) >= limite:
                return out
    return out


def construir(rom_referencia: Path, valores: dict | None = None) -> dict:
    """Assinaturas tiradas de uma ROM cujos endereços são conhecidos (`valores`; padrão: o perfil do FireRed 1.0)."""
    rom = rom_referencia.read_bytes()
    perfil = dict(valores or perfil_padrao())
    perfil.setdefault('name', rom_referencia.name)
    ancoras, sem = {}, []
    for nome, valor in sorted(perfil.items()):
        if nome in META or nome in DERIVED or not isinstance(valor, int):
            continue
        codigo = ROM_BASE <= valor < ROM_BASE + len(rom) and nome not in (
            'controllersTable', 'commandsTable', 'itemsTable', 'wildHeaders')
        lista = []
        if codigo:
            a = _assinatura_codigo(rom, valor)
            if a:
                lista.append(a)
        lista += _assinaturas_literal(rom, valor | 1 if codigo else valor)
        if codigo and not lista[1:]:
            lista += _assinaturas_literal(rom, valor)
        if lista:
            ancoras[nome] = {'referencia': valor, 'codigo': codigo, 'assinaturas': lista}
            if codigo:
                amostra = rom[valor - ROM_BASE:valor - ROM_BASE + 48]
                ancoras[nome]['amostra'] = {'bytes': amostra.hex(), 'vale': ''.join('1' if v else '0' for v in _mascara_bl(amostra))}
        else:
            sem.append(nome)
    # Rotina com código idêntico em vários lugares: posição relativa a uma vizinha com assinatura própria, conferida
    # pelos bytes no destino (sem os BL).
    for nome in list(sem):
        valor = perfil[nome]
        if not (ROM_BASE <= valor < ROM_BASE + len(rom)) or nome in ('controllersTable', 'commandsTable', 'itemsTable', 'wildHeaders'):
            continue
        for base, anc in ancoras.items():
            if anc['codigo'] and anc['assinaturas'][0]['tipo'] == 'codigo' and abs(anc['referencia'] - valor) <= 0x400:
                dados = rom[valor - ROM_BASE:valor - ROM_BASE + 16]
                ancoras[nome] = {'referencia': valor, 'codigo': True, 'assinaturas': [
                    {'tipo': 'relativo_codigo', 'base': base, 'delta': valor - anc['referencia'], 'bytes': dados.hex(),
                     'vale': ''.join('1' if v else '0' for v in _mascara_bl(dados))}]}
                sem.remove(nome)
                break
    # Código idêntico em vários lugares (ex.: a rotina de comandos de cada tipo de controlador só muda a tabela):
    # o LDR é localizado pela distância até uma rotina vizinha que já tem assinatura própria.
    for nome in list(sem):
        valor = perfil[nome]
        achado = None
        candidatos = []
        for base, anc in ancoras.items():
            if not anc['codigo']:
                continue
            b = anc['referencia'] - ROM_BASE
            for ldr in range(max(0, b - 0x400), min(len(rom) - 2, b + 0x400), 2):
                lit = _ldr_literal(rom, ldr)
                if lit is not None and lit + 4 <= len(rom) and struct.unpack_from('<I', rom, lit)[0] == valor:
                    candidatos.append((0 if ldr >= b else 1, abs(ldr - b), base, ldr - b))
        if candidatos:
            _, _, base, delta = min(candidatos)
            achado = {'tipo': 'relativo', 'base': base, 'ldr_delta': delta}
        if achado:
            ancoras[nome] = {'referencia': valor, 'codigo': False, 'assinaturas': [achado]}
            sem.remove(nome)
    return {'referencia': perfil['name'], 'ancoras': ancoras, 'sem_assinatura': sem}


# ------------------------------------------------------------------ resolução (ROM nova)
def _localizar(rom: bytes, nome: str, ancora: dict, resolvidos: dict | None = None) -> tuple[int | None, str]:
    votos = {}
    for a in ancora['assinaturas']:
        if a['tipo'] == 'relativo_codigo':
            base = (resolvidos or {}).get(a['base'])
            if base is None:
                continue
            valor = base + a['delta']
            dados = bytes.fromhex(a['bytes']); vale = [c == '1' for c in a['vale']]
            off = valor - ROM_BASE
            if all(not v or rom[off + i] == d for i, (d, v) in enumerate(zip(dados, vale))):
                votos[valor] = votos.get(valor, 0) + 1
            continue
        if a['tipo'] == 'relativo':
            base = (resolvidos or {}).get(a['base'])
            if base is None:
                continue
            lit = _ldr_literal(rom, base - ROM_BASE + a['ldr_delta'])
            if lit is None or lit + 4 > len(rom):
                continue
            valor = struct.unpack_from('<I', rom, lit)[0]
            # conferência: aponta para a ROM e começa com ponteiros de rotina (Thumb, ímpares, dentro da ROM)
            off = valor - ROM_BASE
            if not (0 <= off < len(rom) - 16):
                continue
            entradas = struct.unpack_from('<4I', rom, off)
            if not all(e & 1 and ROM_BASE <= e < ROM_BASE + len(rom) for e in entradas):
                continue
            votos[valor] = votos.get(valor, 0) + 1
            continue
        dados = bytes.fromhex(a['bytes'])
        vale = [c == '1' for c in a['vale']]
        achados = _achados(rom, _regex(dados, vale))
        if len(achados) != 1:
            continue
        ini = achados[0]
        if a['tipo'] == 'codigo':
            valor = ROM_BASE + ini + a['deslocamento']
        else:
            lit = _ldr_literal(rom, ini + a['ldr'])
            if lit is None or lit + 4 > len(rom):
                continue
            valor = struct.unpack_from('<I', rom, lit)[0]
            if ancora['codigo']:
                valor &= ~1
        votos[valor] = votos.get(valor, 0) + 1
    if not votos:
        return None, 'não encontrado'
    if len(votos) > 1:
        melhor = max(votos, key=votos.get)
        if list(votos.values()).count(votos[melhor]) > 1:
            return None, 'ambíguo: ' + ', '.join(f'{v:#x}' for v in votos)
        return melhor, f'maioria ({votos[melhor]} de {sum(votos.values())})'
    valor = next(iter(votos))
    return valor, f'encontrado ({votos[valor]} assinatura(s))'


def _espaco_livre(rom: bytes, preferido: int) -> int | None:
    def livre(endereco: int) -> bool:
        off = endereco - ROM_BASE
        if off < 0 or off + CAVE_SIZE > len(rom):
            return False
        if any(s <= endereco < s + n or endereco <= s < endereco + CAVE_SIZE for s, n in GBAPK_SPOTS):
            return False
        bloco = rom[off:off + CAVE_SIZE]
        # livre = 0xFF, ou já contém o que o próprio modo Duplas escreve (bx lr / b .)
        return all(b == 0xFF for b in bloco[0x40:]) and bloco[0:2] in (b'\xff\xff', b'\x70\x47')
    if livre(preferido):
        return preferido
    fim = len(rom) - CAVE_SIZE
    inicio = max(0x00100000, len(rom) - 0x00400000)
    for off in range(fim - fim % 0x100, inicio, -0x100):
        if livre(ROM_BASE + off):
            return ROM_BASE + off
    return None


def leitura_do_controle(rom: bytes) -> int | None:
    """Ponto logo depois de o jogo ler o controle: `ldr r0,=REG_KEYINPUT` seguido de `ldrh r1,[r0]`.
    Vale para a ReadKeys original e para a rotina que uma tradução/modificação pôs no lugar dela (ex.: Ruby PT-BR,
    em que a ReadKeys virou um salto para uma rotina de relógio). Havendo mais de uma leitura, fica a mais perto do início."""
    literal = struct.pack('<I', 0x04000130)
    achados = []
    for m in re.finditer(re.escape(literal), rom):
        lit = m.start()
        if lit % 4:
            continue
        for ldr in range(max(0, lit - 1020), lit, 2):
            if _ldr_literal(rom, ldr) == lit and (rom[ldr] | rom[ldr + 1] << 8) >> 8 == 0x48:   # ldr r0,[pc,#]
                if rom[ldr + 2] == 0x01 and rom[ldr + 3] == 0x88:                                # ldrh r1,[r0]
                    achados.append(ROM_BASE + ldr + 4)
    return min(achados) if achados else None


FAMILIAS = {'BPRE': ('FRLG', 'FireRed'), 'BPGE': ('FRLG', 'LeafGreen'), 'BPEE': ('E', 'Emerald'),
            'AXVE': ('RS', 'Ruby'), 'AXPE': ('RS', 'Sapphire')}
IDIOMAS = {'E': 'EUA', 'P': 'Europa (inglês)', 'J': 'Japão', 'F': 'França', 'D': 'Alemanha', 'I': 'Itália', 'S': 'Espanha'}


def cabecalho(rom: bytes) -> dict:
    codigo = rom[0xAC:0xB0].decode('ascii', 'replace')
    familia, jogo = FAMILIAS.get(codigo[:3] + 'E', (None, None))
    return {'titulo': rom[0xA0:0xAC].decode('ascii', 'replace').strip('\x00 '), 'codigo': codigo,
            'revisao': rom[0xBC], 'tamanho_mb': len(rom) // (1024 * 1024), 'familia': familia, 'jogo': jogo,
            'idioma': IDIOMAS.get(codigo[3:], codigo[3:])}


def resolver(rom: bytes, ancoras: dict, oficiais: dict | None = None) -> dict:
    """Assinaturas primeiro (valem também para modificações); o que faltar vem do perfil oficial desta versão, se houver."""
    cab = cabecalho(rom)
    if 'familias' in ancoras:                      # um bloco de assinaturas por família de jogo
        ancoras = ancoras['familias'].get(cab['familia'] or '', {'ancoras': {}, 'sem_assinatura': []})
    perfil = {'gameCode': struct.unpack_from('<I', rom, 0xAC)[0], 'revision': cab['revisao'],
              'family': cab['familia'] or '?', 'name': f"{cab['jogo'] or cab['titulo']} {cab['revisao'] and '1.1' or '1.0'} ({cab['idioma']})"}
    relatorio = {}
    resolvidos = {}
    # primeiro os que têm assinatura própria; depois os relativos (precisam do vizinho resolvido)
    ordem = sorted(ancoras['ancoras'].items(), key=lambda kv: kv[1]['assinaturas'][0]['tipo'].startswith('relativo'))
    for nome, ancora in ordem:
        valor, como = _localizar(rom, nome, ancora, resolvidos)
        if valor is not None:
            resolvidos[nome] = valor
        relatorio[nome] = {'valor': valor, 'como': como, 'referencia': ancora['referencia']}
        if valor is not None:
            perfil[nome] = valor
    for nome, ancora in ancoras['ancoras'].items():
        if relatorio.get(nome, {}).get('valor') is not None or 'amostra' not in ancora:
            continue
        dados = bytes.fromhex(ancora['amostra']['bytes']); vale = [c == '1' for c in ancora['amostra']['vale']]
        vizinhas = sorted((abs(a['referencia'] - ancora['referencia']), n) for n, a in ancoras['ancoras'].items()
                          if a['codigo'] and resolvidos.get(n) is not None and abs(a['referencia'] - ancora['referencia']) <= 0x800)
        for _, viz in vizinhas[:4]:
            candidato = resolvidos[viz] + (ancora['referencia'] - ancoras['ancoras'][viz]['referencia'])
            off = candidato - ROM_BASE
            if 0 <= off < len(rom) - 48 and all(not v or rom[off + i] == d for i, (d, v) in enumerate(zip(dados[:16], vale[:16]))):
                relatorio[nome] = {'valor': candidato, 'como': f'pela vizinha {viz} (bytes conferidos)', 'referencia': ancora['referencia']}
                perfil[nome] = candidato
                resolvidos[nome] = candidato
                break
    # Último recurso (versões traduzidas, revisões): busca por semelhança perto de onde as vizinhas dizem que a rotina
    # está. Só aceita com >= 90% dos bytes iguais e folga clara sobre o segundo melhor lugar.
    for nome, ancora in ancoras['ancoras'].items():
        if relatorio.get(nome, {}).get('valor') is not None or 'amostra' not in ancora:
            continue
        dados = bytes.fromhex(ancora['amostra']['bytes']); vale = [c == '1' for c in ancora['amostra']['vale']]
        validos = sum(vale)
        if validos < 24:
            continue
        perto = sorted((abs(a['referencia'] - ancora['referencia']), n) for n, a in ancoras['ancoras'].items()
                       if a['codigo'] and resolvidos.get(n) is not None and n != nome)
        if not perto:
            continue
        _, viz = perto[0]
        previsto = resolvidos[viz] + (ancora['referencia'] - ancoras['ancoras'][viz]['referencia']) - ROM_BASE
        notas = []
        for off in range(max(0, previsto - 0x1000) & ~1, min(len(rom) - len(dados), previsto + 0x1000), 2):
            iguais = sum(1 for i, (d, v) in enumerate(zip(dados, vale)) if v and rom[off + i] == d)
            notas.append((iguais / validos, off))
        notas.sort(reverse=True)
        if notas and notas[0][0] >= 0.9 and (len(notas) < 2 or notas[0][0] - notas[1][0] >= 0.15):
            valor = ROM_BASE + notas[0][1]
            relatorio[nome] = {'valor': valor, 'referencia': ancora['referencia'],
                               'como': f'por semelhança ({notas[0][0]:.0%} dos bytes, perto de {viz})'}
            perfil[nome] = valor
            resolvidos[nome] = valor
    # o LDR relativo pode depender de uma rotina achada só agora
    for nome, ancora in ancoras['ancoras'].items():
        if relatorio.get(nome, {}).get('valor') is None and ancora['assinaturas'][0]['tipo'].startswith('relativo'):
            valor, como = _localizar(rom, nome, ancora, resolvidos)
            if valor is not None:
                relatorio[nome] = {'valor': valor, 'como': como, 'referencia': ancora['referencia']}
                perfil[nome] = valor
    for nome in ancoras.get('sem_assinatura', []):
        relatorio[nome] = {'valor': None, 'como': 'sem assinatura na referência', 'referencia': None}
    oficial = (oficiais or {}).get(f"{cab['codigo']}{cab['revisao']}")
    if oficial:
        perfil['name'] = oficial['name']
        for nome, valor in oficial.items():
            if nome in ('name', 'family', 'gameCode', 'revision') or not isinstance(valor, int):
                continue
            atual = relatorio.get(nome, {}).get('valor')
            if atual is None:
                relatorio[nome] = {'valor': valor, 'como': 'símbolo oficial desta versão', 'referencia': valor}
                perfil[nome] = valor
            elif atual != valor:
                relatorio[nome]['como'] += ' (difere do oficial: ROM modificada)'
    teclas = leitura_do_controle(rom)
    if teclas is not None:
        antes = relatorio.get('readKeysR1', {}).get('valor')
        relatorio['readKeysR1'] = {'valor': teclas, 'referencia': antes,
                                   'como': 'leitura do controle' + ('' if antes in (None, teclas) else f' (assinatura dava {antes:#x})')}
        perfil['readKeysR1'] = teclas
    cave = _espaco_livre(rom, perfil_padrao()['cave'])
    relatorio['cave'] = {'valor': cave, 'como': 'espaço livre' if cave else 'sem espaço livre', 'referencia': None}
    if cave:
        perfil['cave'] = cave
    return {'cabecalho': cab, 'perfil': perfil, 'relatorio': relatorio}


def perfil_lua(perfil: dict) -> str:
    linhas = ['-- Perfil gerado pela ferramenta do modo Duplas. Não edite à mão: gere de novo a partir da ROM.', 'return {']
    for k in sorted(perfil):
        v = perfil[k]
        if isinstance(v, str):
            linhas.append(f'    {k}={json.dumps(v, ensure_ascii=False)},')
        else:
            linhas.append(f'    {k}={v:#x},' if v > 9 else f'    {k}={v},')
    linhas.append('}')
    return '\n'.join(linhas) + '\n'


if __name__ == '__main__':
    import sys
    ref = Path(sys.argv[1])
    dados = construir(ref)
    destino = Path(__file__).with_name('assinaturas.json')
    destino.write_text(json.dumps(dados, indent=1), encoding='utf-8')
    print(f"{len(dados['ancoras'])} endereços com assinatura; sem assinatura: {dados['sem_assinatura']}")
