"""Testes do livro-razão da bolsa/carteira compartilhada (src/dp_ledger.lua), rodando o Lua 5.4 real via lupa.

Uso: python -m pytest tests/unit -q   (ou: python tests/unit/test_ledger.py)
Simula o anfitrião e os jogadores trocando os pacotes de texto do protocolo (codificar/decodificar de verdade).
"""
from pathlib import Path
import unittest
from lupa import lua54

SRC = Path(__file__).resolve().parents[2] / 'src' / 'dp_ledger.lua'


def new_lua():
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    L = lua.execute(SRC.read_text(encoding='utf-8'))
    return lua, L


class Net:
    """Anfitrião ('A', também joga) + convidado ('B'), com o mesmo caminho de pacotes de texto do jogo."""

    def __init__(self, host_bag, guest_bag):
        self.lua, self.L = new_lua()
        self.t = self.lua.table_from
        self.host = self.L.newHost(self.t(host_bag))
        self.ram = {'A': dict(host_bag), 'B': dict(guest_bag)}
        self.cli = {'A': self.L.newClient(), 'B': self.L.newClient()}
        self.L.join(self.cli['A'], 0, False)
        self.cli['A'].shown = self.t(host_bag)
        self.last_sent = None

    def lt(self, d):
        return self.t(d)

    def pd(self, lt):
        return {k: v for k, v in lt.items()} if lt else {}

    def join_guest(self):
        merge = not self.host.merged['B']
        self.host.merged['B'] = True
        ack = self.host.acks['B'] or 0
        official = self.pd(self.L.snapshot(self.host))
        ops, target = self.L.onFull(self.cli['B'], self.lt(self.ram['B']), self.lt(official), ack, merge, None)
        for i in range(1, len(ops) + 1):
            self.L.apply(self.host, 'B', self.L.decodeOp(self.L.encodeOp(ops[i])))
        self.ram['B'] = self.pd(target)

    def send_ops(self, who, claims=None):
        """O jogador lê a RAM, gera operações, codifica; o anfitrião decodifica e aplica."""
        ops = self.L.diff(self.cli[who], self.lt(self.ram[who]), self.lt(claims or {}))
        results = []
        for i in range(1, len(ops) + 1):
            wire = self.L.encodeOp(ops[i])
            assert len(wire) <= 43, wire
            results.append(self.L.apply(self.host, who, self.L.decodeOp(wire)))
        return results

    def deliver(self, who, full=False):
        """Anfitrião manda o estado oficial (entradas + fim de lote); o jogador reconcilia e escreve na RAM."""
        snap = self.L.snapshot(self.host)
        official = {}
        for k, v in snap.items():
            ver, key, qty = self.L.decodeEntry(self.L.encodeEntry(self.host.ver, k, v))
            official[key] = qty
        ver, ack, _ = self.L.decodeEnd(self.L.encodeEnd(self.host.ver, self.host.acks[who] or 0, full))
        target = self.L.reconcile(self.cli[who], self.lt(official), ack)
        self.ram[who] = self.pd(target)

    def sync(self):
        for who in ('A', 'B'):
            self.send_ops(who)
        for who in ('A', 'B'):
            self.deliver(who)

    def official(self):
        return self.pd(self.L.snapshot(self.host))


class LedgerTest(unittest.TestCase):
    def setUp(self):
        self.n = Net({'3:4': 10, '1:13': 5, '1:14': 2, 'M': 5000}, {})
        self.n.join_guest()

    def test_ct014_ct015_pokeballs_and_potion_are_shared(self):
        n = self.n
        self.assertEqual(n.ram['B'], n.ram['A'])
        n.ram['B']['3:4'] -= 1          # convidado joga uma Poké Ball
        n.ram['A']['1:13'] -= 1         # anfitrião usa uma Potion
        n.sync()
        for who in 'AB':
            self.assertEqual(n.ram[who]['3:4'], 9)
            self.assertEqual(n.ram[who]['1:13'], 4)

    def test_spec_example_items_found_by_partner(self):
        n = self.n
        n.ram['B']['3:4'] += 3          # o parceiro encontra 3 Poké Balls
        n.sync()
        self.assertEqual(n.ram['A']['3:4'], 13)
        self.assertEqual(n.ram['B']['3:4'], 13)

    def test_ct025_wallet(self):
        n = self.n
        n.ram['A']['M'] -= 800
        n.sync()
        n.ram['B']['M'] += 1500
        n.sync()
        self.assertEqual(n.ram['A']['M'], 5700)
        self.assertEqual(n.ram['B']['M'], 5700)

    def test_ct017_simultaneous_pickup_of_same_item_ball(self):
        n = self.n
        n.ram['A']['1:13'] += 1
        n.ram['B']['1:13'] += 1
        ra = n.send_ops('A', {'1:13': 0x3C})
        rb = n.send_ops('B', {'1:13': 0x3C})
        self.assertEqual(ra[0][0], 'ok')
        self.assertEqual(rb[0][0], 'claimed')
        n.deliver('A'); n.deliver('B')
        self.assertEqual(n.ram['A']['1:13'], 6)
        self.assertEqual(n.ram['B']['1:13'], 6)

    def test_last_item_spent_by_both_is_consumed_once(self):
        n = self.n
        n.ram['A']['1:14'] = 0          # os dois gastam os 2 Antidotes
        n.ram['B']['1:14'] = 0
        n.ram['A']['1:14'] = 1          # A gastou 1, B gastou 2 ao mesmo tempo
        n.sync()
        self.assertNotIn('1:14', n.official())
        self.assertNotIn('1:14', n.ram['A'])
        self.assertNotIn('1:14', n.ram['B'])
        self.assertTrue(any('1:14' in line for line in n.host.log.values()))

    def test_ct020_consumable_tm_has_one_stock(self):
        n = Net({'4:289': 1}, {})
        n.join_guest()
        n.ram['A']['4:289'] = 0
        n.sync()
        self.assertNotIn('4:289', n.ram['B'])

    def test_repeated_operation_is_applied_once(self):
        n = self.n
        n.ram['B']['3:4'] += 2
        ops = n.L.diff(n.cli['B'], n.lt(n.ram['B']), None)
        wire = n.L.encodeOp(ops[1])
        self.assertEqual(n.L.apply(n.host, 'B', n.L.decodeOp(wire))[0], 'ok')
        self.assertEqual(n.L.apply(n.host, 'B', n.L.decodeOp(wire))[0], 'dup')
        self.assertEqual(n.official()['3:4'], 12)

    def test_guest_first_join_adds_its_bag(self):
        n = Net({'3:4': 10, 'M': 1000}, {'3:4': 2, '1:13': 1, 'M': 300})
        n.join_guest()                  # foto completa com merge: o convidado ainda não escreve por cima da própria bolsa
        self.assertEqual(n.ram['B']['3:4'], 12)
        n.sync()
        self.assertEqual(n.official(), {'3:4': 12, '1:13': 1, 'M': 1300})
        self.assertEqual(n.ram['A'], n.official())
        n.join_guest()                  # segunda entrada: não soma de novo
        n.sync()
        self.assertEqual(n.official()['3:4'], 12)

    def test_ct030_reconnect_resends_lost_operations_once(self):
        n = self.n
        n.ram['B']['3:4'] -= 4
        n.L.diff(n.cli['B'], n.lt(n.ram['B']), None)    # operação gerada, conexão caiu antes de chegar
        text = n.L.serialize(n.host)
        n.host = n.L.deserialize(text)                   # anfitrião reiniciou a partir do arquivo de sessão
        n.join_guest()                                   # reenvia a pendente
        pend = n.L.unacked(n.cli['B'])
        for i in range(1, len(pend) + 1):
            self.assertEqual(n.L.apply(n.host, 'B', n.L.decodeOp(n.L.encodeOp(pend[i])))[0], 'dup')   # reenvio duplicado
        n.deliver('A'); n.deliver('B')
        self.assertEqual(n.ram['A']['3:4'], 6)
        self.assertEqual(n.ram['B']['3:4'], 6)

    def test_serialize_roundtrip_keeps_claims_and_merged(self):
        n = self.n
        n.ram['A']['1:13'] += 1
        n.send_ops('A', {'1:13': 0x40})
        back = n.L.deserialize(n.L.serialize(n.host))
        self.assertEqual(n.L.serialize(back), n.L.serialize(n.host))
        self.assertTrue(back.merged['B'])

    def test_limits(self):
        n = self.n
        n.ram['A']['M'] = 2_000_000
        n.ram['A']['3:4'] = 5000
        n.sync()
        self.assertEqual(n.ram['B']['M'], 999999)
        self.assertEqual(n.ram['B']['3:4'], 999)

    def test_bad_packets_are_refused(self):
        L = self.n.L
        for bad in ['DPO00000x3:4.....+000001----', 'DPO0000019:4.....+000001----', 'XYZ', 'DPO000001M.......*000001----']:
            self.assertIsNone(L.decodeOp(bad), bad)


if __name__ == '__main__':
    unittest.main()
