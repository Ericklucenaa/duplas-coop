-- Integração de campanha e batalha nativa. O host é o único resolvedor;
-- durante a batalha o parceiro recebe estados para visualização e fornece
-- comandos do seu battler. Sua máquina particular fica guardada separadamente.
local emu=DP_EMU or emu
local DIR=DP_DIR
local P=DP_ADDR or dofile(DIR..'/dp_profile.lua')
local Wire=dofile(DIR..'/dp_wire.lua')
local StorageWire=Wire.new({MAX_BYTES=8*1024*1024,MAX_NODES=500000,MAX_DEPTH=32})
local Session=dofile(DIR..'/dp_session.lua')
local Store=dofile(DIR..'/dp_store.lua')
local Authority=dofile(DIR..'/dp_authority.lua')
local Channel=dofile(DIR..'/dp_channel.lua')
local Campaign=dofile(DIR..'/dp_campaign.lua')
local Party=dofile(DIR..'/dp_party.lua')
local Encounters=dofile(DIR..'/dp_encounters.lua')
local N=dofile(DIR..'/dp_native.lua')
local NativeBattle=dofile(DIR..'/dp_native_battle.lua')
local Reservations=dofile(DIR..'/dp_reservations.lua')
N.National=dofile(DIR..'/dp_species.lua')
local Banner=dofile(DIR..'/dp_banner.lua')
-- Avisos da batalha em dupla (o jogo fica parado nesses momentos e não pode abrir a própria caixa de texto)
-- textos em DP_LANG (inglês, português ou espanhol): src/dp_text.lua
local T=dofile(DIR..'/dp_text.lua')
local WAIT_TEXT={partner_offline=true,no_usable_pokemon=true,battle_busy=true,two_players_required=true}
local SOLO_HINT=T('solo_hint')
local function waitText(reason)
    if WAIT_TEXT[reason] then return T('wait_'..reason) end
    return T('wait_other',tostring(reason))
end
local R={frame=0,channel=nil,authority=nil,peerProfile=nil,pending=nil,view=false,request=nil,
    nextConnect=0,serial=0,lastVideo=-1,mode=nil,queuedSnapshot=nil,lastProfile=-1,lastPing=-1}
DP.Runtime=R
local function log(message) DP.Log('Coop nativo: '..message) end
local function trace(stage)
    if DP_TRACE and R.frame>200 and (not R.channel or not R.channel.authenticated) then
        local f=io.open(DP_TRACE..'.last','w');if f then f:write(R.frame..' '..stage);f:close() end
    end
end
local function clone(value) return Session.copy(value) end
local MachineCodec={encode=function(bytes) assert(type(bytes)=='string' and #bytes>0,'invalid_machine');return bytes end}
function R.savePrivateMachine()
    -- A API saveStateFile deste build reporta falha mesmo deixando um arquivo
    -- de estado. Usar o buffer validado + nossa escrita atômica dá um ACK real.
    return Store.new(DP.Data..'/ultimo-estado.ss0',MachineCodec):save(emu:saveStateBuffer(2))
end
-- Flags e variáveis da campanha vêm da organização do save da família (dp_profile.lua): temporárias e de sistema
-- do jogador ficam de fora; objetos, recompensas, treinadores, insígnias e cenas são da dupla.
local lay=P.layout
local layout={blocks=DP.Blocks,readBag=DP.ReadBag,writeBag=DP.WriteBag,safe=DP.Free,
    flags=DP.SharedFlags,vars=DP.SharedVars,flagOffset=DP.FLAGS,varOffset=DP.VARS,
    dexBytes=DP.DEX_BYTES,ownedOffset=DP.DEX_OWNED,seenOffset=DP.DEX_SEEN,
    seenCopies={DP.DEX_SEEN1,DP.DEX_SEEN2},nationalMagicOffset=lay.nationalMagicOffset,
    nationalFlag=lay.nationalFlag,nationalMagicValue=lay.nationalMagicValue}
Session.configure({flagMax=lay.flagMax,rewardFlags=lay.rewardFlags})
R.campaign=Campaign.new(emu,layout)
R.backend=NativeBattle.new(N,Party,Encounters,{})
R.reservations=Reservations.new(N,{
    -- só com a autoridade ao alcance (o próprio anfitrião, ou o parceiro com o canal ligado): sem ela a CPU ficaria
    -- parada esperando uma resposta que não vem
    active=function() return MPGameMode()=='Coop' and not R.backend.running and not R.view
        and (R.role=='host' or (R.channel and R.channel.authenticated)) end,
    denied=function(key,fixed)
        Banner.show(T('last_unit'),300)
        log('última unidade de '..key..' já era do parceiro: retirada recusada, '..fixed..' Pokémon voltou ao que era')
    end,
    nextId=function() return R.nextId() end,
    reserve=function(id,key)
        local request={kind='reserve',id=id,resource=key}
        if R.role=='host' and R.authority then
            local result=R.authority:dispatch(R.me,request)
            R.reservationReply={id=id,result=result};R.snapshot()
        else R.send({kind='reserve',request=request}) end
    end,
    refund=function(id,key)
        local request={kind='refund',id=id..'-refund',reservation=id}
        if R.role=='host' and R.authority then R.authority:dispatch(R.me,request);R.snapshot()
        else R.send({kind='refund',request=request}) end
    end})
local function now() return R.frame end
-- Carrega um estado da máquina sem trazer junto os botões gravados nele. Um estado salvo pelo outro emulador (o vídeo da
-- batalha) ou num momento anterior guarda os botões apertados naquela hora; sem isso, o getKeys seguinte devolvia os
-- botões do anfitrião como se fossem do parceiro (um teclado comandava os dois lados dentro da batalha).
function R.loadState(buffer,flags)
    local physical=emu:getKeys()
    local ok=emu:loadStateBuffer(buffer,flags)
    emu:setKeys(physical)
    return ok
end
function R.send(message)
    if not R.channel then return false,'offline' end
    local ok,err=R.channel:send(message)
    if not ok and err~='offline' and err~='not_paired' and R.lastSendError~=err then
        R.lastSendError=err;log('mensagem '..tostring(message.kind)..' não enviada: '..tostring(err))
    end
    return ok,err
end
function R.persist()
    if not R.authority then return false end
    return R.authority.store:save(R.authority.state)
end
function R.snapshot()
    if R.authority then
        local s=R.authority.state
        -- Checkpoints e recibos pertencem ao host. A campanha enviada para a
        -- RAM do parceiro contém só os campos de jogo compartilhados.
        R.send({kind='snapshot',document={id=s.id,revision=s.revision,inventory=s.inventory,
            flags=s.flags,vars=s.vars,dex=s.dex}})
    end
end
function R.identity()
    return MPIni and MPIni.code and tostring(MPIni.code),MPIni and MPIni.partner and tostring(MPIni.partner)
end
function R.nextId()
    R.serial=R.serial+1;return string.format('%x-%x-%x',os.time(),R.frame,R.serial)
end
function R.profile()
    if R.backend.running and R.backend.profiles and R.backend.profiles[R.me] then return clone(R.backend.profiles[R.me]) end
    if R.view and R.localProfile then return clone(R.localProfile) end
    local profile=N.profile();profile.position=N.position()
    if R.request then profile.safe=true end
    return profile
end
function R.openAuthority()
    if R.authority then return true end
    local current=R.campaign:read();if not current then return false end
    local store=Store.new(DP.Data..'/campanha-'..R.me..'.bin',StorageWire)
    local authority,err=Authority.open(Session,store,R.me,current.inventory)
    if not authority then log('não abriu campanha: '..tostring(err));return false end
    R.authority=authority
    if authority.state.revision==0 then
        authority.state.flags=clone(current.flags);authority.state.vars=clone(current.vars);authority.state.dex=clone(current.dex)
    end
    local joined=authority:dispatch(R.me,{kind='join',profile=R.profile()})
    if not joined.ok then R.authority=nil;return false end
    R.campaign.baseline=current
    return true
end
function R.beginChannel(token)
    if R.channel and R.channel.config.token==token then return end
    if R.channel then R.channel:close() end
    R.channel=Channel.new(Wire,{localId=R.me,peerId=R.peer,token=token,timeout=900,
        onReady=function() log('canal pareado');R.send({kind='profile',profile=R.profile()}) end,
        onDrop=function(reason)
            if R.backend.running or R.view then Banner.show(T('connection_lost')) end
            if R.backend.running then R.backend:pause() end
            if R.authority and R.authority.state.players[R.peer] then
                R.authority:dispatch(R.peer,{kind='disconnect'})
            end
            log('sessão suspensa: '..tostring(reason))
        end,
        onMessage=function(message) R.receive(message) end})
    if R.role=='host' then R.listen() end
end
function R.listen()
    if not R.channel or R.channel.server then return end
    local server,err=socket.bind(DP_NATIVE_BIND,DP_NATIVE_PORT or 4098)
    if server then server:listen();R.channel.server=server
    else log('porta indisponível: '..tostring(err)) end
end
function R.enemies(context)
    local rng=Encounters.rng(context.seed)
    if context.trainer and context.trainer>0 then
        local team=MPBuildTeam(context.trainer,true);if not team then return nil,'invalid_trainer' end
        local enemies={}
        for i=0,team.count-1 do enemies[#enemies+1]={uid=context.battleId..'/trainer/'..i,
            species=team.species[i+1],raw=DPEncodeMon(DPDecodeMon(team.raw[i]))} end
        if #enemies==1 then
            -- Reforço coerente com o lugar: uma espécie da tabela de selvagens do mapa do treinador (de preferência
            -- outra espécie), no mesmo nível do Pokémon dele. Sem tabela (ginásio, prédio): outro indivíduo da mesma
            -- espécie, com IVs e personalidade próprios. A mesma instância nunca é clonada.
            local own=enemies[1].species;local species,origin
            for _,kind in ipairs({'grass','water','rock'}) do
                local slots=N.table({group=context.group,map=context.map,kind=kind})
                if slots and #slots>0 then
                    local options={}
                    for _,slot in ipairs(slots) do if slot.species~=own and slot.species>0 then options[#options+1]=slot.species end end
                    if #options>0 then species=options[rng:below(#options)+1];origin='tabela do mapa ('..kind..')';break end
                end
            end
            if not species then species=own;origin='mesma espécie, outro indivíduo' end
            local level=math.max(2,team.lastLevel)
            local mon={uid=context.battleId..'/support',species=species,level=level,personality=rng:word(),ivs={},otid=context.otid}
            for i=1,6 do mon.ivs[i]=rng:below(32) end
            mon.nature=mon.personality%25;enemies[2]=N.create(mon,rng,context)
            log(string.format('reforço do treinador: espécie %d, nível %d (%s)',species,level,origin))
        end
        return enemies
    end
    if context.special then
        -- Um encontro roteirizado conserva seu indivíduo original. O segundo
        -- é um acompanhante comum independente, nunca outra cópia do único.
        local f=DPDecodeBytes(context.original)
        local support=({[144]=87,[145]=125,[146]=126,[150]=97,[151]=63,[143]=96})[f.species] or 19
        if support==f.species then support=21 end
        local mon={uid=context.battleId..'/companion',species=support,level=math.max(2,f.level*9//10),
            personality=rng:word(),ivs={},otid=context.otid}
        for i=1,6 do mon.ivs[i]=rng:below(32) end
        mon.nature=mon.personality%25
        return {{uid=context.battleId..'/scripted',species=f.species,raw=context.original},N.create(mon,rng,context)}
    end
    local result,err=Encounters.pair(context,N,rng)
    return result,err
end
function R.makeRequest()
    local profile=R.profile();local position=N.position();local id=R.nextId()
    local flags=emu:read32(N.FLAGS)
    local trainer=(flags&8)~=0 and emu:read16(MPBattleAddress[DPGameID()].opp) or nil
    local context={battleId=id,kind=R.encounterKind or 'grass',group=position.group,map=position.map,
        seed=emu:read32(P.rngValue),otid=profile.otid,trainer=trainer}
    local scripted=emu:read32(P.savedCallback)~=(P.cb2EndWildBattle|1)
    if not trainer and (scripted or not R.encounterKind or (flags&(0x400|0x2000))~=0) then
        context.special=true;context.original=N.read(N.ENEMY,100)
    end
    R.encounterKind=nil
    Banner.show(T('preparing'))
    local enemies,err=R.enemies(context)
    if not enemies then log('batalha aguarda configuração: '..tostring(err));return false end
    R.request={id=id,profile=profile,position=position,context=context,enemies=enemies,
        machine=emu:saveStateBuffer(0),battleKind=trainer and 'trainer' or 'wild'}
    R.requestFrozen=N.freeze();R.waitReason=nil
    if R.role=='host' then R.requestBattle(R.me,R.request)
    else R.send({kind='request_battle',request=R.request}) end
    return true
end
function R.requestBattle(who,request)
    if not R.authority then return end
    local joined=R.authority:dispatch(who,{kind='join',profile=request.profile})
    if not joined.ok then return end
    local response=R.authority:dispatch(who,{kind='battle',id=request.id,enemies=request.enemies,battleKind=request.battleKind})
    if not response.ok then
        -- quem pediu a batalha é quem vê o aviso (o próprio host ou o parceiro)
        if who==R.me then R.waitReason=response.reason;Banner.show(waitText(response.reason),nil,SOLO_HINT)
        else R.send({kind='battle_wait',reason=response.reason}) end
        return
    end
    R.origin=request;R.battle=response.battle
    R.summon=response.battle
    R.send({kind='summon',battle=response.battle})
end
-- O parceiro pode ser chamado para a batalha agora? A máquina inteira é guardada e devolvida igual depois, então
-- menus simples são suspensos com segurança (o jogador volta ao mesmo menu). Diálogo, cena, PC e loja esperam
-- terminar: são os casos em que a especificação pede concluir a ação antes (ou esperar um ponto seguro).
function R.canSuspend()
    if DP.Free() then return true end
    local menu=IsInMenu()
    if menu==3 or menu==4 or menu==5 then return true end            --equipe, resumo, bolsa
    if menu==0 and MPMenuOpen and emu:read8(gAddress[DPGameID()].gScriptLoad)==2 then return true end   --menu START
    return false
end
function R.readyLocal()
    if not R.summon or R.readySent then return end
    if not R.request and not R.canSuspend() then
        Banner.show(T('partner_found'),nil,T('partner_found_hint'))
        if not R.busySent then R.busySent=true;R.send({kind='partner_busy',battle=R.summon.id}) end
        return
    end
    R.busySent=nil
    if R.request and R.request.id~=R.summon.request then
        if not R.lastFieldState then return end
        assert(R.loadState(R.lastFieldState,0),'cannot_cancel_simultaneous_request')
        R.request=nil
    end
    -- Inclui o SRAM particular. Saves automáticos de eventos durante a
    -- execução emprestada não podem gravar a equipe combinada no cartucho.
    R.backup=emu:saveStateBuffer(2)
    R.localProfile=R.profile();R.localProfile.safe=true
    R.returnCallbacks=N.freeze();R.readySent=true
    local returnStore=Store.new(DP.Data..'/retorno-'..R.me..'.bin',Wire)
    local saved,err=returnStore:save({schema=1,battle=R.summon.id,machine=R.backup,callbacks=R.returnCallbacks})
    if not saved then error('return_checkpoint_not_saved: '..tostring(err)) end
    Banner.show(T('entering'))
    local ready={kind='ready',battle=R.summon.id,profile=R.localProfile,position=R.localProfile.position}
    if R.role=='host' then R.ready(R.me,ready) else R.send(ready) end
end
function R.ready(who,message)
    if not R.authority or not R.authority.state.battle or R.authority.state.battle.id~=message.battle then return end
    R.authority:dispatch(who,{kind='join',profile=message.profile})
    local result=R.authority:dispatch(who,{kind='ready',battle=message.battle,position=message.position})
    if not result.ok or result.phase~='committed' or R.backend.running then return end
    local state=R.authority.state
    if not R.loadState(R.origin.machine,0) then error('cannot_load_initiator_state') end
    local prepared,err=R.backend:prepare(state.battle,state.players)
    if not prepared then error(err) end
    local checkpoint=R.backend:checkpoint()
    checkpoint.origin=R.origin;checkpoint.hostBackup=R.backup
    checkpoint.profiles=clone(state.players);checkpoint.callbacks=R.returnCallbacks;checkpoint.started=false
    local durable,why=R.authority:resolve(function(s) s.battle.checkpoint=checkpoint;return true end)
    if not durable then error('checkpoint_not_saved: '..tostring(why)) end
    R.send({kind='commit_battle',battle=state.battle.id})
    R.backend:start();R.fieldFrames=0;R.seenBattle=false;R.mode='battle';log('batalha conjunta iniciada')
    Banner.show(T('double_battle'),120)
end
function R.applyResult(message)
    local plan=message.plans[R.me];if not plan then error('missing_private_result') end
    local receipts=Store.new(DP.Data..'/resultados-aplicados-'..R.me..'.bin',Wire)
    local applied,loadError=receipts:load()
    if not applied and loadError~='not_found' then error('invalid_private_receipts') end
    applied=applied or {schema=1,ids={}}
    if applied.ids[message.battle] then
        R.send({kind='result_applied',battle=message.battle});return
    end
    if not R.backup then
        local saved=Store.new(DP.Data..'/retorno-'..R.me..'.bin',Wire):load()
        if saved and saved.battle==message.battle then R.backup=saved.machine;R.returnCallbacks=saved.callbacks end
    end
    local machine=R.me==message.initiator and message.machine or R.backup
    if not machine then error('missing_return_checkpoint') end
    local journal=Store.new(DP.Data..'/resultado-'..R.me..'.bin',Wire)
    local saved,err=journal:save({schema=1,id=message.battle,plan=plan,machine=machine})
    if not saved then error('private_result_not_saved: '..tostring(err)) end
    R.backend:stop()
    if R.backup then assert(R.loadState(R.backup,2),'cannot_restore_private_cartridge') end
    assert(R.loadState(machine,0),'cannot_restore_private_state')
    -- O checkpoint de espera tinha os dois callbacks parados. A posição e os
    -- callbacks originais estão no estado anterior à convocação.
    if R.returnCallbacks and R.me~=message.initiator then N.unfreeze(R.returnCallbacks) end
    N.applyResult(plan)
    assert(R.savePrivateMachine(),'cannot_save_private_machine')
    applied.ids[message.battle]=true
    assert(receipts:save(applied),'cannot_save_private_receipt')
    Banner.hide()
    R.latestVideo=nil
    R.view=false;R.mode=nil;R.request=nil;R.summon=nil;R.readySent=nil;R.backup=nil
    R.battle=nil;R.returnCallbacks=nil;R.lastResult=message.battle
    R.send({kind='result_applied',battle=message.battle})
    if R.authority and R.authority.state.history[message.battle] then
        local history=R.authority.state.history[message.battle]
        history.delivered=history.delivered or {};history.delivered[R.me]=true;R.persist()
    end
    log('resultado particular aplicado; retorno ao mapa')
end
function R.finishBattle()
    local s=R.authority.state;local battle=s.battle
    local plans={}
    for _,who in ipairs(battle.participants) do
        local plan,err=N.planResult(R.backend:result(who),s.players[who]);if not plan then error(err) end
        plans[who]=plan
    end
    local result={kind='battle_result',battle=battle.id,initiator=battle.initiator,
        machine=emu:saveStateBuffer(0),plans=plans}
    local committed,err=R.authority:resolve(function(st,session)
        local outcome=emu:read8(P.battleOutcome)
        local history=session.finish(st,battle.id,outcome);if not history then return nil end
        st.history[battle.id].delivery=result;return true
    end)
    if not committed then error('battle_result_not_saved: '..tostring(err)) end
    R.send(result);R.applyResult(result);R.snapshot()
end
-- Sair do cooperativo nesta sessão. O jogador volta ao mapa logo antes do encontro (último estado livre salvo)
-- e as próximas batalhas são individuais. Só enquanto o host não aceitou a batalha: nada fica preparado pela metade.
function R.soloEscape()
    if not R.request or R.summon or R.mode then R.escapeHold=0;R.escapeArmed=nil;return false end
    local waiting=R.waitReason or not (R.channel and R.channel.authenticated)
    if not waiting or not R.lastFieldState then R.escapeHold=0;return false end
    -- L(512)+R(256)+SELECT(4) seguros por 1,5 s; a volta ao mapa só acontece depois de soltar os botões
    -- (com L/R ainda apertados o FireRed abriria a Ajuda assim que o jogo voltasse a rodar)
    local keys=emu:getKeys()
    if not R.escapeArmed then
        if (keys&0x304)==0x304 then R.escapeHold=(R.escapeHold or 0)+1 else R.escapeHold=0 end
        if R.escapeHold<90 then return false end
        R.escapeArmed=true;R.escapeHold=0
        Banner.show(T('release_buttons'),nil,T('coop_ends'))
        return false
    end
    if (keys&0x304)~=0 then return false end
    R.escapeArmed=nil
    MPIni.mode='Free Roam'                  --só nesta sessão (o .ini continua em Coop)
    assert(R.loadState(R.lastFieldState,0),'cannot_restore_field_state')
    R.request=nil;R.requestFrozen=nil;R.waitReason=nil
    Banner.show(T('coop_ended'),300,T('next_battles_solo'))
    log('jogador saiu do cooperativo com uma batalha pendente; volta ao mapa e segue individual')
    return true
end
function R.receive(message)
    if DP_DEBUG_NET and message.kind~='video' and message.kind~='input' and message.kind~='ping' and message.kind~='profile' then
        log('DEBUG recebido '..tostring(message.kind)..' '..tostring(message.id or (message.request and message.request.id) or ''))
    end
    if message.kind=='profile' then
        R.peerProfile=message.profile
        if not message.profile or (message.profile.usable or 0)<1 then return end
        if R.authority then
            R.authority:dispatch(R.peer,{kind='join',profile=message.profile})
            if R.request and not R.authority.state.battle then R.requestBattle(R.me,R.request) end
            if R.authority.state.battle and R.authority.state.battle.phase=='paused' then R.resumeHost() end
            for _,history in pairs(R.authority.state.history) do
                if history.delivery and not (history.delivered and history.delivered[R.peer]) then R.send(history.delivery) end
            end
            R.snapshot()
        end
    elseif message.kind=='snapshot' and R.role=='guest' then R.queuedSnapshot=message.document
    elseif message.kind=='event' and R.role=='host' then
        local response=R.authority:dispatch(R.peer,message.request)
        log('evento do parceiro '..tostring(message.request.id)..': '..(response.ok and 'aceito' or ('recusado ('..tostring(response.reason)..')')))
        R.send({kind='event_ack',id=message.request.id,result=response});R.snapshot()
    elseif message.kind=='reserve' and R.role=='host' then
        local response=R.authority:dispatch(R.peer,message.request)
        R.send({kind='reserve_ack',id=message.request.id,result=response});R.snapshot()
    elseif message.kind=='refund' and R.role=='host' then
        R.authority:dispatch(R.peer,message.request);R.snapshot()
    elseif message.kind=='reserve_ack' then R.reservationReply={id=message.id,result=message.result}
    elseif message.kind=='event_ack' and not (R.pending and message.id==R.pending.id) then
        log('confirmação de evento sem pendência: '..tostring(message.id)..' (pendente '..tostring(R.pending and R.pending.id)..')')
    elseif message.kind=='event_ack' and R.pending and message.id==R.pending.id then
        R.pending=nil
        if not message.result.ok then R.campaign.baseline=R.campaign:read() end
    elseif message.kind=='request_battle' and R.role=='host' then R.requestBattle(R.peer,message.request)
    elseif message.kind=='summon' then
        R.summon=message.battle
        if not R.request then Banner.show(T('partner_found')) end
    elseif message.kind=='partner_busy' then
        Banner.show(T('partner_busy'),nil,T('partner_busy_hint'))
    elseif message.kind=='battle_wait' then R.waitReason=message.reason;Banner.show(waitText(message.reason),nil,SOLO_HINT)
    elseif message.kind=='ready' and R.role=='host' then R.ready(R.peer,message)
    elseif message.kind=='resume_battle' then
        local saved=Store.new(DP.Data..'/retorno-'..R.me..'.bin',Wire):load()
        if not saved or saved.battle~=message.battle then error('missing_private_reconnect_checkpoint') end
        R.backup=saved.machine;R.returnCallbacks=saved.callbacks
        R.view=true;R.mode='battle';Banner.show(T('partner_back'),180)
    elseif message.kind=='commit_battle' then R.view=true;R.mode='battle';Banner.show(T('double_battle'),120)
    elseif message.kind=='input' and R.role=='host' then
        -- várias mensagens podem chegar entre dois quadros (o emulador do parceiro mais rápido que o deste): um toque
        -- curto começaria e terminaria entre eles e se perderia. Todo botão visto desde o último quadro conta uma vez.
        if type(message.keys)=='number' then
            R.peerKeys=message.keys&1023
            if R.backend.running then R.peerSeen=(R.peerSeen or 0)|R.peerKeys end   --fora da batalha não acumula
        end
    elseif message.kind=='video' and R.view then
        -- só o estado mais recente importa para a tela: vários que chegam juntos viram um único carregamento
        R.latestVideo=message.machine
    elseif message.kind=='battle_result' then R.applyResult(message)
    elseif message.kind=='result_applied' and R.authority then
        local history=R.authority.state.history[message.battle]
        if history then
            history.delivered=history.delivered or {};history.delivered[R.peer]=true
            if history.delivered[R.me] then history.delivery=nil end
            R.persist()
        end
    end
end
function R.resumeHost()
    local s=R.authority.state;local battle=s.battle
    if not battle or battle.phase~='paused' then return end
    local cp=battle.checkpoint;if not cp then return end
    local resumed=R.authority:dispatch(R.me,{kind='resume',battle=battle.id})
    if not resumed.ok then return end
    if R.backend.running and R.backend.pausedCallback then
        R.backend:resume()
    else
        R.origin=cp.origin;R.backup=cp.hostBackup;R.returnCallbacks=cp.callbacks
        R.battle=battle;R.summon=battle;R.readySent=true
        assert(R.loadState(cp.machine,0),'invalid_reconnect_state')
        R.backend.model=cp.model;R.backend.battle=battle;R.backend.captured=cp.captured
        R.backend.menu=cp.menu;R.backend.uiBank=cp.uiBank or 0
        R.backend.profiles=cp.profiles;R.backend.order={battle.initiator}
        for _,who in ipairs(battle.participants) do if who~=battle.initiator then R.backend.order[2]=who end end
        if cp.started then R.backend.running=true else R.backend:start() end
        R.mode='battle';R.fieldFrames=0;R.seenBattle=cp.started
    end
    R.send({kind='resume_battle',battle=battle.id});log('batalha retomada do checkpoint conjunto')
    Banner.show(T('partner_back'),180)
end
function R.worldTick()
    if R.mode or R.request or R.summon or not DP.Free() then return end
    if not R.peerProfile or (R.peerProfile.usable or 0)<1 or emu:read8(N.COUNT)<1 then return end
    local current=R.campaign:read();if not current then return end
    if R.pending then return end
    local delta=R.campaign.baseline and R.campaign:diff(current) or nil
    if delta then
        R.reservations:adjust(delta)
        local changed=next(delta.inventory) or next(delta.flags) or next(delta.vars)
            or next(delta.dex.seen) or next(delta.dex.owned)
        if not changed then delta=nil end
    end
    if R.queuedSnapshot and not delta then
        local document=R.queuedSnapshot
        local ok=R.campaign:apply(document,document.revision)
        if ok then R.queuedSnapshot=nil end
        return
    end
    if not R.campaign.baseline then R.campaign.baseline=current;return end
    if delta then
        local revision=R.role=='host' and R.authority.state.revision
            or (R.queuedSnapshot and R.queuedSnapshot.revision or R.campaign.revision)
        local request={kind='event',id=R.nextId(),revision=revision,delta=delta}
        if R.role=='host' then
            local response=R.authority:dispatch(R.me,request)
            if response.ok then R.campaign.baseline=current end
            R.queuedSnapshot=R.authority:snapshot();R.snapshot()
        else R.pending=request;R.campaign.baseline=current;R.send({kind='event',request=request}) end
    elseif R.role=='host' and R.campaign.revision~=R.authority.state.revision then
        R.queuedSnapshot=R.authority:snapshot()
    end
end
function R.tick()
    R.frame=R.frame+1
    Banner.tick()
    if not (R.backend.running or R.view) then R.inputOverride=nil end   --fora da batalha em dupla, botões normais
    if MPGameMode()~='Coop' then return end
    R.me,R.peer=R.identity();if not R.me or not R.peer then return end
    R.role=DPHosting() and 'host' or 'guest'
    trace('authority')
    if R.role=='host' and (emu:read8(N.COUNT)<1 or not R.openAuthority()) then return end
    -- parceiro sem nenhum Pokémon que possa lutar (jogo novo, antes do inicial): não há como puxá-lo, então a batalha
    -- segue só com quem a encontrou (no Ruby/Sapphire/Emerald a primeira batalha vem logo depois de escolher o inicial)
    if R.soloBattle then
        if DP.Free() then R.soloBattle=nil end
    elseif not R.request and not R.mode and R.peerProfile and (R.peerProfile.usable or 0)<1 and N.gate() then
        N.release();R.soloBattle=true
        Banner.show(T('partner_no_pokemon'),240)
        log('batalha individual: o parceiro ainda não tem Pokémon')
    elseif N.gate() and not R.request and not R.mode then R.makeRequest() end
    -- último estado livre no mapa (com ou sem parceiro): volta segura para cancelar um pedido de batalha
    if not R.request and not R.summon and not R.mode and not R.view and DP.Free() then R.lastFieldState=emu:saveStateBuffer(0) end
    if R.soloEscape() then return end
    if not R.channel then
        if R.request then Banner.show(T('waiting_connect'),nil,SOLO_HINT) end
        return
    end
    trace('channel')
    local ch=R.channel
    if ch.server and not ch.socket then local peer=ch.server:accept();if peer then ch:attach(peer,now()) end end
    -- Conectar é bloqueante: uma porta fechada congela o emulador ~2 s no Windows. Por isso o convidado só tenta logo
    -- depois de o anfitrião anunciar o canal (ele só anuncia com a porta aberta) e espera cada vez mais entre falhas.
    if R.role=='guest' and not ch.socket and R.frame>=R.nextConnect and R.frame-(R.lastAnnounce or -1e9)<=300 then
        local sock=socket.connect(DPServerAddress(),DP_NATIVE_PORT or 4098)
        if sock then ch:attach(sock,now());R.connectFails=0;R.nextConnect=R.frame+180
        else
            R.connectFails=(R.connectFails or 0)+1
            R.nextConnect=R.frame+math.min(3600,180*(2^R.connectFails))
            log('canal: o anfitrião não atendeu ('..R.connectFails..'ª tentativa)')
        end
    end
    ch:tick(now(),socket.ERRORS.AGAIN)
    trace('channel-ready')
    if R.reservationReply then
        local reply=R.reservationReply;R.reservationReply=nil
        R.reservations:complete(reply.id,reply.result)
    end
    if not ch.authenticated then
        if R.request and not R.summon then Banner.show(T('waiting_connect'),nil,SOLO_HINT) end
        return
    end
    if R.request and not R.summon and R.frame%120==0 then
        if R.role=='host' then R.requestBattle(R.me,R.request)
        else R.send({kind='request_battle',request=R.request}) end
    end
    if R.pending and R.frame%120==0 then
        if DP_DEBUG_NET then log('DEBUG reenviando evento '..tostring(R.pending.id)) end
        R.send({kind='event',request=R.pending})
    end
    if R.reservations.pending and R.frame%120==0 then
        local p=R.reservations.pending
        R.send({kind='reserve',request={kind='reserve',id=p.id,resource=p.key}})
    end
    if R.frame-R.lastPing>=120 then R.send({kind='ping'});R.lastPing=R.frame end
    if not R.mode and R.frame-R.lastProfile>=120 then R.send({kind='profile',profile=R.profile()});R.lastProfile=R.frame end
    if R.summon and not R.readySent then
        if not R.request and R.canSuspend() then R.returnCallbacks={emu:read32(P.gMain),emu:read32(P.callback2)} end
        R.readyLocal()
    end
    if R.backend.running then
        if not ch.authenticated then R.backend:pause();return end
        local mine=R.LocalKeys and R.LocalKeys() or emu:getKeys()
        local peer=(R.peerKeys or 0)|(R.peerSeen or 0);R.peerSeen=0
        local owner=R.battle.initiator==R.me and mine or peer
        local mirror=R.battle.initiator==R.me and peer or mine
        R.backend:setInput(owner,mirror)
        R.backend:adoptOwners()
        local ui=R.backend.menu and R.backend.menu.bank or R.backend.uiBank
        local uiKeys=ui==0 and owner or mirror
        if not R.backend.menu and (emu:read32(P.controllerFuncs)==(P.textController|1) or emu:read32(P.controllerFuncs+8)==(P.textController|1)) then
            uiKeys=uiKeys|((owner|mirror)&1) -- texto compartilhado pode avançar por qualquer participante
        end
        R.inputOverride=uiKeys
        if IsInMenu()==2 then R.seenBattle=true;R.fieldFrames=0
        elseif R.seenBattle and DP.Free() then R.fieldFrames=R.fieldFrames+1 end
        if R.fieldFrames>=30 then R.finishBattle();return end
        -- Tela da batalha para o parceiro: no máximo 10 estados por segundo de relógio. Contar em quadros fazia a 10x
        -- virar ~100 estados (40 MB/s) carregados por segundo no outro emulador, que acabava travando.
        -- (os.clock no Windows é o relógio de parede do processo)
        local agora=os.clock()
        if R.frame-R.lastVideo>=6 and agora-(R.lastVideoClock or -1)>=0.1 and ch.queued<1024*1024 then
            R.send({kind='video',machine=emu:saveStateBuffer(0)});R.lastVideo=R.frame;R.lastVideoClock=agora
        end
        if R.frame%120==0 then
            local cp=R.backend:checkpoint();cp.origin=R.origin;cp.hostBackup=R.backup
            cp.callbacks=R.returnCallbacks;cp.profiles=R.backend.profiles;cp.started=true
            local saved,err=R.authority:resolve(function(s) s.battle.checkpoint=cp;return true end)
            if not saved then error('battle_checkpoint_failed: '..tostring(err)) end
        end
        R.backend:endInputFrame()
    elseif R.view then
        if R.latestVideo then
            local machine=R.latestVideo;R.latestVideo=nil
            assert(R.loadState(machine,0),'invalid_battle_video_state')
            R.viewCallbacks=N.freeze()   --o que a tela mostra de verdade (o callback congelado vira o de espera)
        end
        local keys=R.LocalKeys and R.LocalKeys() or emu:getKeys()
        R.send({kind='input',keys=keys});R.inputOverride=0   --a cópia local só mostra a batalha: não reage a botões
    else
        if DP.Free() then R.reservations:observe() end
        R.worldTick()
        if DP.Free() and R.frame%600==0 then assert(R.savePrivateMachine(),'cannot_save_private_machine') end
    end
end
function R.install()
    R.backend:install();R.reservations:install();DP.RuntimeManaged=true
    local originalTick=MPTick
    function MPTick()
        trace('vendor-tick')
        -- O tick do fornecedor roda protegido: um erro dele (ex.: logo depois de restaurar a máquina particular)
        -- não pode impedir o tick do cooperativo, que é quem reenvia eventos e aplica a campanha.
        if not R.mode then
            local okVendor,errVendor=pcall(originalTick)
            if not okVendor and R.vendorError~=tostring(errVendor) then
                R.vendorError=tostring(errVendor);log('erro no tick do GBA-PK (o cooperativo segue): '..R.vendorError)
            end
        end
        trace('runtime-tick')
        local ok,err=pcall(R.tick)
        if not ok then
            R.backend:pause()
            if R.error~=tostring(err) then R.error=tostring(err);log('pausado: '..R.error) end
        end
    end
    local receive=MPProgressReceive
    function MPProgressReceive(id,data)
        local payload=data:sub(21,63)
        if payload:sub(1,3)=='DPN' and MPCoopActive and id==MPCoopPartner then
            R.me,R.peer=R.identity();R.role=DPHosting() and 'host' or 'guest'
            if R.role=='guest' then R.beginChannel(payload:sub(4,35));R.lastAnnounce=R.frame end
            return
        end
        return receive(id,data)
    end
    -- O código do fornecedor possui um interceptador de treino Versus e um
    -- compartilhamento aproximado de XP. Ambos conflitam com esta batalha real.
    local vsTick=MPVsTickSafe
    function MPVsTickSafe()
        if MPGameMode()=='Coop' then MPVsStub(false);return end
        return vsTick()
    end
    local share=MPCoopShareTickSafe
    function MPCoopShareTickSafe() if MPGameMode()~='Coop' then return share() end end
    local trainerReceive=MPCoopReceive
    function MPCoopReceive(kind,id,data) if MPGameMode()~='Coop' then return trainerReceive(kind,id,data) end end
    local sendAll=MPCoopSendAll
    function MPCoopSendAll() if MPGameMode()~='Coop' then return sendAll() end end
    callbacks:add('frame',function()
        if DPHosting() and MPGameMode()=='Coop' and MPCoopActive and MPCoopPartner then
            R.me,R.peer=R.identity();R.role='host'
            if not R.channel then
                local key=DP_PAIR_KEY
                if not key then
                    local rng=Encounters.rng((os.time()~emu:read32(P.rngValue))&0xffffffff)
                    key=string.format('%08x%08x%08x%08x',rng:word(),rng:word(),rng:word(),rng:word())
                end
                R.beginChannel(key)
            end
            -- porta que não abriu (ocupada por outra janela, por exemplo): tenta de novo de tempos em tempos
            if not R.channel.server and R.frame%600==0 then R.listen() end
            -- só anuncia o canal com a porta aberta: anunciar sem ela faz o parceiro tentar conectar numa porta fechada,
            -- e no Windows cada tentativa recusada congela o emulador dele por uns 2 segundos
            -- e só quando já atende conexões: sem Pokémon (jogo novo) a campanha não abre e o canal não é lido; o parceiro
            -- encheria a fila da porta e as tentativas seguintes seriam recusadas
            if R.channel.server and R.authority and R.frame%120==0 then MPSendPacket('PRGS',MPCoopPartner,'DPN'..R.channel.config.token) end
        end
    end)
    -- Registrar o tipo antes de o gerador nativo consumir os parâmetros.
    -- Botões da batalha em dupla entram na leitura do controle do próprio jogo (ReadKeys, logo depois de ler
    -- REG_KEYINPUT em r1), nunca com emu:setKeys: setKeys fica gravado no emulador e o getKeys seguinte devolveria os
    -- botões do parceiro como se fossem deste jogador (um teclado acabava comandando os dois lados).
    R.keysHook=emu:setBreakpoint(function()
        if R.inputOverride~=nil then emu:writeRegister('r1',(0x3ff~(R.inputOverride&0x3ff))&0x3ff) end
    end,P.readKeysR1)
    local encounterHook=emu:setBreakpoint(function()
        R.encounterKind=({[0]='grass',[1]='water',[2]='rock'})[emu:readRegister('r1')]
    end,P.encounterKindHook)
    R.encounterHook=encounterHook
    R.fishingHook=emu:setBreakpoint(function()
        R.encounterKind=({[0]='old_rod',[1]='good_rod',[2]='super_rod'})[emu:readRegister('r1')]
    end,P.fishingHook)
    log('integração carregada; requer dois participantes pareados')
end
return R
