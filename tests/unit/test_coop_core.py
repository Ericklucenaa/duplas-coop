"""Validação final dos modelos Lua reais (Lua 5.4 via lupa)."""
from pathlib import Path
import tempfile
import unittest

from lupa import lua54

ROOT = Path(__file__).resolve().parents[2]


class CoopCore(unittest.TestCase):
    def setUp(self):
        self.lua = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().SRC = str(ROOT / "src").replace("\\", "/")
        self.lua.execute("""
            S=dofile(SRC..'/dp_session.lua');W=dofile(SRC..'/dp_wire.lua')
            P=dofile(SRC..'/dp_party.lua');E=dofile(SRC..'/dp_encounters.lua')
            A=dofile(SRC..'/dp_authority.lua');C=dofile(SRC..'/dp_channel.lua')
            function campaign()
                local s=S.new('campaign',{['1:13']=1,M=1000})
                S.player(s,'A',{safe=true,usable=1,party={'A'}})
                S.player(s,'B',{safe=true,usable=1,party={'B'}})
                return s
            end
            function enemies() return {{uid='one',species=16},{uid='two',species=19}} end
            function battle(s)
                local b=assert(S.requestBattle(s,'A','request',enemies(),'wild'))
                assert(S.ready(s,b.id,'A',{map=1}));assert(S.ready(s,b.id,'B',{map=2}))
                return s.battle
            end
        """)

    def run_lua(self, code):
        self.lua.execute(code)

    def test_lua_files_compile(self):
        for path in (ROOT / "src").glob("*.lua"):
            with self.subTest(file=path.name):
                self.lua.globals().FILE = str(path).replace("\\", "/")
                self.run_lua("assert(loadfile(FILE))")

    def test_compat_fetches_live_core_after_context_change(self):
        self.run_lua("""
            local adapter={memory={}}
            local function core(n)
                return {n=n,read32=function(self) return self.n end,getGameCode=function() return 'BPRE' end}
            end
            adapter._core=core(1)
            local proxy=dofile(SRC..'/dp_compat.lua').wrap(adapter)
            assert(proxy:read32(0)==1 and proxy:getGameCode()=='AGB-BPRE')
            adapter._core=core(2);collectgarbage()
            assert(proxy:read32(0)==2)
        """)

    def test_storage_budget_does_not_expand_network_budget(self):
        self.run_lua("""
            local disk=W.new({MAX_BYTES=4*1024*1024})
            local value=string.rep('a',W.MAX_BYTES+1)
            assert(not pcall(W.encode,value))
            local bytes=disk.encode(value);assert(disk.decode(bytes)==value)
            assert(not pcall(W.decode,bytes))
        """)

    def test_one_potion_has_one_winner(self):
        self.run_lua("""
            local s=campaign()
            assert(S.reserve(s,'A','a','1:13').ok)
            assert(not S.reserve(s,'B','b','1:13').ok)
            assert(s.inventory['1:13']==nil)
        """)

    def test_reservation_retry_and_refund_exactly_once(self):
        self.run_lua("""
            local s=campaign();assert(S.reserve(s,'A','a','1:13').ok)
            assert(S.reserve(s,'A','a','1:13').ok)
            assert(S.refund(s,'A','refund','a').ok)
            assert(S.refund(s,'A','refund','a').ok)
            assert(not S.refund(s,'A','other-refund','a').ok)
            assert(s.inventory['1:13']==1)
            assert(not S.reserve(s,'A','a','M').ok)
        """)

    def test_cannot_refund_someone_elses_reservation(self):
        self.run_lua("""
            local s=campaign();S.reserve(s,'A','a','1:13')
            assert(not S.refund(s,'B','refund','a').ok)
            assert(s.inventory['1:13']==nil)
        """)

    def test_failed_transaction_is_atomic(self):
        self.run_lua("""
            local s=campaign();local before=W.encode(s)
            local result=S.transact(s,'A','trade',{M=-100,['1:13']=-2})
            assert(not result.ok);assert(W.encode(s)==before)
        """)

    def test_pickup_cannot_repeat_even_for_same_player(self):
        self.run_lua("""
            local s=campaign();assert(S.transact(s,'A','a',{['1:13']=1},'pickup-12').ok)
            assert(not S.transact(s,'A','b',{['1:13']=1},'pickup-12').ok)
            assert(not S.transact(s,'B','c',{['1:13']=1},'pickup-12').ok)
            assert(s.inventory['1:13']==2)
        """)

    def test_scene_reset_and_stale_revision(self):
        self.run_lua("""
            local s=campaign();s.vars[0x4050]=3
            assert(S.progress(s,'A','a',0,{[0x820]=true},{[0x4050]=0}).ok)
            assert(s.vars[0x4050]==0 and s.flags[0x820])
            assert(not S.progress(s,'B','b',0,{}, {[0x4050]=3}).ok)
            assert(s.vars[0x4050]==0)
        """)

    def test_campaign_event_is_one_atomic_revision(self):
        self.run_lua("""
            local s=campaign()
            local event={inventory={['4:339']=1},flags={[0x820]=true},vars={[0x4050]=0},dex={seen={[0]=1}}}
            assert(S.event(s,'A','a',0,event).ok)
            assert(s.revision==1 and s.inventory['4:339']==1 and s.flags[0x820] and s.dex.seen[0]==1)
            assert(S.event(s,'A','a',0,event).ok and s.revision==1)
            local before=W.encode(s)
            assert(not S.event(s,'A','b',1,{inventory={M=10},vars={[0x4050]=-1}}).ok)
            assert(W.encode(s)==before)
        """)

    def test_npc_tm_reward_is_unique_and_respawn_gets_new_epoch(self):
        self.run_lua("""
            local s=campaign()
            local delta={inventory={['4:289']=1},flags={[0x231]=true}}
            assert(S.event(s,'A','reward1',0,delta).ok)
            local again=S.event(s,'B','reward2',1,delta)
            assert(again.ok and again.claimed)   -- aceito sem o ganho: a recompensa continua única
            assert(s.inventory['4:289']==1)
            assert(S.event(s,'A','reset',1,{flags={[0x231]=false}}).ok)
            assert(S.event(s,'B','respawn',2,delta).ok)
            assert(s.inventory['4:289']==2)
        """)

    def test_late_event_keeps_what_the_player_did(self):
        # o parceiro mudou a campanha enquanto o evento estava a caminho: bolsa é soma, vale sobre o estado atual
        self.run_lua("""
            local s=campaign();s.inventory['1:13']=2;s.inventory['4:289']=1
            assert(S.event(s,'A','host-tm',0,{inventory={['4:289']=-1}}).ok and s.revision==1)
            local r=S.event(s,'B','guest',0,{inventory={['4:289']=-1,['1:13']=-1}})
            assert(r.ok, r.reason)
            assert(s.inventory['4:289']==nil, 'o último TM vale uma vez')
            assert(s.inventory['1:13']==1, 'a Potion dada para segurar sai da bolsa mesmo com o evento atrasado')
            assert(r.adjusted and r.adjusted['4:289']==0, 'o gasto sem estoque é registrado como ajustado')
        """)

    def test_late_event_does_not_undo_scene_changed_by_partner(self):
        self.run_lua("""
            local s=campaign();s.vars[0x4050]=1
            assert(S.event(s,'A','advance',0,{vars={[0x4050]=2}}).ok)
            local r=S.event(s,'B','stale',0,{vars={[0x4050]=1,[0x4051]=5},flags={[0x230]=true}})
            assert(r.ok and s.vars[0x4050]==2, 'cena avançada pelo parceiro não volta')
            assert(s.vars[0x4051]==5 and s.flags[0x230], 'o que ninguém mexeu entra normalmente')
            assert(r.ignored and r.ignored[1]=='var/'..0x4050)
        """)

    def test_event_from_the_future_or_offline_is_refused(self):
        self.run_lua("""
            local s=campaign()
            assert(not S.event(s,'A','future',5,{inventory={M=1}}).ok)
            S.disconnect(s,'B')
            assert(not S.event(s,'B','offline',0,{inventory={M=1}}).ok)
        """)

    def test_battle_requires_partner_and_usable_team(self):
        self.run_lua("""
            local s=campaign();S.disconnect(s,'B')
            assert(not S.requestBattle(s,'A','a',enemies(),'wild'))
            S.player(s,'B',{safe=true,usable=0})
            assert(not S.requestBattle(s,'A','b',enemies(),'wild'))
        """)

    def test_battle_requests_arbitrate_and_wait_for_both(self):
        self.run_lua("""
            local s=campaign();local b=assert(S.requestBattle(s,'A','a',enemies(),'wild'))
            assert(not S.requestBattle(s,'B','b',enemies(),'trainer'))
            assert(S.ready(s,b.id,'A',{map=1}));assert(s.battle.phase=='preparing')
            assert(S.ready(s,b.id,'B',{map=2}));assert(s.battle.phase=='committed')
            assert(S.ready(s,b.id,'B',{map=2}))
        """)

    def test_repeated_disconnect_preserves_resume_phase(self):
        self.run_lua("""
            local s=campaign();local b=battle(s)
            S.disconnect(s,'A');S.disconnect(s,'B');assert(b.resumePhase=='committed')
            S.player(s,'A',{usable=1,safe=true});assert(not S.resume(s,b.id))
            S.player(s,'B',{usable=1,safe=true});assert(S.resume(s,b.id));assert(b.phase=='committed')
        """)

    def test_two_private_captures_same_turn(self):
        self.run_lua("""
            local s=campaign();local b=battle(s)
            assert(S.capture(s,b.id,'A',1,{uid='one',species=16}))
            assert(not S.capture(s,b.id,'B',1,{uid='one',species=16}))
            assert(S.capture(s,b.id,'B',2,{uid='two',species=19}))
            assert(s.battle.phase=='committed')
            local result=S.finish(s,b.id,7)
            assert(result.captures[1].owner=='A' and result.captures[2].owner=='B')
            assert(result.positions.A.map==1 and result.positions.B.map==2)
        """)

    def test_both_actions_required_before_turn_commit(self):
        self.run_lua("""
            local s=campaign();local b=battle(s)
            assert(S.action(s,b.id,0,'A',{kind='move',move=1}))
            assert(not S.commitTurn(s,b.id,'checkpoint'))
            assert(S.action(s,b.id,0,'B',{kind='move',move=2}))
            assert(S.commitTurn(s,b.id,'checkpoint'));assert(b.turn==1)
            assert(not S.action(s,b.id,0,'A',{kind='move',move=1}))
        """)

    def test_full_private_teams_survive_physical_slot_rotation(self):
        self.run_lua("""
            local a,b={},{};for i=1,6 do a[i]=string.rep(string.char(64+i),100);b[i]=string.rep(string.char(96+i),100) end
            local state=P.new({'A','B'},{A={party=a},B={party=b}})
            P.bind(state,0,'A',1);P.bind(state,1,'B',1);P.activate(state,0,'A',1);P.activate(state,2,'B',1)
            P.bind(state,2,'A',6);P.commitSlot(state,2,string.rep('X',100))
            assert(#P.result(state,'A').party==6 and #P.result(state,'B').party==6)
            assert(P.result(state,'A').party[6]==string.rep('X',100))
            assert(P.result(state,'B').party[6]==b[6]);assert(not P.canSelect(state,'A',1))
            assert(P.canSelect(state,'A',6))
            assert(not pcall(P.activate,state,2,'A',2))
        """)

    def test_wild_species_and_ivs_generated_independently(self):
        self.run_lua("""
            local provider={table=function() return {{species=16,min=3,max=8},{species=19,min=3,max=8}},{50,50} end,
                create=function(mon) return mon end}
            local mixed=false;local differentIV=false
            for seed=1,100 do
                local pair=assert(E.pair({battleId='b'..seed,kind='grass',otid=1234},provider,E.rng(seed)))
                assert(pair[1].uid~=pair[2].uid and pair[1].ivs~=pair[2].ivs)
                if pair[1].species~=pair[2].species then mixed=true end
                if W.encode(pair[1].ivs)~=W.encode(pair[2].ivs) then differentIV=true end
            end
            assert(mixed and differentIV)
        """)

    def test_unique_encounter_is_not_silently_cloned(self):
        self.run_lua("""
            local pair,err=E.pair({special=true}, {}, E.rng(1))
            assert(pair==nil and err=='special_encounter_configuration_required')
        """)

    def test_wire_binary_roundtrip_and_rejection(self):
        self.run_lua(r"""
            local payload={bytes='\0\255\128',negative=-1234567890,zero=0,yes=true,no=false,[0]='zero'}
            assert(W.encode(W.decode(W.encode(payload)))==W.encode(payload))
            for _,bytes in ipairs({'','s\0\0\0\5a','m\255\255\255\255','ttrailing'}) do assert(not pcall(W.decode,bytes)) end
            local cycle={};cycle.a=cycle;assert(not pcall(W.encode,cycle))
        """)

    def test_authority_publishes_only_after_durable_save(self):
        self.run_lua("""
            local store={fail=false,load=function() return nil,'not_found' end,
                save=function(self,data) if self.fail then return false,'disk full' end;self.saved=W.encode(data);return true end}
            local a=assert(A.open(S,store,'session',{M=100}))
            assert(a:dispatch('A',{kind='join',profile={usable=1,safe=true}}).ok)
            store.fail=true
            assert(not a:dispatch('A',{kind='inventory',id='a',changes={M=-10}}).ok)
            assert(a.state.inventory.M==100 and not a.state.receipts['A:a'])
            store.fail=false
            assert(a:dispatch('A',{kind='inventory',id='a',changes={M=-10}}).ok)
            assert(a.state.inventory.M==90 and W.decode(store.saved).inventory.M==90)
        """)

    def test_battle_command_discriminator_does_not_replace_battle_kind(self):
        self.run_lua("""
            local store={load=function() return nil,'not_found' end,save=function() return true end}
            local a=assert(A.open(S,store,'session',{}))
            a:dispatch('A',{kind='join',profile={usable=1,safe=true}})
            a:dispatch('B',{kind='join',profile={usable=1,safe=true}})
            local result=a:dispatch('A',{kind='battle',id='a',enemies=enemies(),battleKind='gym'})
            assert(result.ok and result.battle.kind=='gym')
        """)

    def test_channel_requires_pairing_and_handles_fragmentation(self):
        self.run_lua(r"""
            local received={};local ready=false
            local c=C.new(W,{localId='A',peerId='B',token='0123456789abcdef',onReady=function() ready=true end,
                onMessage=function(m) received[#received+1]=m end})
            c.socket={close=function() end}
            local function frame(message) local bytes=W.encode(message);return string.pack('>I4',#bytes)..bytes end
            local bytes=frame({kind='hello',version=1,id='B',peer='A',token='0123456789abcdef'})
            for i=1,#bytes do assert(c:feed(bytes:sub(i,i),1)) end
            assert(ready and c.authenticated)
            assert(c:feed(frame({kind='test',payload='\0\255'}),2))
            assert(#received==1 and received[1].payload=='\0\255')
        """)

    def test_wrong_peer_and_oversized_frame_are_rejected(self):
        self.run_lua("""
            local c=C.new(W,{localId='A',peerId='B',token='0123456789abcdef'})
            c.socket={close=function() end}
            local bytes=W.encode({kind='hello',version=1,id='C',peer='A',token='0123456789abcdef'})
            assert(not c:feed(string.pack('>I4',#bytes)..bytes,1));assert(not c.socket)
            c.socket={close=function() end};assert(not c:feed(string.pack('>I4',W.MAX_BYTES+1),2))
        """)

    def test_partial_send_backpressure_and_timeout(self):
        self.run_lua("""
            local sent='';local c=C.new(W,{localId='A',peerId='B',token='0123456789abcdef',timeout=10})
            c.socket={send=function(_,bytes) local n=math.min(3,#bytes);sent=sent..bytes:sub(1,n);return n end,
                receive=function() return nil,'again' end,close=function() end}
            c.authenticated=true;assert(c:send({kind='test',n=1}));c:tick(1,'again')
            assert(c.queued==0 and #c.tx==0 and W.decode(sent:sub(5)).n==1)
            c:tick(12,'again');assert(not c.socket)
        """)

    def test_store_recovers_previous_checkpoint(self):
        with tempfile.TemporaryDirectory(prefix="phoenix-coop-") as directory:
            self.lua.globals().STATE_PATH = str(Path(directory) / "session.bin").replace("\\", "/")
            self.run_lua("""
                local store=dofile(SRC..'/dp_store.lua').new(STATE_PATH,W)
                assert(store:save({schema=1,n=1}));assert(store:save({schema=1,n=2}))
                local f=assert(io.open(STATE_PATH,'wb'));f:write('corrupt');f:close()
                local state,source=store:load();assert(state.n==1 and source==STATE_PATH..'.bak')
            """)


if __name__ == "__main__":
    unittest.main()
