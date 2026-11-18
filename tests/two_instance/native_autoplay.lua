-- Duas máquinas reais. O roteiro só dirige botões e inicia um encontro por
-- bytecode nativo; cálculos, controladores, golpes e conclusão são do jogo.
local ROLE,OUT=assert(COOP_ROLE),assert(COOP_OUT)
local frame=0
local function log(message)
    local f=assert(io.open(OUT..'/'..ROLE..'.log','a'))
    f:write(string.format('[%06d] %s\n',frame,message));f:close()
end
local here=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
log('INITIAL script loaded')
DP_GBAPK=COOP_GBAPK;DP_DATA=COOP_DATA
DP_TRACE=OUT..'/'..ROLE..'-loader.log'
DP_EMU=dofile(here..'/../../src/dp_compat.lua').wrap(emu)
local machine=DP_EMU
DP_ADDR=DP_ADDR or dofile(here..'/../../src/dp_profile.lua')   --perfil antes de tudo (o boot já usa endereços)
local P=DP_ADDR
log('COMPAT ready')
local initialized=false
local function boot()
local ok,err=pcall(dofile,here..'/../../src/iniciar-coop-nativo.lua')
log('LOAD '..tostring(ok)..' '..tostring(err or ''))
if not ok then return end
local emu=DP_EMU or emu
local originalLog=DP.Log
function DP.Log(message) originalLog(message);log(message) end
local R=DP.Runtime
local P=DP_ADDR   --endereços do jogo (perfil): o mesmo roteiro serve para outras ROMs
local scenario=COOP_SCENARIO or 'wild'
local N=R.backend.native
local menuStarted=nil
local switched=false
local lastS0,lastS2=nil,nil
local actionAt=nil
local OWN_SPECIES=ROLE=='host' and {[1]=true,[4]=true,[7]=true,[25]=true,[16]=true,[19]=true}
    or {[152]=true,[155]=true,[158]=true,[27]=true,[29]=true,[32]=true}
if COOP_FIXTURE_TEAMS and not (COOP_GUEST_EMPTY and ROLE=='guest') then
    local sb1,sb2=N.blocks()
    if ROLE=='guest' then emu:write16(sb2+12,emu:read16(sb2+12)~0x1234) end   --outro ID secreto: outro treinador
    local profile=N.profile();local rng=dofile(here..'/../../src/dp_encounters.lua').rng(ROLE=='host' and 1234 or 9876)
    local species=ROLE=='host' and {1,4,7,25,16,19} or {152,155,158,27,29,32}
    for i,sp in ipairs(species) do
        local mon={uid='fixture/'..ROLE..'/'..i,species=sp,level=20,personality=rng:word(),ivs={},otid=profile.otid}
        for stat=1,6 do mon.ivs[stat]=rng:below(32) end;mon.nature=mon.personality%25
        local raw=N.create(mon,rng,{}).raw
        local f=DPDecodeBytes(raw);f.ot={};for j=0,6 do f.ot[j]=profile.name:byte(j+1) end
        if scenario=='switch' then f.moves[0]=45;f.pp[0]=40;f.moves[1]=57;f.pp[1]=15 end
        if scenario=='controls' then f.moves[0]=33;f.pp[0]=35;f.moves[1]=45;f.pp[1]=40 end
        N.write(N.PARTY+(i-1)*100,DPEncodeMon(f))
    end
    emu:write8(N.COUNT,6)
    local bag=DP.ReadBag();bag['3:1']=20;DP.WriteBag(bag)
    log('FIXTURE six private Pokemon otid='..profile.otid..' first='..species[1]..' sixth='..species[6])
end
if scenario=='gym' then
    local sb=N.blocks();local flag=0x820
    emu:write8(sb+DP.FLAGS+flag//8,emu:read8(sb+DP.FLAGS+flag//8)&(~(1<<(flag%8))))
end
if scenario=='reserve' then
    local bag=DP.ReadBag();bag['1:13']=1;DP.WriteBag(bag)
    emu:write16(N.PARTY+0x56,emu:read16(N.PARTY+0x58)-20)
    log('RESOURCE BEFORE hp='..emu:read16(N.PARTY+0x56)..' max='..emu:read16(N.PARTY+0x58))
end
if scenario=='race' then
    -- a última unidade de um TM e de uma Potion; o 4º golpe do 1º Pokémon é Tackle e ele não segura nada
    local bag=DP.ReadBag();bag['4:289']=1;bag['1:13']=1;DP.WriteBag(bag)
    local f=DPDecodeBytes(N.read(N.PARTY,100));f.item=0;f.moves[3]=33;f.pp[3]=35;N.write(N.PARTY,DPEncodeMon(f))
end
if scenario=='items' then
    -- última unidade de um TM para os dois e 2 Potions; nenhum Pokémon segura item
    local bag=DP.ReadBag();bag['4:289']=1;bag['1:13']=2;DP.WriteBag(bag)
    local f=DPDecodeBytes(N.read(N.PARTY,100));f.item=0;N.write(N.PARTY,DPEncodeMon(f))
end
local storeModule=dofile(here..'/../../src/dp_store.lua')
local wireModule=dofile(here..'/../../src/dp_wire.lua')
storeModule.new(OUT..'/before-'..ROLE..'.bin',wireModule):save({schema=1,profile=N.profile(),position=N.position(),bag=DP.ReadBag()})
if scenario=='controls' then
    R.LocalKeys=nil
    if ROLE=='host' then
        -- registro de cada toque novo que o jogo entrega a um lado da batalha (para achar toque no lado errado)
        local inject=R.backend.injectInput
        function R.backend.injectInput(self,bank)
            inject(self,bank)
            if (bank==0 or bank==2) and self.fresh[bank]~=0 then
                local m=P.battleMons+bank*0x58+0x24
                log(string.format('KEY bank=%d fresh=%x ctrl=%08x pp=%d,%d',bank,self.fresh[bank],
                    emu:read32(P.controllerFuncs+bank*4),emu:read8(m),emu:read8(m+1)))
            end
        end
    end
end
if scenario~='controls' then R.LocalKeys=function()
    -- COOP_IDLE: os dois ficam parados no menu da batalha por N quadros (como quem pensa no que fazer)
    if COOP_IDLE and R.view~=nil and (R.backend.running or R.view) then idleFrom=idleFrom or frame;if frame-idleFrom<COOP_IDLE then return 0 end end
    if scenario=='switch' then
        local bank=ROLE=='host' and 0 or 2
        local controller=emu:read32(P.controllerFuncs+bank*4)
        if menuStarted then
            local age=frame-menuStarted
            for _,at in ipairs({60,100,140,180,220}) do if age>=at and age<at+8 then return 128 end end   -- 8 quadros: o toque atravessa a rede
            if age>=260 then return age%40<8 and 1 or 0 end
            return 0
        end
        if controller==(P.ctrlActionInput|1) then
            -- menu de ação: sequência fixa contada a partir de quando ele aparece (baixo = POKéMON; cima = LUTAR)
            actionAt=actionAt or frame
            local age=frame-actionAt
            if age>=20 and age<24 then return switched and 64 or 128 end
            if age>=60 and age<64 then return 1 end
            if age>=120 then actionAt=nil end
            return 0
        end
        actionAt=nil
        if controller==(P.ctrlMoveInput|1) and switched then
            if frame%40<4 then return 16 end
            return (frame%40>=20 and frame%40<24) and 1 or 0
        end
        if controller~=(P.ctrlMoveInput|1) and controller~=(P.ctrlTargetInput|1) and controller~=(P.textController|1) then return 0 end
    end
    if scenario=='trainer' or scenario=='gym' or scenario=='reinforce' then
        local bank=ROLE=='host' and 0 or 2
        if emu:read32(P.controllerFuncs+bank*4)==(P.ctrlMoveInput|1) then
            if frame%40<4 then return 16 end -- selecionar o segundo golpe
            return (frame%40>=20 and frame%40<24) and 1 or 0
        end
    end
    return (frame%40<4) and 1 or 0
end end
local networkStarted=false
local triggered=false
local battleSeen=false
local previousMode=nil
local pairedAt=nil
local snapshotTaken=false
local disconnected=false
local returnedAt=nil
local resourceAt=nil
local resourceDone=false
local itemsAt=nil
local ctrlState,ctrlAt,ctrlRelease,ctrlStart,ctrlLast=nil,nil,nil,nil,nil
local raceAt=nil
local soloBattle,soloDone,soloHold,retriggered,freeSince=nil,nil,nil,nil,nil
local K=C.GBA_KEY
local function startWild()
    -- setwildbattle Pidgey(16), level 5; dowildbattle; end.
    local bytes={0,0xb6,16,0,5,0,0,0xb7,2}
    local base=gAddress[DPGameID()].gScriptData-0x08000000
    for i,value in ipairs(bytes) do emu.memory.cart0:write8(base+i-1,value) end
    LoadScriptIntoMemory('Data')
end
if COOP_SEPARATE_MAPS and ROLE=='guest' then
    local ptr=gAddress[DPGameID()].gScriptData
    local bytes=string.char(0,0x39,3,0,255)..string.pack('<I2I2',10,10)..string.char(2)
    for i=1,#bytes do emu.memory.cart0:write8(ptr-0x08000000+i-1,bytes:byte(i)) end
    LoadScriptIntoMemory('Data');log('FIXTURE native warp to Pallet Town')
end
local function startTrainer(id)
    local ptr=gAddress[DPGameID()].gScriptData
    local text=ptr+0x100
    local bytes=string.char(0,0x5c,3)..string.pack('<I2I2I4',id,0,text)
    if scenario=='gym' then bytes=bytes..string.char(0x29)..string.pack('<I2',0x820)
        ..string.char(0x44)..string.pack('<I2I2',289,1) end
    bytes=bytes..string.char(2)
    for i=1,#bytes do emu.memory.cart0:write8(ptr-0x08000000+i-1,bytes:byte(i)) end
    emu.memory.cart0:write8(text-0x08000000,255)
    LoadScriptIntoMemory('Data')
end
-- RemoveBagItem(item, 1) de verdade, chamado por uma rotina Thumb como callback2 (volta ao campo depois)
local REMOVE_STUB={16,181,6,72,1,33,6,76,0,240,6,248,5,73,6,72,8,96,16,188,1,188,0,71,32,71,0,191,68,51,34,17,217,161,9,8,244,48,0,3,181,101,5,8}
-- As rotinas de teste foram montadas para o FireRed 1.0: os endereços absolutos guardados nelas (literais de 4 bytes)
-- são trocados pelos do perfil antes de gravar, para o mesmo teste rodar em outra ROM.
local function relocate(code)
    local map={[0x02024284]=P.party,[0x080413c1]=P.itemEffect|1,[0x0809a1d9]=P.removeBagItem|1,
        [0x030030f4]=P.callback2,[0x080565b5]=P.cb2Overworld|1}
    local out={}
    local i=1
    while i<=#code do
        if (i-1)%4==0 and i+3<=#code then
            local w=string.unpack('<I4',code,i)
            if map[w] then out[#out+1]=string.pack('<I4',map[w]);i=i+4 goto continue end
        end
        out[#out+1]=code:sub(i,i);i=i+1
        ::continue::
    end
    return table.concat(out)
end
local function nativeRemove(item)
    local code=relocate(string.char(table.unpack(REMOVE_STUB)))
    for i=1,#code do emu.memory.cart0:write8((P.cave-0x08000000+0x180)+i-1,code:byte(i)) end
    emu.memory.cart0:write32((P.cave-0x08000000+0x180)+28,item)
    emu:write32(P.callback2,(P.cave+0x181))
end
local function startRemedy()
    local code=relocate(dofile(here..'/native_item_call.lua'))
    for i=1,#code do emu.memory.cart0:write8((P.cave-0x08000000+0x140)+i-1,code:byte(i)) end
    emu:write32(P.callback2,(P.cave+0x141))
    resourceAt=frame;log('RESOURCE native medicine entry')
end
if scenario=='trainer' or scenario=='gym' then
    emu:setBreakpoint(function()
        if not R.backend.running then return end
        local bank=emu:read8(P.activeBattler)
        if (bank==0 or bank==2) and (R.backend.fresh[bank]&1)~=0 then
            log(string.format('TARGET bank=%d cursor=%d absent=%x count=%d positions=%d,%d,%d,%d',bank,
                emu:read8((P.controllerFuncs+0x14)),emu:read8(P.absentFlags),emu:read8((P.activeBattler+8)),
                emu:read8((P.activeBattler+0x12)),emu:read8((P.activeBattler+0x13)),emu:read8((P.activeBattler+0x14)),emu:read8((P.activeBattler+0x15))))
        end
    end,P.ctrlTargetInput)
end
if scenario=='capture' then
    local function skip() emu:writeRegister('pc',emu:readRegister('lr')&0xfffffffe) end
    local function complete(bank,command,value)
        local base=P.battleBufferB+bank*512
        emu:write8(base,command);emu:write8(base+1,value);emu:write8(base+2,0);emu:write8(base+3,0)
        emu:write32(P.controllerFuncs+bank*4,(P.ctrlRunCommand|1))
        emu:write32((P.activeBattler+4),emu:read32((P.activeBattler+4))&(~(1<<bank)))
        skip()
    end
    emu:setBreakpoint(function()
        if not R.backend.running then return end
        local bank=emu:read8(P.activeBattler)
        if bank==0 or bank==2 then complete(bank,33,1);log('NATIVE action ball bank='..bank) end
    end,P.ctrlActionInput)
    emu:setBreakpoint(function()
        if not R.backend.running then return end
        local bank=emu:read8(P.activeBattler)
        if bank==0 or bank==2 then
            local bag=DP.ReadBag();bag['3:1']=(bag['3:1'] or 0)-1;DP.WriteBag(bag)
            complete(bank,35,1);log('NATIVE select Master Ball bank='..bank)
        end
    end,emu:read32(P.controllersTable+21*4)&0xfffffffe)
end
-- Menu que a TELA mostra. O parceiro só vê estados do anfitrião, congelados logo ao carregar (o callback principal
-- vira o de espera e IsInMenu responderia sempre 1): para ele vale o callback real do estado exibido.
local function telaMenu()
    if not (ROLE=='guest' and R.view and R.viewCallbacks) then return IsInMenu() end
    N.unfreeze(R.viewCallbacks);local menu=IsInMenu();N.freeze()   --na mesma chamada: o jogo não anda nenhum quadro
    return menu
end
callbacks:add('frame',function()
    if scenario=='switch' and R.mode=='battle' then
        -- O parceiro vê a máquina do host: o menu aberto só é deste jogador quando mostra a equipe dele.
        local mine=false
        if telaMenu()==3 then
            local ok,f=pcall(DPDecodeBytes,N.read(N.PARTY,100))
            mine=ok and f and OWN_SPECIES[f.species]==true
        end
        if mine and not menuStarted and not switched then menuStarted=frame;log('PARTY menu own team') end
        if menuStarted and frame-menuStarted==250 then emu:screenshot(OUT..'/'..ROLE..'-party.png') end
        if menuStarted and telaMenu()==2 and frame-menuStarted>260 then
            menuStarted=nil;switched=true;log('SWITCH chosen in own party menu')
        end
        -- espécie em campo de cada lado do jogador, a cada mudança (a troca acontece quando o turno é resolvido)
        local s0,s2=emu:read16(P.battleMons),emu:read16(P.battleMons+2*0x58)
        if telaMenu()==2 and (s0~=lastS0 or s2~=lastS2) then lastS0,lastS2=s0,s2;log('FIELD bank0='..s0..' bank2='..s2) end
    end
    if (scenario=='single' or scenario=='solo') and ROLE=='guest' then return end
    if scenario=='single' and frame>2600 and not networkStarted and DP.Free() then
        networkStarted=true;MPIni.mode='Free Roam';log('SINGLE player mode, no partner')
    end
    if (scenario=='single' or scenario=='solo') and ROLE=='host' then
        if not triggered and frame>3400 and DP.Free() then triggered=true;log('TRIGGER '..scenario);startWild() end
        -- depois de sair do cooperativo o jogador volta ao mapa: um novo encontro já é uma batalha individual
        -- (o encontro pendente pode recomeçar sozinho; só cria outro se o jogador ficar livre por 5 s sem batalha)
        if scenario=='solo' and soloHold and MPGameMode()~='Coop' and not soloBattle then
            if DP.Free() then freeSince=freeSince or frame else freeSince=nil end
            if not retriggered and freeSince and frame-freeSince>=300 then
                retriggered=frame;log('SOLO new encounter after leaving coop');startWild()
            end
        end
        if triggered and IsInMenu()==2 and not soloBattle then soloBattle=frame;log('SOLO battle running') end
        if soloBattle and not soloDone and IsInMenu()==0 and DP.Free() and frame-soloBattle>120 then
            soloDone=true;log('SOLO back to field mode='..tostring(MPGameMode())..' coopRequest='..tostring(R.request~=nil))
        end
        if scenario=='solo' and R.request and not soloHold then soloHold=frame;log('SOLO waiting for partner (frozen)') end
        if soloHold and frame-soloHold>=300 and frame-soloHold<420 then
            for _,k in ipairs({C.GBA_KEY.L,C.GBA_KEY.R,C.GBA_KEY.SELECT}) do machine:addKey(k) end
        elseif soloHold and frame-soloHold==420 then
            for _,k in ipairs({C.GBA_KEY.L,C.GBA_KEY.R,C.GBA_KEY.SELECT}) do machine:clearKey(k) end
        end
        if retriggered and (frame-retriggered==200 or frame-retriggered==600) then
            emu:screenshot(OUT..'/solo-'..(frame-retriggered)..'.png')
            log(string.format('SOLO probe cb1=%08x cb2=%08x lock=%d scriptLoad=%d flags=%08x',emu:read32(P.gMain),
                emu:read32(P.callback2),emu:read8(gAddress[DPGameID()].gLockControls),emu:read8(gAddress[DPGameID()].gScriptLoad),
                emu:read32(P.battleTypeFlags)))
        end
        if scenario=='single' then
            if R.request then log('SINGLE ERROR coop intercepted a single-player battle') end
            return
        end
    end
    if frame>2600 and not networkStarted and DP.Free() then
        storeModule.new(OUT..'/before-'..ROLE..'.bin',wireModule):save({schema=1,profile=N.profile(),position=N.position(),bag=DP.ReadBag()})
        MPIni.mode='Coop';MPIni.code=ROLE=='host' and 'PHX1' or 'PHX2'
        MPIni.partner=ROLE=='host' and 'PHX2' or 'PHX1'
        local connected,why=pcall(ROLE=='host' and host or connect)
        log('NET '..tostring(connected)..' '..tostring(why or ''))
        if connected then networkStarted=true end
    end
    if ROLE=='guest' and frame>3000 and frame%300==0 and not DPConnected() then pcall(connect) end
    if R.channel and R.channel.authenticated then pairedAt=pairedAt or frame end
    if pairedAt and frame-pairedAt>240 and not triggered and ROLE=='host' and DP.Free() then
        triggered=true;log('TRIGGER '..scenario)
        if scenario=='reinforce' then
            -- um treinador comum desta ROM com um único Pokémon (o modo Duplas precisa dar um reforço a ele)
            local a=MPBattleAddress[DPGameID()];local chosen
            for id=1,a.ntrainers-1 do
                local t=MPTrainerInfo(id)
                if t and t.size==1 and t.double==0 and t.class~=84 and t.class~=87 and t.class~=89 and t.class~=90 then chosen=id;break end
            end
            log('REINFORCE trainer='..tostring(chosen));startTrainer(chosen)
        elseif scenario=='trainer' then
            -- FireRed: o treinador 89 de sempre; outros jogos: o treinador comum de dois Pokémon mais fraco (o primeiro da
            -- tabela do Emerald tem nível 31 e a batalha não acabava a tempo contra a equipe de teste, de nível 20)
            local chosen=89
            if P.family~='FRLG' then
                local a=MPBattleAddress[DPGameID()];chosen=nil
                local best
                for id=1,a.ntrainers-1 do
                    local t=MPTrainerInfo(id)
                    if t and t.size==2 and t.double==0 then
                        local step=(t.flags&1)~=0 and 16 or 8   --com golpes próprios o registro de cada Pokémon tem 16 bytes
                        local top=0;for i=0,t.size-1 do top=math.max(top,emu:read16(t.party+i*step+2)) end
                        if not best or top<best then best,chosen=top,id end
                    end
                end
                log('TRAINER weakest two-Pokemon level='..tostring(best))
            end
            local f=assert(io.open(OUT..'/trainer-id','w'));f:write(tostring(chosen));f:close()
            log('TRAINER id='..tostring(chosen));startTrainer(chosen)
        elseif scenario=='gym' then startTrainer(414)
        elseif scenario=='items' or scenario=='race' then
            local signal=assert(io.open(OUT..'/resource-trigger','w'));signal:write('go');signal:close()
        elseif scenario=='reserve' then
            local signal=assert(io.open(OUT..'/resource-trigger','w'));signal:write('go');signal:close();startRemedy()
        else startWild() end
    end
    if scenario=='race' then
        -- os dois jogadores ao mesmo tempo: primeiro o último TM (golpe aprendido, depois a retirada nativa),
        -- depois a última Potion dada para segurar
        if ROLE=='guest' and not triggered and io.open(OUT..'/resource-trigger','r') then triggered=true end
        if triggered and not raceAt and DP.Free() then
            raceAt=frame
            local f=DPDecodeBytes(N.read(N.PARTY,100));f.moves[3]=92;f.pp[3]=10;N.write(N.PARTY,DPEncodeMon(f))
            nativeRemove(289);log('RACE tm taught, native removal')
        end
        if raceAt and frame-raceAt==600 then
            local f=DPDecodeBytes(N.read(N.PARTY,100))
            log('RACE tm result move4='..f.moves[3]..' stock='..tostring(DP.ReadBag()['4:289'] or 0))
        end
        if raceAt and frame-raceAt==700 then
            local f=DPDecodeBytes(N.read(N.PARTY,100));f.item=13;N.write(N.PARTY,DPEncodeMon(f))
            nativeRemove(13);log('RACE potion given, native removal')
        end
        if raceAt and frame-raceAt==1300 and DP.Free() then
            local bag=DP.ReadBag()
            log('RACE give result held='..DPDecodeBytes(N.read(N.PARTY,100)).item..' stock='..tostring(bag['1:13'] or 0))
            storeModule.new(OUT..'/after-'..ROLE..'.bin',wireModule):save({schema=1,profile=N.profile(),position=N.position(),bag=bag})
        end
    end
    if scenario=='items' and triggered and not itemsAt and (ROLE=='host' or io.open(OUT..'/resource-trigger','r')) then
        -- os dois gastam o último TM no mesmo instante; o convidado ainda dá uma Potion para o 1º Pokémon segurar
        itemsAt=frame
        local bag=DP.ReadBag();bag['4:289']=(bag['4:289'] or 0)-1;if bag['4:289']<=0 then bag['4:289']=nil end
        if ROLE=='guest' then
            bag['1:13']=(bag['1:13'] or 0)-1
            local f=DPDecodeBytes(N.read(N.PARTY,100));f.item=13;N.write(N.PARTY,DPEncodeMon(f))
        end
        DP.WriteBag(bag);log('ITEMS used last TM'..(ROLE=='guest' and ' and gave a Potion to hold' or ''))
    end
    if scenario=='items' and ROLE=='guest' and not triggered and io.open(OUT..'/resource-trigger','r') then triggered=true end
    if itemsAt and frame-itemsAt==900 and DP.Free() then
        storeModule.new(OUT..'/after-'..ROLE..'.bin',wireModule):save({schema=1,profile=N.profile(),position=N.position(),bag=DP.ReadBag()})
        local bag=DP.ReadBag()
        log('ITEMS RESULT tm='..tostring(bag['4:289'] or 0)..' potion='..tostring(bag['1:13'] or 0)
            ..' held='..DPDecodeBytes(N.read(N.PARTY,100)).item)
    end
    if scenario=='reserve' and ROLE=='guest' and not triggered and DP.Free() then
        local signal=io.open(OUT..'/resource-trigger','r')
        if signal then signal:close();triggered=true;startRemedy() end
    end
    if resourceAt and not resourceDone and frame-resourceAt>180 and DP.Free() and not R.reservations.pending then
        resourceDone=true
        storeModule.new(OUT..'/after-'..ROLE..'.bin',wireModule):save({schema=1,profile=N.profile(),position=N.position(),bag=DP.ReadBag()})
        log('RESOURCE RESULT hp='..emu:read16(N.PARTY+0x56)..' stock='..tostring(DP.ReadBag()['1:13'] or 0))
    end
    if R.mode=='battle' and not snapshotTaken and emu:read16(P.battleMons+0x58+0x28)>0
        and emu:read16(P.battleMons+3*0x58+0x28)>0 then
        snapshotTaken=true;emu:screenshot(OUT..'/'..ROLE..'-double.png')
        log('DOUBLE four battlers; both wild/enemy HP positive')
    end
    if scenario=='reconnect' and R.backend.running and not disconnected and snapshotTaken then
        disconnected=true;R.reconnectAt=frame+120;R.channel:drop('test_disconnect')
        log('TEST disconnected during battle')
    end
    if scenario=='busy' and ROLE=='guest' and pairedAt then
        -- o parceiro abre o menu de Pokémon (START, baixo, A) pouco antes de o anfitrião encontrar a batalha
        local t=frame-pairedAt
        local press={[100]=C.GBA_KEY.START,[140]=C.GBA_KEY.DOWN,[180]=C.GBA_KEY.A}
        if press[t] then emu:addKey(press[t]) elseif press[t-6] then emu:clearKey(press[t-6]) end
        if t==230 then log('BUSY party menu open menu='..IsInMenu()) end
        if returnedAt and frame-returnedAt==60 then log('BUSY returned menu='..IsInMenu()) end
        for _,at in ipairs({90,130,170,210}) do       --depois de conferir, fecha o menu para a foto final
            if returnedAt and frame-returnedAt==at then emu:addKey(C.GBA_KEY.B) end
            if returnedAt and frame-returnedAt==at+6 then emu:clearKey(C.GBA_KEY.B) end
        end
    end
    if scenario=='controls' and R.mode=='battle' then
        -- cada instância aperta botões de verdade (addKey), olhando só o menu do PRÓPRIO lado da batalha:
        -- anfitrião = LUTAR + 1º golpe; parceiro = LUTAR + 2º golpe (direita). Texto: o anfitrião aperta A de vez em quando.
        local bank=ROLE=='host' and 0 or 2
        local ctrl=emu:read32(P.controllerFuncs+bank*4)
        local want=nil
        if ctrl==(P.ctrlActionInput|1) then want='action' elseif ctrl==(P.ctrlMoveInput|1) then want='move' end
        if want~=ctrlState then ctrlState=want;ctrlAt=frame end
        local age=frame-(ctrlAt or frame)
        local press=nil
        if want=='action' and age==20 then press=C.GBA_KEY.A
        elseif want=='move' and ROLE=='guest' and age==20 then press=C.GBA_KEY.RIGHT
        elseif want=='move' and age==50 then press=C.GBA_KEY.A
        elseif not want and ROLE=='host' and frame%30==0 then press=C.GBA_KEY.A end   --o anfitrião aperta A o tempo todo, inclusive na vez do parceiro
        if press then emu:addKey(press);ctrlRelease=ctrlRelease or {};ctrlRelease[frame+8]=press end
        if ctrlRelease and ctrlRelease[frame] then emu:clearKey(ctrlRelease[frame]);ctrlRelease[frame]=nil end
        if ROLE=='host' then
            local function pp(b) local base=P.battleMons+b*0x58+0x24;return emu:read8(base)..','..emu:read8(base+1) end
            local turn=emu:read8((P.battleMons-2))
            if not ctrlStart and emu:read16(P.battleMons)>0 and emu:read16(P.battleMons+2*0x58)>0 then
                ctrlStart=true;log('CONTROLS start bank0='..pp(0)..' bank2='..pp(2))
            end
            if ctrlStart and turn>=1 and emu:read16(P.battleMons)>0 then ctrlLast=pp(0)..' bank2='..pp(2) end   --último PP visto em campo
        end
    end
    if R.mode~=previousMode then
        previousMode=R.mode;log('MODE '..tostring(R.mode))
        if R.mode=='battle' then battleSeen=true end
        if battleSeen and not R.mode and scenario=='controls' and ROLE=='host' and ctrlLast then log('CONTROLS end bank0='..ctrlLast) end
        if battleSeen and not R.mode then
            log('RETURNED battle='..tostring(R.lastResult)..' party='..emu:read8(P.partyCount))
            returnedAt=frame
            emu:screenshot(OUT..'/'..ROLE..'-return.png')
            local result=dofile(here..'/../../src/dp_store.lua').new(DP_DATA..'/resultado-'..(ROLE=='host' and 'PHX1' or 'PHX2')..'.bin',dofile(here..'/../../src/dp_wire.lua')):load()
            if result then log('RESULT captures='..#result.plan.captures..' party='..#result.plan.party..' boxes='..#result.plan.boxes) end
        end
    end
    if returnedAt and frame-returnedAt==600 and DP.Free() then
        storeModule.new(OUT..'/after-'..ROLE..'.bin',wireModule):save({schema=1,profile=N.profile(),position=N.position(),bag=DP.ReadBag()})
        log('AFTER snapshot saved')
    end
    if returnedAt and frame%60==0 and frame-returnedAt<=900 then
        local bag=DP.ReadBag() or {}
        log(string.format('SYNC rframe=%s auth=%s err=%s ball=%s rev=%s queued=%s pending=%s free=%s baseline=%s',
            tostring(R.frame),tostring(R.channel and R.channel.authenticated),tostring(R.error),tostring(bag['3:1']),
            tostring(R.campaign.revision),tostring(R.queuedSnapshot and R.queuedSnapshot.revision),tostring(R.pending and R.pending.id),
            tostring(DP.Free()),tostring(R.campaign.baseline and R.campaign.baseline.inventory['3:1'])))
    end
    if frame%120==0 and frame>2400 then
        local status=string.format('STATE game=%s menu=%s free=%s host=%s connected=%s role=%s paired=%s mode=%s error=%s',
            tostring(DPGameID()),tostring(IsInMenu()),tostring(DP.Free()),tostring(DPHosting()),tostring(DPConnected()),
            tostring(R.role),tostring(R.channel and R.channel.authenticated),tostring(R.mode),tostring(R.error))
        log(status)
        if not DP.Free() and DP.FreeParts and not R.mode then
            log('FREEPARTS '..tostring(select(2,pcall(DP.FreeParts))))
            if frame%1200==0 then emu:screenshot(OUT..'/'..ROLE..'-preso-'..frame..'.png') end
        end
        if R.backend.running then
            log(string.format('CTRL %08x %08x keys=%x,%x fresh=%x,%x attacker=%d absent=%x turn=%d',
                emu:read32(P.controllerFuncs),emu:read32((P.controllerFuncs+8)),R.backend.input[0],R.backend.input[2],
                R.backend.fresh[0],R.backend.fresh[2],emu:read8(P.attacker),emu:read8(P.absentFlags),emu:read8((P.battleMons-2))))
            if emu:read32(P.controllerFuncs)==(P.textController|1) then emu:screenshot(OUT..'/trainer-message.png') end
            if frame%600==0 then
                local t={}
                for b=0,3 do local m=P.battleMons+b*0x58
                    t[#t+1]=string.format('%d:sp%d hp%d/%d lv%d mv%d,%d',b,emu:read16(m),emu:read16(m+0x28),emu:read16(m+0x2c),emu:read8(m+0x2a),emu:read16(m+0x0c),emu:read16(m+0x0e)) end
                log('MONS '..table.concat(t,' | '))
            end
        end
        if R.mode=='battle' then emu:screenshot(OUT..'/'..ROLE..'-battle.png') end
    end
end)
end
local bootCallback
local startedInField=false
local presoDesde=nil
local apertandoA=false   --o A deste roteiro está apertado agora (para soltar se a batalha começar no meio)
bootCallback=callbacks:add('frame',function()
    local success,failure=pcall(function()
    frame=frame+1
    if frame==1 then log('FIRST frame') end
    if frame%600==0 then log('BOOTSTATE '..string.format('%08x',machine:read32(P.callback2))..' t='..os.time()) end
    -- tela de título (START, A, A) só quando o jogo não começou já no mapa (estado carregado com -t)
    if frame==1990 then startedInField=machine:read32(P.callback2)==(P.cb2Overworld|1) end
    if not startedInField then
        if frame==2000 then machine:addKey(C.GBA_KEY.START) end
        if frame==2005 then machine:clearKey(C.GBA_KEY.START) end
        if frame==2300 or frame==2400 then machine:addKey(C.GBA_KEY.A) end
        if frame==2305 or frame==2405 then machine:clearKey(C.GBA_KEY.A) end
    end
    -- A só quando algo prende o jogador (mensagem, aviso da conexão, resumo do "continuar"): apertar sempre fazia o
    -- personagem falar com o que estivesse na frente (no caminhão do Emerald, as caixas) e nunca ficar livre
    if frame>2500 and not (COOP_SCENARIO=='busy' and COOP_ROLE=='guest') then
        if not (DP and DP.Runtime and DP.Runtime.mode) then
            local livre=DP and DP.Free and DP.Free()
            if livre then presoDesde=nil else presoDesde=presoDesde or frame end
            if presoDesde and frame-presoDesde>=60 and frame%60<4 then machine:addKey(C.GBA_KEY.A);apertandoA=true
            elseif apertandoA then machine:clearKey(C.GBA_KEY.A);apertandoA=false end
        elseif apertandoA then
            -- a batalha começou no meio do toque: soltar, senão o A fica preso e nenhuma mensagem avança
            machine:clearKey(C.GBA_KEY.A);apertandoA=false;presoDesde=nil
        end
    end
    if not initialized and frame>2500 and machine:read32(P.callback2)==(P.cb2Overworld|1) then
        initialized=true;log('BOOT field ready');boot()
    end
    end)
    if not success then log('HARNESS ERROR '..tostring(failure));callbacks:remove(bootCallback) end
end)
