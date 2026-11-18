-- Adaptador nativo da batalha em dupla: os endereços vêm do perfil da ROM (gerado pela ferramenta).
-- Os endereços são verificados no perfil; nenhum fallback para outra ROM.
local emu=DP_EMU or emu
local P=DP_ADDR or dofile(DP_DIR..'/dp_profile.lua')
local N={PARTY=P.party,ENEMY=P.enemyParty,COUNT=P.partyCount,
    INIT=P.cb2InitBattle,FLAGS=P.battleTypeFlags,IDLE=P.idle,HEADERS=P.wildHeaders}
local function read(address,n) return emu:readRange(address,n) end
local function write(address,bytes) for i=1,#bytes do emu:write8(address+i-1,bytes:byte(i)) end end
function N.install()
    assert(emu:read32(0x080000ac)==P.gameCode and emu:read8(0x080000bc)==P.revision,
        'esta ROM não corresponde ao perfil carregado ('..P.name..')')
    local bytes=read(N.IDLE,2)
    assert(bytes=='\255\255' or bytes=='\112\071','native idle cave occupied')
    emu.memory.cart0:write16(N.IDLE-0x08000000,0x4770) -- bx lr, retorna ao laço do emulador, sem girar CPU.
end
function N.blocks()
    local a,b=P.readSaveBlocks(emu)
    assert(a>=0x02000000 and a<0x02040000 and b>=0x02000000 and b<0x02040000,'save not loaded')
    return a,b
end
-- ID do treinador (público | secreto<<16), em sb2+0x0A. Não é múltiplo de 4: read32 ali lê a palavra alinhada e gira
-- os bytes (vinha o gênero no lugar do ID secreto), e os Pokémon do próprio jogador pareciam de outro treinador.
function N.trainerId(sb2) return emu:read16(sb2+10)|(emu:read16(sb2+12)<<16) end
function N.profile()
    local _,sb2=N.blocks();local count=emu:read8(N.COUNT);assert(count<=6,'invalid party count')
    local party,usable={},0
    for i=0,count-1 do
        local raw=read(N.PARTY+i*100,100);party[#party+1]=raw
        if emu:read16(N.PARTY+i*100+0x56)>0 and (emu:read8(N.PARTY+i*100+0x13)&4)==0 then usable=usable+1 end
    end
    local empty={};local storage=P.readStorage(emu)
    if storage>=0x02000000 and storage+0x83d0<=0x02040000 then
        for i=0,419 do if (emu:read8(storage+4+i*80+0x13)&2)==0 then empty[#empty+1]=4+i*80 end end
    end
    return {party=party,usable=usable,otid=N.trainerId(sb2),name=read(sb2,7),gender=emu:read8(sb2+8),
        freeStorage=empty,safe=DP.Free()}
end
function N.table(context)
    local sb=N.blocks();local group,map=context.group or emu:read8(sb+4),context.map or emu:read8(sb+5)
    local field=({grass=4,water=8,rock=12,old_rod=16,good_rod=16,super_rod=16})[context.kind]
    if not field then return nil end
    for index=0,1023 do
        local header=N.HEADERS+index*20
        if emu:read8(header)==255 then break end
        if emu:read8(header)==group and emu:read8(header+1)==map then
            local info=emu:read32(header+field);if info==0 then return nil end
            local ptr=emu:read32(info+4);local count=field==4 and 12 or (field==16 and 10 or 5)
            local first=0
            if context.kind=='old_rod' then count=2 elseif context.kind=='good_rod' then first=2;count=3
            elseif context.kind=='super_rod' then first=5;count=5 end
            local slots={};for i=first,first+count-1 do
                local p=ptr+i*4;slots[#slots+1]={min=emu:read8(p),max=emu:read8(p+1),species=emu:read16(p+2)}
            end
            return slots
        end
    end
end
function N.create(mon,rng,context)
    assert(DPDecodeMon and DPEncodeMon,'codec bridge missing')
    local g=gAddress[DPGameID()];local a=MPBattleAddress[DPGameID()]
    local base=g.gSpeciesInfo+28*mon.species
    local template=MPBuildMon({id=1,gender=0,double=0,name={0xff}},
        {species=mon.species,level=mon.level,iv=0},0,{hash=0},false)
    local f=DPDecodeMon(MPRawFromBytes(template))
    f.pers=mon.personality;f.otid=mon.otid;f.ivs=0
    for i=1,6 do f.ivs=f.ivs|(mon.ivs[i]<<((i-1)*5)) end
    if emu:read8(base+0x17)~=0 then f.ivs=f.ivs|((f.pers&1)<<31) else mon.abilitySlot=0 end
    local roll=rng:below(100);local common,rare=emu:read16(base+12),emu:read16(base+14)
    f.item=common==rare and common or (roll<5 and rare or (roll<55 and common or 0))
    local ratio=emu:read8(base+16)
    mon.gender=ratio==255 and 'none' or (ratio==254 and 'female' or ((f.pers&255)<ratio and 'female' or 'male'))
    local iv=mon.ivs;local level=mon.level
    f.maxhp=mon.species==303 and 1 or (((2*emu:read8(base)+iv[1])*level)//100+level+10);f.hp=f.maxhp
    f.stats={}
    local up,down=mon.nature//5,mon.nature%5
    for stat=0,4 do
        local value=((2*emu:read8(base+stat+1)+iv[stat+2])*level)//100+5
        if up~=down then if stat==up then value=value*110//100 elseif stat==down then value=value*90//100 end end
        f.stats[stat]=value
    end
    mon.raw=DPEncodeMon(f);mon.item=f.item;mon.moves=f.moves
    return mon
end
function N.gate()
    local g=gAddress[DPGameID()]
    if emu:read32(g.gMainCallback)==(N.INIT|1) then emu:write32(g.gMainCallback,N.IDLE|1);return true end
    return false
end
function N.release() emu:write32(gAddress[DPGameID()].gMainCallback,N.INIT|1) end
function N.freeze()
    local main=gAddress[DPGameID()].gMainCallback
    local previous={emu:read32(main-4),emu:read32(main)}
    emu:write32(main-4,N.IDLE|1);emu:write32(main,N.IDLE|1)
    return previous   --sem setKeys: ele fica gravado no emulador e contaminaria os botões reais do jogador
end
function N.unfreeze(previous)
    local main=gAddress[DPGameID()].gMainCallback
    emu:write32(main-4,previous[1]);emu:write32(main,previous[2])
end
function N.position()
    local sb=N.blocks();return {group=emu:read8(sb+4),map=emu:read8(sb+5),x=emu:read16(sb),y=emu:read16(sb+2)}
end
-- O plano escolhe destinos uma vez. Reaplicá-lo após crash escreve nos mesmos
-- slots; não chama uma segunda vez a operação "adicionar Pokémon".
function N.planResult(result,profile)
    local plan={party={},boxes={},captures={}}
    for i,raw in ipairs(result.party) do assert(#raw==100);plan.party[i]=raw end
    local free=1
    local keys={};for uid in pairs(result.captures) do keys[#keys+1]=uid end;table.sort(keys)
    for _,uid in ipairs(keys) do
        local f=DPDecodeBytes(result.captures[uid]);f.otid=profile.otid;f.ot={}
        for i=0,6 do f.ot[i]=profile.name:byte(i+1) or 255 end
        f.origins=(f.origins&0x7fff)|((profile.gender&1)<<15)
        local raw=DPEncodeMon(f);plan.captures[#plan.captures+1]={uid=uid,species=f.species,personality=f.pers}
        if #plan.party<6 then plan.party[#plan.party+1]=raw
        else
            local offset=profile.freeStorage[free];if not offset then return nil,'private_pc_full' end
            plan.boxes[#plan.boxes+1]={offset=offset,raw=raw:sub(1,80)};free=free+1
        end
    end
    return plan
end
function N.applyResult(plan)
    local storage=P.readStorage(emu)
    if #plan.boxes>0 then assert(storage>=0x02000000 and storage+0x83d0<=0x02040000,'invalid_storage_pointer') end
    for i=0,5 do write(N.PARTY+i*100,plan.party[i+1] or string.rep('\0',100)) end
    emu:write8(N.COUNT,#plan.party)
    for _,box in ipairs(plan.boxes) do
        assert(box.offset>=4 and box.offset<=4+419*80 and (box.offset-4)%80==0 and #box.raw==80)
        write(storage+box.offset,box.raw)
    end
    local sb1,sb2=N.blocks()
    for _,mon in ipairs(plan.captures or {}) do
        local number=N.National and N.National[mon.species]
        if number and number>=1 and number<=386 then
            local at=(number-1)//8;local bit=1<<((number-1)%8)
            for _,address in ipairs({sb2+0x28+at,sb2+0x5c+at,sb1+0x5f8+at,sb1+0x3a18+at}) do
                emu:write8(address,emu:read8(address)|bit)
            end
        end
    end
end
N.read=read;N.write=write
return N
