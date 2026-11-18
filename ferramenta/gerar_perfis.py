"""Gera os perfis oficiais e as assinaturas a partir dos símbolos dos projetos de descompilação (pret).

Uso (só para quem mantém a ferramenta; o app usa os arquivos gerados):
  python ferramenta/gerar_perfis.py <pasta com os .sym do pret> <pasta com as ROMs oficiais>

Saída:
  ferramenta/perfis.json      perfil exato de cada ROM oficial (código + revisão), pelo nome de cada rotina/variável
  ferramenta/assinaturas.json assinaturas tiradas das ROMs de referência disponíveis (achar os pontos em modificações
                              e em ROMs de outros idiomas)
Os .sym vêm dos branches "symbols" de pret/pokefirered, pret/pokeemerald e pret/pokeruby.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import assinaturas as A

AQUI = Path(__file__).parent

# ponto do perfil -> (nome do símbolo, deslocamento), por família. O deslocamento vale para todas as versões da família.
PONTOS_FRLG = json.loads((AQUI / 'simbolos-frlg.json').read_text(encoding='utf-8'))
# Emerald: mesmos nomes do FireRed, menos a pesca (mesma assinatura: info em r0, vara em r1)
PONTOS_E = dict(PONTOS_FRLG, fishingHook=['GenerateFishingWildMon', 0])
# Ruby/Sapphire: save em endereço fixo (sem ponteiro) e três rotinas com outro nome (mesmos argumentos)
PONTOS_RS = {k: v for k, v in PONTOS_FRLG.items() if k not in ('saveBlock1Ptr', 'saveBlock2Ptr', 'storagePtr')}
PONTOS_RS.update(encounterKindHook=['GenerateWildMon', 0], fishingHook=['GenerateFishingWildMon', 0],
                 itemEffect=['ExecuteTableBasedItemEffect_', 0], saveBlock1=['gSaveBlock1', 0], saveBlock2=['gSaveBlock2', 0],
                 storage=['gPokemonStorage', 0])
PONTOS = {'FRLG': PONTOS_FRLG, 'E': PONTOS_E, 'RS': PONTOS_RS}

# ROMs oficiais conhecidas: (código, revisão) -> (família, nome legível, arquivo .sym)
OFICIAIS = {
    ('BPRE', 0): ('FRLG', 'FireRed 1.0 (EUA)', 'pokefirered_symbols_pokefirered.sym'),
    ('BPRE', 1): ('FRLG', 'FireRed 1.1 (EUA)', 'pokefirered_symbols_pokefirered_rev1.sym'),
    ('BPGE', 0): ('FRLG', 'LeafGreen 1.0 (EUA)', 'pokefirered_symbols_pokeleafgreen.sym'),
    ('BPGE', 1): ('FRLG', 'LeafGreen 1.1 (EUA)', 'pokefirered_symbols_pokeleafgreen_rev1.sym'),
    ('BPEE', 0): ('E', 'Emerald (EUA)', 'pokeemerald_symbols_pokeemerald.sym'),
    ('AXVE', 0): ('RS', 'Ruby 1.0 (EUA)', 'pokeruby_symbols_pokeruby.sym'),
    ('AXVE', 1): ('RS', 'Ruby 1.1 (EUA)', 'pokeruby_symbols_pokeruby_rev1.sym'),
    ('AXPE', 0): ('RS', 'Sapphire 1.0 (EUA)', 'pokeruby_symbols_pokesapphire.sym'),
}
CODIGO = {'BPRE': 0x45525042, 'BPGE': 0x45475042, 'BPEE': 0x45455042, 'AXVE': 0x45565841, 'AXPE': 0x45505841}


def ler_sym(arquivo: Path) -> dict:
    d = {}
    for linha in arquivo.read_text(encoding='utf-8', errors='replace').splitlines():
        p = linha.split()
        if len(p) >= 4 and p[3] not in d:
            d[p[3]] = int(p[0], 16)
    return d


def perfil_do_simbolo(sym: dict, pontos: dict) -> dict:
    out = {}
    for chave, (nome, deslocamento) in pontos.items():
        if nome in sym:
            out[chave] = sym[nome] + deslocamento
    return out


def main(pasta_sym: Path, pasta_roms: Path, extras: list[Path] = ()) -> None:
    perfis = {}
    for (codigo, rev), (familia, nome, arquivo) in OFICIAIS.items():
        valores = perfil_do_simbolo(ler_sym(pasta_sym / arquivo), PONTOS[familia])
        valores.update({'name': nome, 'family': familia, 'gameCode': CODIGO[codigo], 'revision': rev})
        perfis[f'{codigo}{rev}'] = valores
    (AQUI / 'perfis.json').write_text(json.dumps(perfis, indent=1, ensure_ascii=False), encoding='utf-8')

    # assinaturas: as ROMs oficiais da pasta + ROMs extras (traduções, modificações) passadas na linha de comando.
    # Uma ROM extra com cabeçalho oficial usa o perfil dele; as outras, o FireRed 1.0 (EUA), base mais comum de modificações.
    referencias = [(rom, A.perfil_padrao()) for rom in extras if rom.exists()]
    for rom in sorted(pasta_roms.glob('*.gba')) + [e for e in extras if e.exists()]:
        dados = rom.read_bytes()
        chave = dados[0xAC:0xB0].decode('ascii', 'replace') + str(dados[0xBC])
        if chave in perfis:
            referencias.append((rom, perfis[chave]))
    familias = {}
    for rom, valores in referencias:
        if not rom.exists():
            continue
        familia = valores.get('family', 'FRLG')
        juntas = familias.setdefault(familia, {'referencia': [], 'ancoras': {}, 'sem_assinatura': []})
        parcial = A.construir(rom, valores)
        juntas['referencia'].append(f"referência {len(juntas['referencia']) + 1}: {len(parcial['ancoras'])} pontos")
        for chave, ancora in parcial['ancoras'].items():
            atual = juntas['ancoras'].setdefault(chave, {'referencia': ancora['referencia'], 'codigo': ancora['codigo'],
                                                         'assinaturas': []})
            if 'amostra' in ancora and 'amostra' not in atual:
                atual['amostra'] = ancora['amostra']
            vistas = {json.dumps(a, sort_keys=True) for a in atual['assinaturas']}
            for a in ancora['assinaturas']:
                if json.dumps(a, sort_keys=True) not in vistas:
                    atual['assinaturas'].append(a)
    # assinaturas por família: uma rotina do Emerald não pode ser achada pela assinatura do FireRed (nem o contrário)
    for familia, juntas in familias.items():
        juntas['sem_assinatura'] = sorted(set(PONTOS[familia]) - set(juntas['ancoras']))
    (AQUI / 'assinaturas.json').write_text(json.dumps({'familias': familias}, indent=1), encoding='utf-8')
    print('perfis oficiais:', ', '.join(f"{k} ({v['name']}, {len(v) - 4} pontos)" for k, v in perfis.items()))
    for familia, juntas in familias.items():
        print(f'assinaturas {familia}:', '; '.join(juntas['referencia']), '| sem assinatura:', juntas['sem_assinatura'])


if __name__ == '__main__':
    main(Path(sys.argv[1]), Path(sys.argv[2]), [Path(a) for a in sys.argv[3:]])
