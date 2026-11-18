-- Autoridade da campanha. Independente de emu/socket: nenhum efeito é autorizado
-- antes de reservar TODOS os recursos e confirmar os dois participantes.
local S = {}
local function copy(t)
    if type(t) ~= 'table' then return t end
    local r = {}; for k,v in pairs(t) do r[k] = copy(v) end; return r
end
local function integer(n) return type(n)=='number' and n==math.floor(n) end
local function identifier(id) return type(id)=='string' and #id>0 and #id<=128 and not id:find(':',1,true) end
local function resourceKey(k)
    if k=='M' or k=='C' then return true end
    if type(k)~='string' then return false end
    local pocket,n=k:match('^([1-5]):(%d+)$')
    return pocket~=nil and tonumber(n)>0 and tonumber(n)<1024
end
-- Faixas que dependem da família do jogo; o runtime chama S.configure com as do perfil.
S.config={flagMax=0x8ff,rewardFlags={{0x20,0x4ff},{0x500,0x7ff},{0x820,0x829}}}
function S.configure(config)
    for k,v in pairs(config or {}) do S.config[k]=v end
end
-- flag que marca uma recompensa única (item do mapa, item escondido, treinador vencido, insígnia)
function S.isReward(flag)
    for _,r in ipairs(S.config.rewardFlags) do if flag>=r[1] and flag<=r[2] then return true end end
    return false
end
function S.new(id, inventory)
    assert(type(id)=='string' and #id>0)
    return {schema=1,id=id,revision=0,nextBattle=0,inventory=copy(inventory or {}),
        flags={},vars={},dex={seen={},owned={}},claims={},claimEpochs={},receipts={},players={},battle=nil,history={}}
end
function S.player(s,id,profile)
    assert(identifier(id) and type(profile)=='table')
    if not s.players[id] then
        local count=0;for _ in pairs(s.players) do count=count+1 end
        assert(count<2,'session_full')
    end
    local p=copy(profile); p.connected=true; p.safe=profile.safe==true
    p.usable=profile.usable or 0; s.players[id]=p
end
-- id estável persiste no cliente ANTES de enviar: reconectar/repetir não duplica.
-- Uma transação inválida não produz gasto parcial nem marca a recompensa.
function S.transact(s,player,id,changes,claim)
    if not identifier(player) or not identifier(id) or type(changes)~='table' then return {ok=false,reason='invalid'} end
    if claim~=nil and (type(claim)~='string' or #claim==0 or #claim>256) then return {ok=false,reason='invalid_claim'} end
    local key=player..':'..id
    if s.receipts[key] then return copy(s.receipts[key]) end
    if not s.players[player] or not s.players[player].connected then return {ok=false,reason='offline'} end
    if claim and s.claims[claim] then return {ok=false,reason='claimed'} end
    local nextValues=copy(s.inventory)
    for resource,delta in pairs(changes or {}) do
        if not resourceKey(resource) or not integer(delta) then return {ok=false,reason='invalid'} end
        local limit=resource=='M' and 999999 or (resource=='C' and 9999 or 999)
        local amount=(nextValues[resource] or 0)+delta
        if amount<0 or amount>limit then return {ok=false,reason='insufficient_or_full',resource=resource} end
        nextValues[resource]=amount>0 and amount or nil
    end
    s.inventory=nextValues; if claim then s.claims[claim]=key end
    s.revision=s.revision+1
    local receipt={ok=true,revision=s.revision,id=key}
    s.receipts[key]=receipt
    return copy(receipt)
end
function S.reserve(s,player,id,resource)
    if not resourceKey(resource) then return {ok=false,reason='invalid_resource'} end
    if not identifier(player) or not identifier(id) then return {ok=false,reason='invalid'} end
    local existing=s.receipts[player..':'..id]
    if existing and (existing.kind~='reservation' or existing.resource~=resource) then return {ok=false,reason='request_id_reused'} end
    local receipt=S.transact(s,player,id,{[resource]=-1})
    if receipt.ok then
        local original=s.receipts[player..':'..id]
        if original.kind and (original.kind~='reservation' or original.resource~=resource) then
            return {ok=false,reason='request_id_reused'}
        end
        original.kind='reservation';original.resource=resource
    end
    return receipt
end
function S.refund(s,player,id,reservation)
    if not identifier(player) or not identifier(id) or not identifier(reservation) or id==reservation then return {ok=false,reason='invalid'} end
    local original=s.receipts[player..':'..reservation]
    if not original or original.kind~='reservation' then return {ok=false,reason='unknown_reservation'} end
    if original.refund and original.refund~=id then return {ok=false,reason='already_refunded'} end
    local existing=s.receipts[player..':'..id]
    if existing and (existing.kind~='refund' or existing.reservation~=reservation) then return {ok=false,reason='request_id_reused'} end
    local receipt=S.transact(s,player,id,{[original.resource]=1})
    if receipt.ok then
        original.refund=id;s.receipts[player..':'..id].kind='refund';s.receipts[player..':'..id].reservation=reservation
    end
    return receipt
end
-- Variáveis de cena NÃO são contadores monotônicos: 3 -> 0 pode ser correto.
-- CAS impede um cliente atrasado de desfazer o evento que acabou de chegar.
function S.progress(s,player,id,expected,flags,vars)
    if not identifier(player) or not identifier(id) then return {ok=false,reason='invalid'} end
    local key=player..':'..id
    if s.receipts[key] then return copy(s.receipts[key]) end
    if expected~=s.revision then return {ok=false,reason='stale',revision=s.revision} end
    if not s.players[player] or not s.players[player].connected then return {ok=false,reason='offline'} end
    for n,v in pairs(flags or {}) do
        if not integer(n) or n<0 or n>S.config.flagMax or type(v)~='boolean' then return {ok=false,reason='invalid_flag'} end
    end
    for n,v in pairs(vars or {}) do
        if not integer(n) or n<0x4000 or n>0x40ff or not integer(v) or v<0 or v>65535 then
            return {ok=false,reason='invalid_var'}
        end
    end
    for n,v in pairs(flags or {}) do s.flags[n]=v end
    for n,v in pairs(vars or {}) do s.vars[n]=v end
    s.revision=s.revision+1
    local r={ok=true,revision=s.revision};s.receipts[key]=r;return copy(r)
end
-- Evento completo da campanha: inventário, flags e cenas entram na mesma revisão.
-- Bolsa e Pokédex são somas/uniões e valem sobre o estado atual mesmo quando o cliente estava uma revisão atrás
-- (rejeitar o evento inteiro perdia o que o jogador realmente fez). Só o impossível é ajustado: gasto além do estoque
-- para em zero (a unidade já foi gasta pelo parceiro), ganho para no limite, ganho de item já reivindicado não entra.
-- Flags e variáveis de cena mantêm a proteção contra cliente atrasado, chave a chave: só entram se ninguém as mudou
-- depois da revisão que o cliente viu. Dados inválidos continuam rejeitando o evento inteiro.
local function limitOf(resource) return resource=='M' and 999999 or (resource=='C' and 9999 or 999) end
function S.event(s,player,id,expected,delta)
    if not identifier(player) or not identifier(id) or type(delta)~='table' then return {ok=false,reason='invalid'} end
    local receiptKey=player..':'..id
    if s.receipts[receiptKey] then return copy(s.receipts[receiptKey]) end
    if not integer(expected) or expected>s.revision then return {ok=false,reason='stale',revision=s.revision} end
    if not s.players[player] or not s.players[player].connected then return {ok=false,reason='offline'} end
    if type(delta.inventory or {})~='table' or type(delta.flags or {})~='table' or type(delta.vars or {})~='table' then
        return {ok=false,reason='invalid'}
    end
    if delta.claim~=nil and (type(delta.claim)~='string' or #delta.claim==0 or #delta.claim>256) then return {ok=false,reason='invalid_claim'} end
    for resource,amount in pairs(delta.inventory or {}) do
        if not resourceKey(resource) or not integer(amount) then return {ok=false,reason='invalid'} end
    end
    for n,v in pairs(delta.flags or {}) do
        if not integer(n) or n<0 or n>S.config.flagMax or type(v)~='boolean' then return {ok=false,reason='invalid_flag'} end
    end
    for n,v in pairs(delta.vars or {}) do
        if not integer(n) or n<0x4000 or n>0x40ff or not integer(v) or v<0 or v>65535 then return {ok=false,reason='invalid_var'} end
    end
    local staged=copy(s)
    staged.keyRevisions=staged.keyRevisions or {flags={},vars={}}
    local late=expected<s.revision
    local accepted={flags={},vars={}};local ignored={}
    for n,v in pairs(delta.flags or {}) do
        if late and (staged.keyRevisions.flags[n] or 0)>expected then ignored[#ignored+1]='flag/'..n
        else accepted.flags[n]=v end
    end
    for n,v in pairs(delta.vars or {}) do
        if late and (staged.keyRevisions.vars[n] or 0)>expected then ignored[#ignored+1]='var/'..n
        else accepted.vars[n]=v end
    end
    local gain=false;for _,amount in pairs(delta.inventory or {}) do if amount>0 then gain=true end end
    local rewards={};local alreadyClaimed=false;staged.claimEpochs=staged.claimEpochs or {}
    if delta.claim and staged.claims[delta.claim] then alreadyClaimed=true end
    for flag,on in pairs(accepted.flags) do
        if S.isReward(flag) then
            if on and gain then
                local claim='flag/'..flag..'/'..(staged.claimEpochs[flag] or 0)
                if s.flags[flag] or staged.claims[claim] then alreadyClaimed=true else rewards[#rewards+1]=claim end
            elseif on==false and staged.flags[flag] then
                staged.claimEpochs[flag]=(staged.claimEpochs[flag] or 0)+1
            end
        end
    end
    local adjusted={}
    for resource,amount in pairs(delta.inventory or {}) do
        if amount>0 and alreadyClaimed then
            adjusted[resource]=0           --a recompensa já foi entregue a alguém: o ganho repetido não entra
        else
            local current=staged.inventory[resource] or 0
            local value=math.max(0,math.min(limitOf(resource),current+amount))
            if value~=current+amount then adjusted[resource]=value-current end
            staged.inventory[resource]=value>0 and value or nil
        end
    end
    for n,v in pairs(accepted.flags) do
        if staged.flags[n]~=v then staged.keyRevisions.flags[n]=s.revision+1 end
        staged.flags[n]=v
    end
    for n,v in pairs(accepted.vars) do
        if staged.vars[n]~=v then staged.keyRevisions.vars[n]=s.revision+1 end
        staged.vars[n]=v
    end
    if not alreadyClaimed then
        for _,claim in ipairs(rewards) do staged.claims[claim]=receiptKey end
        if delta.claim then staged.claims[delta.claim]=receiptKey end
    end
    for _,which in ipairs({'seen','owned'}) do
        local bytes=delta.dex and delta.dex[which] or {}
        if type(bytes)~='table' then return {ok=false,reason='invalid_dex'} end
        for at,value in pairs(bytes) do
            if not integer(at) or at<0 or at>=52 or not integer(value) or value<0 or value>255 then
                return {ok=false,reason='invalid_dex'}
            end
            staged.dex[which][at]=(staged.dex[which][at] or 0)|value
        end
    end
    staged.revision=s.revision+1
    local receipt={ok=true,revision=staged.revision,id=receiptKey}
    if next(adjusted) then receipt.adjusted=adjusted end
    if #ignored>0 then receipt.ignored=ignored end
    if alreadyClaimed then receipt.claimed=true end
    staged.receipts[receiptKey]=receipt
    for k in pairs(s) do s[k]=nil end
    for k,v in pairs(staged) do s[k]=v end
    return copy(receipt)
end
function S.requestBattle(s,initiator,request,enemies,kind)
    if not identifier(initiator) or not identifier(request) then return nil,'invalid_request' end
    if kind~='wild' and kind~='trainer' and kind~='gym' and kind~='special' then return nil,'invalid_battle_kind' end
    if s.battle then
        if s.battle.request==request and s.battle.initiator==initiator then return copy(s.battle) end
        return nil,'battle_busy'
    end
    local ids={};for id,p in pairs(s.players) do
        if not p.connected then return nil,'partner_offline' end
        if p.usable<1 then return nil,'no_usable_pokemon' end
        ids[#ids+1]=id
    end
    table.sort(ids)
    if #ids~=2 or not s.players[initiator] then return nil,'two_players_required' end
    if type(enemies)~='table' or #enemies<2 or #enemies>6 then return nil,'enemy_roster_required' end
    local identities={}
    for _,enemy in ipairs(enemies) do
        if type(enemy)~='table' or type(enemy.uid)~='string' or identities[enemy.uid]
            or not integer(enemy.species) or enemy.species<1 or enemy.species>411 then
            return nil,'distinct_instances_required'
        end
        identities[enemy.uid]=true
    end
    s.nextBattle=s.nextBattle+1
    s.battle={id=s.id..'/'..s.nextBattle,request=request,initiator=initiator,
        participants=ids,kind=kind,phase='preparing',ready={},turn=0,actions={},
        enemies=copy(enemies),captures={},positions={},checkpoint=nil}
    return copy(s.battle)
end
function S.ready(s,id,player,position)
    local b=s.battle;local p=s.players[player]
    if b and b.id==id and b.phase=='committed' and b.ready[player] then return true,'committed' end
    if not b or b.id~=id or b.phase~='preparing' or not p then return false,'stale_battle' end
    local member=false;for _,who in ipairs(b.participants) do if who==player then member=true end end
    if not member then return false,'not_participant' end
    if not p.connected or not p.safe or p.usable<1 then return false,'unsafe' end
    b.ready[player]=true;b.positions[player]=copy(position)
    for _,who in ipairs(b.participants) do if not b.ready[who] then return true,'waiting' end end
    b.phase='committed';return true,'committed'
end
function S.action(s,id,turn,player,action)
    local b=s.battle
    if not b or b.id~=id or b.phase~='committed' or b.turn~=turn then return false,'stale_turn' end
    local allowed=false;for _,who in ipairs(b.participants) do if who==player then allowed=true end end
    if not allowed or not s.players[player].connected then return false,'not_participant' end
    if b.actions[player] then return false,'already_chosen' end
    if type(action)~='table' then return false,'invalid_action' end
    b.actions[player]=copy(action);return true
end
-- Só o resolvedor nativo autoritativo chama este ponto; efeitos não são
-- calculados separadamente pelos clientes (mesmo RNG, mesmo resultado).
function S.commitTurn(s,id,checkpoint)
    local b=s.battle;if not b or b.id~=id or b.phase~='committed' then return false end
    for _,who in ipairs(b.participants) do
        if s.players[who].usable>0 and not b.actions[who] then return false end
    end
    b.checkpoint=checkpoint;b.turn=b.turn+1;b.actions={};s.revision=s.revision+1;return true
end
function S.capture(s,id,player,target,pokemon)
    local b=s.battle
    if not b or b.id~=id or b.phase~='committed' or b.kind~='wild' then return false,'invalid_battle' end
    local member=false;for _,who in ipairs(b.participants) do if who==player then member=true end end
    if not member then return false,'not_participant' end
    local mon=b.enemies[target]
    if not mon or mon.removed or b.captures[target] then return false,'target_unavailable' end
    if type(pokemon)~='table' or pokemon.uid~=mon.uid or pokemon.species~=mon.species then return false,'wrong_identity' end
    b.captures[target]={owner=player,pokemon=copy(pokemon)};mon.removed=true
    local number=mon.nationalDex or mon.species
    if number>=1 and number<=386 then
        local at=(number-1)//8;local bit=1<<((number-1)%8)
        s.dex.seen[at]=(s.dex.seen[at] or 0)|bit;s.dex.owned[at]=(s.dex.owned[at] or 0)|bit
    end
    return true
end
function S.disconnect(s,player)
    if s.players[player] then s.players[player].connected=false end
    if s.battle and s.battle.phase~='paused' then s.battle.resumePhase=s.battle.phase;s.battle.phase='paused' end
end
function S.resume(s,id)
    local b=s.battle;if not b or b.id~=id or b.phase~='paused' then return false end
    for _,who in ipairs(b.participants) do if not s.players[who].connected then return false end end
    b.phase=b.resumePhase or 'preparing';b.resumePhase=nil;return true
end
function S.finish(s,id,outcome)
    local b=s.battle;if not b or b.id~=id or b.phase~='committed' then return nil,'invalid_battle' end
    local result={id=id,outcome=outcome,captures=copy(b.captures),positions=copy(b.positions),participants=copy(b.participants)}
    s.history[id]=result;s.battle=nil;s.revision=s.revision+1;return copy(result)
end
S.copy=copy
return S
