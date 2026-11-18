"""Confere evidências reais: retorno, integridade PK3, equipe/PC e campanha."""
from pathlib import Path
import argparse
import json
import struct

from lupa import lua54

ROOT = Path(__file__).resolve().parents[2]
QUEM = {"host": {"en": "host", "pt": "anfitrião", "es": "anfitrión"},
        "guest": {"en": "partner", "pt": "parceiro", "es": "compañero"}}


def L(en, pt, es):
    """Mensagem de falha nos três idiomas do app (a tela mostra a do idioma escolhido)."""
    return {"en": en, "pt": pt, "es": es}


def check(folder: Path, scenario: str):
    lua = lua54.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    wire = lua.execute((ROOT / "src/dp_wire.lua").read_bytes())

    def read(path):
        return wire[b"decode"](path.read_bytes())

    if scenario in ("reserve", "items", "race"):
        return check_resources(folder, scenario, read)
    if scenario in ("single", "solo"):
        log = (folder / "host.log").read_text(encoding="utf-8")
        assert "HARNESS ERROR" not in log and "pausado:" not in log and "SINGLE ERROR" not in log, L('Duplas mode runtime error', 'erro de execução no modo Duplas', 'error de ejecución del modo Duplas')
        assert "SOLO battle running" in log, L('the battle never started', 'a batalha não começou', 'el combate no empezó')
        assert "SOLO back to field" in log, L('the battle never finished', 'a batalha não terminou', 'el combate no terminó')
        if scenario == "solo":
            # sem parceiro: a batalha esperou congelada e só seguiu sozinha depois de L+R+SELECT
            assert log.index("SOLO waiting for partner") < log.index("saiu do cooperativo") < log.index("SOLO battle running"),                 L('the battle had to wait for the partner and continue alone only after L+R+SELECT', 'a batalha devia esperar o parceiro e só seguir sozinha depois de L+R+SELECT', 'el combate debía esperar al compañero y seguir solo después de L+R+SELECT')
            assert "mode=Free Roam" in log, L('co-op should have been turned off for this session', 'o modo cooperativo devia ser desligado nesta sessão', 'el cooperativo debía apagarse en esta sesión')
        else:
            assert "SOLO waiting for partner" not in log, L('a single-player battle must not wait for anyone', 'a batalha individual não devia esperar ninguém', 'un combate individual no debía esperar a nadie')
        return {"scenario": scenario, "status": "passed"}

    def valid_mon(raw):
        assert len(raw) in (80, 100), L(f'Pokémon with invalid size ({len(raw)} bytes)', f'Pokémon com tamanho inválido ({len(raw)} bytes)', f'Pokémon con tamaño inválido ({len(raw)} bytes)')
        pid, ot = struct.unpack_from("<II", raw)
        key = pid ^ ot
        plain = b"".join(struct.pack("<I", value ^ key) for value in struct.unpack_from("<12I", raw, 32))
        assert sum(struct.unpack("<24H", plain)) & 65535 == struct.unpack_from("<H", raw, 28)[0], L('corrupted Pokémon (bad checksum)', 'Pokémon corrompido (soma de verificação errada)', 'Pokémon corrupto (suma de verificación incorrecta)')
        return pid, ot

    outcomes = {}
    captures = []
    for role, player in (("host", "PHX1"), ("guest", "PHX2")):
        log = (folder / f"{role}.log").read_text(encoding="utf-8")
        assert "MODE battle" in log and "RETURNED battle=" in log, L(f'{QUEM[role]["en"]}: the battle did not finish', f'{QUEM[role]["pt"]}: a batalha não terminou', f'{QUEM[role]["es"]}: el combate no terminó')
        assert "pausado:" not in log and "HARNESS ERROR" not in log, L(f'{QUEM[role]["en"]}: Duplas mode runtime error', f'{QUEM[role]["pt"]}: erro de execução no modo Duplas', f'{QUEM[role]["es"]}: error de ejecución del modo Duplas')
        before = read(folder / f"before-{role}.bin")
        after = read(folder / f"after-{role}.bin")
        result = read(folder / f"{role}-dados/resultado-{player}.bin")
        plan = result[b"plan"]
        initial = [before[b"profile"][b"party"][i] for i in range(1, len(before[b"profile"][b"party"]) + 1)]
        final = [plan[b"party"][i] for i in range(1, len(plan[b"party"]) + 1)]
        initial_ids = [valid_mon(raw) for raw in initial]
        final_ids = [valid_mon(raw) for raw in final]
        assert set(initial_ids).issubset(final_ids), L(f'{QUEM[role]["en"]}: the team lost or swapped Pokémon', f'{QUEM[role]["pt"]}: a equipe perdeu ou trocou Pokémon', f'{QUEM[role]["es"]}: el equipo perdió o cambió Pokémon')
        assert len(final) <= 6
        for name in (b"group", b"map", b"x", b"y"):
            assert before[b"position"][name] == after[b"position"][name], L(f'{QUEM[role]["en"]}: returned to the map in the wrong place', f'{QUEM[role]["pt"]}: voltou ao mapa no lugar errado', f'{QUEM[role]["es"]}: volvió al mapa en el lugar equivocado')
        for i in range(1, len(plan[b"boxes"]) + 1):
            mon = plan[b"boxes"][i][b"raw"]
            _, ot = valid_mon(mon)
            assert ot == before[b"profile"][b"otid"], L(f'{QUEM[role]["en"]}: captured Pokémon got the wrong trainer', f'{QUEM[role]["pt"]}: Pokémon capturado ficou com o treinador errado', f'{QUEM[role]["es"]}: el Pokémon capturado quedó con el entrenador equivocado')
        owned = [plan[b"captures"][i][b"uid"] for i in range(1, len(plan[b"captures"]) + 1)]
        captures.extend(owned)
        if scenario == "switch":
            # a troca tem de acontecer de verdade e trazer o sexto Pokémon de cada jogador ao seu lado do campo
            # cada jogador abriu um menu com a própria equipe; o campo é lido na máquina autoritativa (host)
            assert "PARTY menu own team" in log, L(f'{QUEM[role]["en"]}: the menu with their own team did not open', f'{QUEM[role]["pt"]}: o menu com a própria equipe não abriu', f'{QUEM[role]["es"]}: el menú con su propio equipo no se abrió')
            host_log = (folder / "host.log").read_text(encoding="utf-8")
            fields = [line.split("FIELD ", 1)[1] for line in host_log.splitlines() if "FIELD bank0=" in line]
            assert any("bank0=19 " in f + " " for f in fields), L(f"the host's 6th Pokémon never entered the field: {fields}", f'o 6º Pokémon do anfitrião não entrou em campo: {fields}', f'el 6.º Pokémon del anfitrión no entró en el campo: {fields}')
            assert any(f.endswith("bank2=32") for f in fields), L(f"the partner's 6th Pokémon never entered the field: {fields}", f'o 6º Pokémon do parceiro não entrou em campo: {fields}', f'el 6.º Pokémon del compañero no entró en el campo: {fields}')
        if scenario == "reinforce" and role == "host":
            # o treinador de um Pokémon ganhou um segundo indivíduo, coerente com o mapa (ou outro da mesma espécie)
            import re as _re
            m = _re.search(r"reforço do treinador: espécie (\d+), nível (\d+) \((.+?)\)", log)
            assert m, L('the single-Pokémon trainer got no reinforcement', 'o treinador de um Pokémon só não recebeu reforço', 'el entrenador de un solo Pokémon no recibió refuerzo')
        if scenario == "controls" and role == "host":
            # botões reais nos dois emuladores: cada lado gastou PP só no golpe que o PRÓPRIO jogador escolheu
            import re as _re
            s0 = _re.search(r"CONTROLS start bank0=(\d+),(\d+) bank2=(\d+),(\d+)", log)
            s1 = _re.search(r"CONTROLS end bank0=(\d+),(\d+) bank2=(\d+),(\d+)", log)
            assert s0 and s1, L('the battle never ran', 'a batalha não chegou a rodar', 'el combate no llegó a ejecutarse')
            a = list(map(int, s0.groups())); b = list(map(int, s1.groups()))
            assert b[0] < a[0] and b[1] == a[1], L(f'the host should have used only its 1st move (PP {a} -> {b})', f'o anfitrião devia usar só o 1º golpe (PP {a} -> {b})', f'el anfitrión debía usar solo su 1.er movimiento (PP {a} -> {b})')
            assert b[3] < a[3] and b[2] == a[2], L(f'the partner should have used only its 2nd move (PP {a} -> {b})', f'o parceiro devia usar só o 2º golpe (PP {a} -> {b})', f'el compañero debía usar solo su 2.º movimiento (PP {a} -> {b})')
        if scenario == "busy" and role == "guest":
            # chamado de dentro do menu de Pokémon e devolvido ao mesmo menu depois da batalha
            assert "BUSY party menu open menu=3" in log, L('the partner never opened the Pokémon menu', 'o parceiro não abriu o menu de Pokémon', 'el compañero no abrió el menú de Pokémon')
            assert log.index("BUSY party menu open") < log.index("MODE battle"), L('the partner was summoned before opening the menu', 'o parceiro foi chamado antes de abrir o menu', 'el compañero fue llamado antes de abrir el menú')
            assert "BUSY returned menu=3" in log, L('the partner did not return to the open menu', 'o parceiro não voltou ao menu que estava aberto', 'el compañero no volvió al menú que estaba abierto')
        if scenario == "capture":
            assert len(owned) == 1, L(f'{QUEM[role]["en"]}: expected exactly one own capture', f'{QUEM[role]["pt"]}: devia ter exatamente uma captura própria', f'{QUEM[role]["es"]}: debía tener exactamente una captura propia')
            assert len(final) == min(6, len(initial) + 1)
        outcomes[role] = {"original_team": len(initial), "returned_team": len(final), "captures": len(owned), "pc_additions": len(plan[b"boxes"])}
    assert len(captures) == len(set(captures)), L('the same wild Pokémon was delivered twice', 'o mesmo Pokémon selvagem foi entregue duas vezes', 'el mismo Pokémon salvaje se entregó dos veces')
    state = read(folder / "host-dados/campanha-PHX1.bin")
    assert not state[b"battle"], L('the battle was not recorded in the campaign', 'a batalha não foi registrada na campanha', 'el combate no se registró en la campaña')
    for role in ("host", "guest"):
        after = read(folder / f"after-{role}.bin")
        assert dict(after[b"bag"].items()) == dict(state[b"inventory"].items()), L(f'{QUEM[role]["en"]}: the bag differs from the campaign', f'{QUEM[role]["pt"]}: a bolsa ficou diferente da campanha', f'{QUEM[role]["es"]}: la mochila quedó distinta de la campaña')
    if scenario == "capture":
        before = read(folder / "before-host.bin")
        if before[b"bag"][b"3:1"]:
            assert state[b"inventory"][b"3:1"] == before[b"bag"][b"3:1"] - 2, L('Poké Ball usage is wrong', 'o gasto de Poké Balls ficou errado', 'el gasto de Poké Balls es incorrecto')
    if scenario == "trainer":
        marca = folder / "trainer-id"
        treinador = int(marca.read_text()) if marca.exists() else 89
        assert state[b"flags"][0x500 + treinador], L(f'the victory over trainer {treinador} was not shared', f'a vitória contra o treinador {treinador} não foi compartilhada', f'la victoria contra el entrenador {treinador} no se compartió')
    if scenario == "gym":
        assert state[b"flags"][0x820], L('the badge was not shared', 'a insígnia não foi compartilhada', 'la medalla no se compartió')
        before = read(folder / "before-host.bin")
        assert state[b"inventory"][b"4:289"] == (before[b"bag"][b"4:289"] or 0) + 1, L('the TM reward was not shared exactly once', 'o TM do prêmio não foi compartilhado uma única vez', 'la MT del premio no se compartió una sola vez')
    return {"scenario": scenario, "status": "passed", "players": outcomes, "revision": state[b"revision"]}


def check_resources(folder: Path, scenario: str, read):
    """Disputa pela última unidade, sem batalha: a unidade vale uma vez e as bolsas terminam iguais à campanha."""
    import re
    logs = {role: (folder / f"{role}.log").read_text(encoding="utf-8") for role in ("host", "guest")}
    for role, log in logs.items():
        assert "pausado:" not in log and "HARNESS ERROR" not in log, L(f'{QUEM[role]["en"]}: Duplas mode runtime error', f'{QUEM[role]["pt"]}: erro de execução no modo Duplas', f'{QUEM[role]["es"]}: error de ejecución del modo Duplas')
    state = read(folder / "host-dados/campanha-PHX1.bin")
    inventory = dict(state[b"inventory"].items())
    for role in ("host", "guest"):
        after = read(folder / f"after-{role}.bin")
        assert dict(after[b"bag"].items()) == inventory, L(f'{QUEM[role]["en"]}: the bag differs from the campaign', f'{QUEM[role]["pt"]}: a bolsa ficou diferente da campanha', f'{QUEM[role]["es"]}: la mochila quedó distinta de la campaña')
    result = {"scenario": scenario, "status": "passed", "revision": state[b"revision"]}
    if scenario == "reserve":
        rows = {}
        for role, log in logs.items():
            before = re.search(r"RESOURCE BEFORE hp=(\d+) max=(\d+)", log)
            after = re.search(r"RESOURCE RESULT hp=(\d+) stock=(\d+)", log)
            assert after, L(f'{QUEM[role]["en"]}: the medicine use never finished', f'{QUEM[role]["pt"]}: o uso do remédio não terminou', f'{QUEM[role]["es"]}: el uso de la medicina no terminó')
            rows[role] = (int(before.group(1)) if before else None, int(after.group(1)), int(after.group(2)))
        healed = [role for role, (b, a, _) in rows.items() if b is not None and a > b]
        assert len(healed) == 1, L(f'the last Potion should heal exactly one player: {rows}', f'a última Potion devia curar só um jogador: {rows}', f'la última Poción debía curar a un solo jugador: {rows}')
        assert all(stock == 0 for _, _, stock in rows.values()), L(f'the stock should end at zero: {rows}', f'o estoque devia terminar em zero: {rows}', f'el stock debía terminar en cero: {rows}')
        assert b"1:13" not in inventory, L('the campaign still lists the Potion', 'a campanha ainda lista a Potion', 'la campaña aún incluye la Poción')
        result["healed"] = healed[0]
    if scenario == "items":
        for role, log in logs.items():
            m = re.search(r"ITEMS RESULT tm=(\d+) potion=(\d+) held=(\d+)", log)
            assert m, L(f'{QUEM[role]["en"]}: the item dispute never finished', f'{QUEM[role]["pt"]}: a disputa de itens não terminou', f'{QUEM[role]["es"]}: la disputa de objetos no terminó')
            tm, potion, held = map(int, m.groups())
            assert tm == 0, L(f'{QUEM[role]["en"]}: the last TM should be spent once and never come back ({tm})', f'{QUEM[role]["pt"]}: o último TM devia ser gasto uma vez e não voltar ({tm})', f'{QUEM[role]["es"]}: la última MT debía gastarse una vez y no volver ({tm})')
            assert potion == 1, L(f'{QUEM[role]["en"]}: the held Potion should leave the shared bag once ({potion})', f'{QUEM[role]["pt"]}: a Potion dada para segurar devia sair da bolsa uma vez ({potion})', f'{QUEM[role]["es"]}: la Poción dada para llevar debía salir de la mochila una vez ({potion})')
            assert held == (13 if role == "guest" else 0), L(f'{QUEM[role]["en"]}: the held item should belong only to the partner\'s Pokémon ({held})', f'{QUEM[role]["pt"]}: o item segurado devia ficar só com o Pokémon do parceiro ({held})', f'{QUEM[role]["es"]}: el objeto llevado debía quedar solo con el Pokémon del compañero ({held})')
        assert b"4:289" not in inventory and inventory.get(b"1:13") == 1, L(f'the campaign bag is wrong: {inventory}', f'a bolsa da campanha ficou errada: {inventory}', f'la mochila de la campaña es incorrecta: {inventory}')
    if scenario == "race":
        tm, give = {}, {}
        for role, log in logs.items():
            m = re.search(r"RACE tm result move4=(\d+) stock=(\d+)", log)
            g = re.search(r"RACE give result held=(\d+) stock=(\d+)", log)
            assert m and g, L(f'{QUEM[role]["en"]}: the race never finished', f'{QUEM[role]["pt"]}: a disputa não terminou', f'{QUEM[role]["es"]}: la disputa no terminó')
            tm[role] = (int(m.group(1)), int(m.group(2)))
            give[role] = (int(g.group(1)), int(g.group(2)))
        learned = [r for r, (move, _) in tm.items() if move == 92]
        reverted = [r for r, (move, _) in tm.items() if move == 33]
        assert len(learned) == 1 and len(reverted) == 1, L(f'the last TM should teach exactly one Pokémon: {tm}', f'o último TM devia ensinar exatamente um Pokémon: {tm}', f'la última MT debía enseñar exactamente a un Pokémon: {tm}')
        holding = [r for r, (held, _) in give.items() if held == 13]
        assert len(holding) == 1, L(f'the last Potion should be held by exactly one Pokémon: {give}', f'a última Potion devia ficar com exatamente um Pokémon: {give}', f'la última Poción debía quedar con exactamente un Pokémon: {give}')
        assert all(stock == 0 for _, stock in list(tm.values()) + list(give.values())), L(f'the stock should end at zero: {tm} {give}', f'o estoque devia terminar em zero: {tm} {give}', f'el stock debía terminar en cero: {tm} {give}')
        assert b"4:289" not in inventory and b"1:13" not in inventory, L(f'the campaign still lists the items: {inventory}', f'a campanha ainda lista os itens: {inventory}', f'la campaña aún incluye los objetos: {inventory}')
        assert any("retirada recusada" in log for log in logs.values()), L('no removal was refused', 'nenhuma retirada foi recusada', 'no se rechazó ninguna retirada')
        result["tm_kept_by"] = learned[0]
        result["potion_held_by"] = holding[0]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", type=Path)
    parser.add_argument("--scenario", default="wild")
    args = parser.parse_args()
    result = check(args.folder, args.scenario)
    text = json.dumps(result, indent=2)
    print(text)
    (args.folder / "validation.json").write_text(text + "\n", encoding="utf-8")
