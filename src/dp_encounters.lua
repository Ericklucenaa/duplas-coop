-- Sorteio independente de encontros: nunca copia o primeiro Pokémon.
local E={}
E.weights={grass={20,20,10,10,10,10,5,5,4,4,1,1},water={60,30,5,4,1},rock={60,30,5,4,1},
    old_rod={70,30},good_rod={60,20,20},super_rod={40,40,15,4,1}}
function E.rng(seed)
    local r={state=seed & 0xffffffff}
    function r:next() self.state=(self.state*0x41c64e6d+0x6073)&0xffffffff;return self.state>>16 end
    function r:word() return (self:next()<<16)|self:next() end
    -- Rejection sampling, sem o viés de módulo na escolha das espécies.
    function r:below(n)
        assert(n>=1 and n<=65536 and n==math.floor(n))
        local limit=65536-(65536%n);local v
        repeat v=self:next() until v<limit
        return v%n
    end
    return r
end
function E.pick(slots,weights,rng)
    assert(#slots==#weights,'encounter_table_shape')
    local total=0;for i,w in ipairs(weights) do assert(w>0 and slots[i].species>0);total=total+w end
    local roll=rng:below(total)
    for i,w in ipairs(weights) do
        if roll<w then return slots[i] end;roll=roll-w
    end
end
function E.pair(context,provider,rng)
    if context.special then
        local rule=provider.special and provider.special(context)
        if not rule then return nil,'special_encounter_configuration_required' end
        return rule -- regras explícitas devem conservar a identidade dos únicos.
    end
    local slots,weights=provider.table(context)
    weights=weights or E.weights[context.kind]
    if not slots or not weights then return nil,'no_valid_encounter_table' end
    local result={}
    for index=1,2 do
        local slot=E.pick(slots,weights,rng)
        assert(slot.min>=1 and slot.max<=100 and slot.max>=slot.min)
        local level=slot.min+rng:below(slot.max-slot.min+1)
        local personality=rng:word();local iv={}
        for stat=1,6 do iv[stat]=rng:below(32) end
        local mon={uid=context.battleId..'/wild/'..index,species=slot.species,level=level,
            personality=personality,nature=personality%25,ivs=iv,otid=context.otid,
            abilitySlot=personality&1}
        mon.shiny=(((context.otid>>16)~(context.otid&65535)~(personality>>16)~(personality&65535))<8)
        -- A fábrica do motor calcula gênero, habilidade válida, golpes, itens
        -- e estatísticas conforme a espécie, mapa e regras reais da ROM.
        result[index]=provider.create(mon,rng,context)
        assert(result[index] and result[index].uid==mon.uid,'factory_must_keep_instance_identity')
    end
    return result
end
return E
