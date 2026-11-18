-- Reserva da última unidade antes de ela valer. Suspende a CPU no ponto de entrada, mas deixa os quadros do emulador
-- e o canal de rede funcionando (não gira em Lua esperando resposta). Dois pontos:
--   1. efeito de item em Pokémon (ExecuteTableBasedItemEffect: remédios, vitaminas): reservado antes do efeito;
--   2. retirada da bolsa (RemoveBagItem: TM ensinado, item dado para segurar, item jogado/vendido): reservado antes de
--      sair da bolsa. Se o anfitrião recusar (o parceiro gastou a última), a unidade não sai e o efeito que o jogo acabou
--      de aplicar no Pokémon é desfeito (item segurado e golpes voltam ao que eram antes de entrar no menu).
local emu=DP_EMU or emu
local M={}
function M.new(native,config)
    local r={native=native,config=config,pending=nil,approved=nil,approvedRemove=nil,hooks={},credits={},covered={},snapshot=nil}
    local P=DP_ADDR or dofile(DP_DIR..'/dp_profile.lua')
    local ENTRY=P.itemEffect
    local REMOVE=P.removeBagItem
    local SPIN=P.spin
    local function signed(v) return v>0x7fffffff and v-0x100000000 or v end
    function r:registers(entry)
        local out={};for i=0,14 do out[i]=emu:readRegister('r'..i) end
        out.pc=entry;out.cpsr=emu:readRegister('cpsr');return out
    end
    function r:restore(registers)
        if registers.cpsr then emu:writeRegister('cpsr',signed(registers.cpsr)) end
        for i=0,14 do emu:writeRegister('r'..i,signed(registers[i])) end
        emu:writeRegister('pc',registers.pc)
    end
    -- equipe como estava antes de o jogador entrar no menu (o runtime chama com o jogador livre no mapa)
    function r:observe()
        if self.pending then return end
        self.snapshot=native.read(native.PARTY,600)
    end
    -- desfaz, nos Pokémon do próprio jogador, o efeito de uma retirada recusada
    function r:undo(p)
        local snap=p.snapshot;if not snap then return 0 end
        local fixed=0
        for slot=0,5 do
            local current=native.read(native.PARTY+slot*100,100)
            local pid,ot=string.unpack('<I4I4',current)
            if pid~=0 then
                for s=0,5 do
                    local old=snap:sub(s*100+1,s*100+100)
                    local opid,oot=string.unpack('<I4I4',old)
                    if opid==pid and oot==ot then
                        local fc,fo=DPDecodeBytes(current),DPDecodeBytes(old)
                        local changed=false
                        if fc.item~=fo.item then fc.item=fo.item;changed=true end
                        for m=0,3 do
                            if fc.moves[m]~=fo.moves[m] then
                                for k=0,3 do fc.moves[k]=fo.moves[k];fc.pp[k]=fo.pp[k] end
                                changed=true;break
                            end
                        end
                        if changed then native.write(native.PARTY+slot*100,DPEncodeMon(fc));fixed=fixed+1 end
                        break
                    end
                end
            end
        end
        return fixed
    end
    function r:complete(id,result)
        local p=self.pending;if not p or p.id~=id then return false end
        self.pending=nil;self:restore(p.registers)
        local remove=p.kind=='remove'
        if result.ok then
            if remove then self.approvedRemove=p else self.approved=p;self.covered[p.key]=(self.covered[p.key] or 0)+1 end
            self.credits[p.key]=(self.credits[p.key] or 0)-1
            local returnAddress=p.registers[14]&0xfffffffe
            local returnHook
            returnHook=emu:setBreakpoint(function()
                if emu:readRegister('sp')~=p.registers[13] then return end
                emu:clearBreakpoint(returnHook)
                -- remédio: 0 = efeito aplicado; RemoveBagItem: 1 = retirado. Falhou: devolve a unidade reservada.
                local failed=remove and emu:readRegister('r0')==0 or (not remove and emu:readRegister('r0')~=0)
                if failed then
                    self.credits[p.key]=(self.credits[p.key] or 0)+1
                    if not remove then self.covered[p.key]=math.max(0,(self.covered[p.key] or 1)-1) end
                    self.config.refund(p.id,p.key)
                elseif remove then
                    self.snapshot=native.read(native.PARTY,600)   --o efeito aprovado vira a nova base
                end
            end,returnAddress)
        else
            if remove then
                local fixed=self:undo(p)
                emu:writeRegister('r0',0)                       --a unidade não sai da bolsa
                if self.config.denied then self.config.denied(p.key,fixed) end
            else
                emu:writeRegister('r0',1)
            end
            emu:writeRegister('pc',p.registers[14]&0xfffffffe)
        end
        return true
    end
    function r:adjust(delta)
        for key,amount in pairs(self.credits) do
            if amount~=0 then
                delta.inventory[key]=(delta.inventory[key] or 0)-amount
                if delta.inventory[key]==0 then delta.inventory[key]=nil end
            end
        end
        self.credits={};self.covered={}
    end
    local function pocketOf(item)
        -- o número de bolso da tabela de itens segue a ordem do jogo; a bolsa compartilhada usa a ordem do save
        local pocket=emu:read8(P.itemsTable+44*item+26)
        if pocket<1 or pocket>5 then return nil end
        return P.layout.pocketFromTable and P.layout.pocketFromTable[pocket] or pocket
    end
    function r:install()
        local bytes=native.read(SPIN,2)
        assert(bytes=='\255\255' or bytes=='\254\231','native_reservation_cave_occupied')
        emu.memory.cart0:write16(SPIN-0x08000000,0xe7fe)
        self.hooks[1]=emu:setBreakpoint(function()
            if not self.config.active() then return end
            if self.approved then self.approved=nil;return end
            if self.pending then return end
            local item=emu:readRegister('r1')&65535
            local pocket=pocketOf(item);if not pocket then return end
            local id=self.config.nextId()
            self.pending={id=id,key=pocket..':'..item,registers=self:registers(ENTRY)}
            emu:writeRegister('pc',SPIN)
            self.config.reserve(id,self.pending.key)
        end,ENTRY)
        self.hooks[2]=emu:setBreakpoint(function()
            if not self.config.active() then return end
            if self.approvedRemove then self.approvedRemove=nil;return end
            if self.pending then return end
            local item=emu:readRegister('r0')&65535
            if (emu:readRegister('r1')&65535)~=1 then return end    --só a retirada de uma unidade disputa a última
            local pocket=pocketOf(item);if not pocket then return end
            local key=pocket..':'..item
            if (self.covered[key] or 0)>0 then self.covered[key]=self.covered[key]-1;return end   --já reservada (remédio)
            local id=self.config.nextId()
            self.pending={id=id,key=key,kind='remove',registers=self:registers(REMOVE),snapshot=self.snapshot}
            emu:writeRegister('pc',SPIN)
            self.config.reserve(id,key)
        end,REMOVE)
    end
    return r
end
return M
