-- Propriedade da equipe independente dos seis slots físicos do FireRed.
-- O adaptador deve carregar os slots necessários; nunca truncar a equipe
-- de seis de cada jogador para caber na RAM de uma batalha individual.
local P={}
local function clone(t)
    if type(t)~='table' then return t end
    local out={};for k,v in pairs(t) do out[k]=clone(v) end;return out
end
function P.new(participants,profiles)
    assert(#participants==2,'two_players_required')
    local state={players={},active={},slots={},captures={}}
    for side,owner in ipairs(participants) do
        local profile=assert(profiles[owner],'profile_required')
        assert(type(profile.party)=='table' and #profile.party<=6,'invalid_party')
        state.players[owner]={party=clone(profile.party),side=side,changed={}}
    end
    return state
end
function P.bind(state,physical,owner,index)
    assert(physical>=0 and physical<6 and physical%1==0,'invalid_physical_slot')
    local player=assert(state.players[owner],'not_participant')
    assert(index>=1 and index<=#player.party and index%1==0,'invalid_private_slot')
    for slot,binding in pairs(state.slots) do
        if slot~=physical and binding.owner==owner and binding.index==index then error('pokemon_already_loaded') end
    end
    state.slots[physical]={owner=owner,index=index}
    return player.party[index]
end
function P.commitSlot(state,physical,raw)
    local binding=assert(state.slots[physical],'unbound_slot')
    assert(type(raw)=='string' and #raw==100,'invalid_native_pokemon')
    local player=state.players[binding.owner]
    player.party[binding.index]=raw;player.changed[binding.index]=true
end
function P.activate(state,battler,owner,index)
    assert(battler==0 or battler==2,'invalid_player_battler')
    local p=assert(state.players[owner],'not_participant')
    assert((p.side==1 and battler==0) or (p.side==2 and battler==2),'wrong_battler_owner')
    assert(p.party[index],'invalid_private_slot')
    state.active[battler]={owner=owner,index=index}
end
function P.canSelect(state,owner,index)
    local p=state.players[owner];if not p or not p.party[index] then return false end
    for _,active in pairs(state.active) do
        if active.owner==owner and active.index==index then return false end
    end
    return true
end
function P.capture(state,owner,uid,raw)
    assert(state.players[owner],'not_participant')
    assert(type(uid)=='string' and type(raw)=='string' and #raw==100,'invalid_capture')
    if state.captures[uid] then return false,'already_captured' end
    state.captures[uid]={owner=owner,raw=raw};return true
end
function P.result(state,owner)
    local player=assert(state.players[owner],'not_participant')
    local captures={}
    for uid,mon in pairs(state.captures) do if mon.owner==owner then captures[uid]=mon.raw end end
    return {party=clone(player.party),changed=clone(player.changed),captures=captures}
end
return P
