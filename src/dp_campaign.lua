-- Espelho da campanha em RAM. Campos privados (equipe, PC, nome, opções e
-- posição) nunca fazem parte do documento compartilhado.
local M={}
function M.new(memory,layout)
    local c={memory=memory,layout=layout,baseline=nil,revision=-1}
    function c:read()
        local sb1,sb2=self.layout.blocks();if not sb1 then return nil end
        local out={inventory=self.layout.readBag(),flags={},vars={},dex={seen={},owned={}}}
        local flagBytes={}
        for flag in pairs(self.layout.flags) do
            local index=flag//8
            if flagBytes[index]==nil then flagBytes[index]=self.memory:read8(sb1+self.layout.flagOffset+index) end
            out.flags[flag]=(flagBytes[index]&(1<<(flag%8)))~=0
        end
        for var in pairs(self.layout.vars) do out.vars[var]=self.memory:read16(sb1+self.layout.varOffset+(var-0x4000)*2) end
        for i=0,self.layout.dexBytes-1 do
            out.dex.owned[i]=self.memory:read8(sb2+self.layout.ownedOffset+i)
            out.dex.seen[i]=self.memory:read8(sb2+self.layout.seenOffset+i)
        end
        return out
    end
    function c:diff(current)
        if not self.baseline then return nil end
        local delta={inventory={},flags={},vars={},dex={seen={},owned={}}};local changed=false
        local keys={};for k in pairs(current.inventory) do keys[k]=true end
        for k in pairs(self.baseline.inventory) do keys[k]=true end
        for k in pairs(keys) do
            local d=(current.inventory[k] or 0)-(self.baseline.inventory[k] or 0)
            if d~=0 then delta.inventory[k]=d;changed=true end
        end
        for k,v in pairs(current.flags) do if self.baseline.flags[k]~=v then delta.flags[k]=v;changed=true end end
        for k,v in pairs(current.vars) do if self.baseline.vars[k]~=v then delta.vars[k]=v;changed=true end end
        for _,which in ipairs({'seen','owned'}) do for k,v in pairs(current.dex[which]) do
            local added=v&(~(self.baseline.dex[which][k] or 0))&255
            if added~=0 then delta.dex[which][k]=added;changed=true end
        end end
        return changed and delta or nil
    end
    function c:apply(document,revision)
        if revision<self.revision then return false,'stale_snapshot' end
        if not self.layout.safe() then return false,'unsafe' end
        local sb1,sb2=self.layout.blocks();if not sb1 then return false,'save_not_loaded' end
        self.layout.writeBag(document.inventory)
        local bytes,previous={},{}
        for flag,value in pairs(document.flags) do
            if self.layout.flags[flag] then
                local address=sb1+self.layout.flagOffset+flag//8;local mask=1<<(flag%8)
                if bytes[address]==nil then bytes[address]=self.memory:read8(address);previous[address]=bytes[address] end
                bytes[address]=value and (bytes[address]|mask) or (bytes[address]&(~mask)&255)
            end
        end
        for address,byte in pairs(bytes) do if byte~=previous[address] then self.memory:write8(address,byte) end end
        for var,value in pairs(document.vars) do
            if self.layout.vars[var] then self.memory:write16(sb1+self.layout.varOffset+(var-0x4000)*2,value) end
        end
        local national=self.layout.nationalFlag or 0x840
        if self.layout.nationalMagicOffset and document.flags[national]~=nil then
            -- o jogo confere também o valor mágico da Pokédex, não apenas a flag do sistema
            self.memory:write8(sb2+self.layout.nationalMagicOffset,document.flags[national] and (self.layout.nationalMagicValue or 0xb9) or 0)
        end
        for i=0,self.layout.dexBytes-1 do
            local seen=(document.dex.seen[i] or 0)|self.memory:read8(sb2+self.layout.seenOffset+i)
            local owned=(document.dex.owned[i] or 0)|self.memory:read8(sb2+self.layout.ownedOffset+i)
            self.memory:write8(sb2+self.layout.seenOffset+i,seen)
            self.memory:write8(sb2+self.layout.ownedOffset+i,owned)
            for _,offset in ipairs(self.layout.seenCopies) do self.memory:write8(sb1+offset+i,seen) end
        end
        self.revision=revision;self.baseline=self:read();return true
    end
    return c
end
return M
