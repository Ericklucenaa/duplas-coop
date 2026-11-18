-- Driver do motor FireRed. Executa o cálculo original de dano, habilidades,
-- efeitos, IA e RNG; Lua só arbitra participantes, slots e propriedade.
local emu=DP_EMU or emu
local B={}
function B.new(native,partyModule,encounters,config)
    local b={native=native,parties=partyModule,encounters=encounters,config=config,hooks={},model=nil,
        running=false,menu=nil,input={[0]=0,[2]=0},fresh={[0]=0,[2]=0},uiBank=0,captured={},context=nil}
    local N=native
    local P=DP_ADDR or dofile(DP_DIR..'/dp_profile.lua')
    local A={active=P.activeBattler,indexes=P.battlerPartyIndexes,mons=P.battleMons,absent=P.absentFlags,
        attacker=P.attacker,target=P.target,instr=P.battlescriptPtr,outcome=P.battleOutcome,
        bufferA=P.battleBufferA,bufferB=P.battleBufferB,main=P.gMain,
        controllers=P.controllersTable,commands=P.commandsTable,script=P.battleScript}
    local function skip(result)
        if result~=nil then emu:writeRegister('r0',result) end
        emu:writeRegister('pc',emu:readRegister('lr')&0xfffffffe)
    end
    local function physical(raw) return DPEncodeMon(DPDecodeMon(raw)) end
    local function decoded(raw)
        local words={};for i=1,100,4 do words[#words+1]=string.format('%010d',string.unpack('<I4',raw,i)+1000000000) end
        return DPDecodeMon(table.concat(words))
    end
    local function usable(raw)
        return type(raw)=='string' and #raw==100 and string.unpack('<I2',raw,0x57)>0 and (raw:byte(0x14)&4)==0
    end
    function b:hook(address,fn)
        local id=emu:setBreakpoint(function()
            if self.running then fn() end
        end,address&0xfffffffe)
        assert(id and id>=0,'native_breakpoint_failed');self.hooks[#self.hooks+1]=id
    end
    function b:owner(bank) return self.order[bank==0 and 1 or 2] end
    function b:flush()
        if not self.model or self.menu then return end
        for slot in pairs(self.model.slots) do partyModule.commitSlot(self.model,slot,N.read(N.PARTY+100*slot,100)) end
    end
    function b:writeCombined()
        for slot=0,5 do
            local binding=self.model.slots[slot]
            N.write(N.PARTY+slot*100,binding and self.model.players[binding.owner].party[binding.index] or string.rep('\0',100))
        end
        emu:write8(N.COUNT,6)
    end
    function b:prepare(battle,profiles)
        if not emu.setBreakpoint then return false,'mgba_debug_api_required' end
        if not battle or #battle.participants~=2 then return false,'two_players_required' end
        self.order={battle.initiator}
        for _,who in ipairs(battle.participants) do if who~=battle.initiator then self.order[2]=who end end
        self.battle=battle;self.profiles=profiles
        self.model=partyModule.new(self.order,profiles)
        for side,owner in ipairs(self.order) do
            local indices={};for index,raw in ipairs(profiles[owner].party) do if usable(raw) then indices[#indices+1]=index end end
            if #indices==0 then return false,'no_usable_pokemon' end
            for index in ipairs(profiles[owner].party) do
                local found=false;for _,present in ipairs(indices) do if present==index then found=true end end
                if not found then indices[#indices+1]=index end
            end
            for i=1,math.min(3,#indices) do partyModule.bind(self.model,(i-1)*2+side-1,owner,indices[i]) end
            partyModule.activate(self.model,(side-1)*2,owner,indices[1])
        end
        self:writeCombined()
        for i=0,5 do N.write(N.ENEMY+i*100,battle.enemies[i+1] and battle.enemies[i+1].raw or string.rep('\0',100)) end
        emu:write8(P.enemyPartyCount,#battle.enemies)
        emu:write32(N.FLAGS,emu:read32(N.FLAGS)|1)
        self.captured={};self.menu=nil;return true
    end
    -- Obediência: o jogo compara o treinador original do Pokémon em campo (gBattleMons: ID em +0x54, nome em +0x3C)
    -- com o jogador DESTA máquina. O Pokémon do parceiro pareceria trocado e desobedeceria acima do limite das
    -- insígnias (no começo do jogo, qualquer um acima do nível 10). Quem pertence ao próprio dono passa a ter o
    -- jogador desta máquina como treinador só na cópia da batalha; a equipe não muda. Pokémon trocado de verdade
    -- (de outro treinador para o dono) continua trocado e obedece como no jogo normal.
    local function nameOf(bytes,size)
        local out={};for i=1,size do local c=bytes:byte(i);if not c or c==255 then break end;out[#out+1]=string.char(c) end
        return table.concat(out)
    end
    function b:adoptOwners()
        if not self.model or not self.profiles then return end
        local _,sb2=N.blocks()
        local localId=N.trainerId(sb2);local localName=emu:readRange(sb2,8)
        for _,bank in ipairs({0,2}) do
            local m=A.mons+bank*0x58
            local profile=emu:read16(m)~=0 and self.profiles[self:owner(bank)]
            if profile and emu:read32(m+0x54)~=localId and emu:read32(m+0x54)==profile.otid
                and nameOf(emu:readRange(m+0x3c,8),8)==nameOf(profile.name,7) then
                emu:write32(m+0x54,localId)
                for i=0,7 do emu:write8(m+0x3c+i,localName:byte(i+1)) end
            end
        end
    end
    function b:checkpoint()
        self:flush()
        return {machine=emu:saveStateBuffer(0),model=self.model,captured=self.captured,menu=self.menu,uiBank=self.uiBank}
    end
    function b:start() self.running=true;N.release() end
    function b:pause()
        if not self.running then return end
        if not self.pausedCallback then
            self.pausedCallback=N.freeze()
        end
    end
    function b:resume()
        if self.pausedCallback then N.unfreeze(self.pausedCallback);self.pausedCallback=nil end
    end
    function b:setInput(owner,mirror)
        self.fresh[0]=(owner&(~self.input[0]))&1023;self.fresh[2]=(mirror&(~self.input[2]))&1023
        self.input[0]=owner&1023;self.input[2]=mirror&1023
    end
    function b:injectInput(bank)
        if bank~=0 and bank~=2 then return end
        local held=self.input[bank];local fresh=self.fresh[bank]
        self.uiBank=bank
        for _,offset in ipairs({0x28,0x2c}) do emu:write16(A.main+offset,held) end
        for _,offset in ipairs({0x2a,0x2e,0x30}) do emu:write16(A.main+offset,fresh) end
    end
    function b:endInputFrame()
        -- fresh é calculado quando o próximo conjunto de entradas chega.
    end
    function b:openParty(bank)
        if self.menu or (bank~=0 and bank~=2) then return end
        self:flush()
        local owner=self:owner(bank);local p=self.model.players[owner]
        local active=emu:read16(A.indexes+2*bank);local binding=self.model.slots[active]
        if not binding or binding.owner~=owner then error('active_pokemon_owner_mismatch') end
        local map={[active]=binding.index};local cursor=1
        for slot=0,5 do if slot~=active then
            while cursor==binding.index do cursor=cursor+1 end
            if p.party[cursor] then map[slot]=cursor;cursor=cursor+1 end
        end end
        local other=bank~2
        self.menu={bank=bank,owner=owner,map=map,other=other,otherIndex=emu:read16(A.indexes+2*other)}
        for slot=0,5 do N.write(N.PARTY+100*slot,map[slot] and p.party[map[slot]] or string.rep('\0',100)) end
        emu:write8(N.COUNT,6)
        emu:write16(A.indexes+2*other,active)
    end
    function b:closeParty(bank)
        local menu=self.menu;if not menu or bank~=menu.bank then return end
        -- Só fechar depois de o controlador emitir a seleção de Pokémon.
        local buffer=A.bufferB+bank*512
        if emu:read8(buffer)~=0x22 then return end
        local selected=emu:read8(buffer+1)
        local p=self.model.players[menu.owner]
        for slot,index in pairs(menu.map) do p.party[index]=N.read(N.PARTY+slot*100,100) end
        self.menu=nil
        if selected<6 then
            local index=assert(menu.map[selected],'selection_outside_private_party')
            local physicalSlot
            for slot,binding in pairs(self.model.slots) do
                if binding.owner==menu.owner and binding.index==index then physicalSlot=slot end
            end
            if not physicalSlot then
                for slot=bank//2,5,2 do
                    if slot~=emu:read16(A.indexes+2*bank) then physicalSlot=slot;break end
                end
                assert(physicalSlot,'no_private_switch_slot');partyModule.bind(self.model,physicalSlot,menu.owner,index)
            end
            emu:write8(buffer+1,physicalSlot)
        end
        emu:write16(A.indexes+2*menu.other,menu.otherIndex)
        self:writeCombined()
    end
    function b:replenish()
        if not self.model or self.menu then return end
        self:flush()
        local activeSlots={[emu:read16(A.indexes)]=true,[emu:read16(A.indexes+4)]=true}
        for slot,binding in pairs(self.model.slots) do
            if not activeSlots[slot] and not usable(self.model.players[binding.owner].party[binding.index]) then
                local loaded={};for _,v in pairs(self.model.slots) do if v.owner==binding.owner then loaded[v.index]=true end end
                for index,raw in ipairs(self.model.players[binding.owner].party) do
                    if not loaded[index] and usable(raw) then
                        partyModule.bind(self.model,slot,binding.owner,index);N.write(N.PARTY+slot*100,raw);break
                    end
                end
            end
        end
    end
    function b:capture()
        local bank=emu:read8(A.attacker);local target=emu:read8(A.target)
        if (bank~=0 and bank~=2) or (target~=1 and target~=3) then error('invalid_capture_target') end
        local index=emu:read16(A.indexes+target*2)+1;local mon=self.battle.enemies[index]
        if not mon or self.captured[mon.uid] then error('capture_target_already_removed') end
        local raw=N.read(N.ENEMY+(index-1)*100,100)
        local owner=self:owner(bank)
        assert(partyModule.capture(self.model,owner,mon.uid,raw))
        self.captured[mon.uid]=owner
        emu:write16(A.mons+target*0x58+0x28,0)
        emu:write16(N.ENEMY+(index-1)*100+0x56,0)
        emu:write8(A.absent,emu:read8(A.absent)|(1<<target))
        local other=target~2
        if emu:read16(A.mons+other*0x58+0x28)==0 or (emu:read8(A.absent)&(1<<other))~=0 then emu:write8(A.outcome,7) end
        emu:write32(A.instr,A.script+1)
    end
    function b:install()
        assert(emu.setBreakpoint,'mGBA 0.11 debug API required')
        N.install()
        emu.memory.cart0:write8(A.script-0x08000000,0xf0)
        emu.memory.cart0:write8(A.script-0x08000000+1,0xf6)
        self:hook(P.battleEnemyCount,function() skip(#self.battle.enemies) end)
        self:hook(P.battleSkipRoutine,function() skip() end)
        self:hook(P.partyOtCheck,function()
            local pointer=emu:readRegister('r0')
            if pointer<N.PARTY or pointer>=N.PARTY+600 or (pointer-N.PARTY)%100~=0 then return end
            local slot=(pointer-N.PARTY)//100
            local binding=self.model.slots[slot]
            local owner=self.menu and self.menu.owner or (binding and binding.owner)
            if not owner then return end
            local f=DPDecodeBytes(N.read(pointer,100));local profile=self.profiles[owner]
            local name={};for i=0,6 do if f.ot[i]==255 then break end;name[#name+1]=string.char(f.ot[i]) end
            local expected=profile.name:match('^[^\255]*')
            skip(f.otid==profile.otid and table.concat(name)==expected and 0 or 1)
        end)
        self:hook(P.partyMenuHook,function()
            local slot=(emu:readRegister('r0')-N.PARTY)//100
            local binding=self.model.slots[slot]
            if binding then self.uiBank=binding.owner==self.order[1] and 0 or 2 end
        end)
        self:hook(emu:read32(A.controllers+25*4),function()
            local bank=emu:read8(A.active);local slot=emu:read8(A.bufferA+bank*512+1)
            local binding=self.model.slots[slot]
            if binding then self.uiBank=binding.owner==self.order[1] and 0 or 2 end
        end)
        for _,address in ipairs({P.ctrlActionInput,P.ctrlTargetInput,P.ctrlMoveInput}) do
            self:hook(address,function() self:injectInput(emu:read8(A.active)) end)
        end
        -- Comando 22 abre a equipe; a seleção devolvida é o comando 34.
        self:hook(emu:read32(A.controllers+22*4),function() self:openParty(emu:read8(A.active)) end)
        self:hook(emu:read32(A.controllers+21*4),function() self.uiBank=emu:read8(A.active) end)
        self:hook(P.battleCloseParty,function() self:closeParty(emu:read8(A.active)) end)
        self:hook(emu:read32(A.commands+0xf1*4),function()
            emu:write32(A.instr,A.script);skip()
        end)
        self:hook(emu:read32(A.commands+0xf0*4),function() self:capture();skip() end)
        self:hook(P.battleReplenish,function() self:replenish() end)
    end
    function b:result(owner)
        self:flush();return partyModule.result(self.model,owner)
    end
    function b:stop()
        self.running=false;self.pausedCallback=nil;self.menu=nil
    end
    b.decode=decoded;b.addresses=A
    return b
end
return B
