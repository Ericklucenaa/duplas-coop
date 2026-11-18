-- Fronteira transacional da campanha: copia -> valida -> persiste -> publica.
-- O transporte não recebe uma confirmação de sucesso antes de gravar o estado.
local A={}
function A.open(session,store,id,inventory)
    local state,source=store:load()
    if not state and source~='not_found' then return nil,source end
    if state and state.id~=id then return nil,'wrong_campaign' end
    state=state or session.new(id,inventory)
    -- Presença não sobrevive a uma queda de processo. A batalha conserva o
    -- checkpoint e só sai de pausa depois de ambos voltarem à sessão.
    for _,p in pairs(state.players) do p.connected=false;p.safe=false end
    if state.battle and state.battle.phase~='paused' then
        state.battle.resumePhase=state.battle.phase;state.battle.phase='paused'
    end
    local authority={state=state,session=session,store=store}
    local handlers={
        join=function(s,who,r) session.player(s,who,r.profile);return {ok=true} end,
        inventory=function(s,who,r) return session.transact(s,who,r.id,r.changes,r.claim) end,
        reserve=function(s,who,r) return session.reserve(s,who,r.id,r.resource) end,
        refund=function(s,who,r) return session.refund(s,who,r.id,r.reservation) end,
        progress=function(s,who,r) return session.progress(s,who,r.id,r.revision,r.flags,r.vars) end,
        event=function(s,who,r) return session.event(s,who,r.id,r.revision,r.delta) end,
        battle=function(s,who,r)
            local b,err=session.requestBattle(s,who,r.id,r.enemies,r.battleKind)
            return b and {ok=true,battle=b} or {ok=false,reason=err}
        end,
        ready=function(s,who,r)
            local ok,phase=session.ready(s,r.battle,who,r.position)
            return {ok=ok,reason=not ok and phase or nil,phase=ok and phase or nil}
        end,
        action=function(s,who,r)
            local ok,err=session.action(s,r.battle,r.turn,who,r.action)
            return {ok=ok,reason=err}
        end,
        disconnect=function(s,who) session.disconnect(s,who);return {ok=true} end,
        resume=function(s,who,r)
            if not s.players[who] or not s.players[who].connected then return {ok=false,reason='offline'} end
            return {ok=session.resume(s,r.battle)}
        end
    }
    -- who vem da conexão autenticada, nunca de um campo escolhido no pacote.
    function authority:dispatch(who,request)
        if type(request)~='table' or type(who)~='string' then return {ok=false,reason='invalid_request'} end
        local handler=handlers[request.kind]
        if not handler then return {ok=false,reason='unknown_command'} end
        local staged=session.copy(self.state)
        local valid,result=pcall(handler,staged,who,request)
        if not valid then return {ok=false,reason='invalid_request'} end
        if not result.ok then return result end
        local saved,err=self.store:save(staged)
        if not saved then return {ok=false,reason='storage_unavailable',detail=tostring(err)} end
        self.state=staged;result.revision=staged.revision
        return result
    end
    -- Chamado somente pelo resolvedor do host. Não existe comando de rede
    -- que permita ao cliente inventar captura, resultado ou checkpoint.
    function authority:resolve(callback)
        local staged=session.copy(self.state)
        local valid,result=pcall(callback,staged,session)
        if not valid then return nil,'resolver_failed' end
        if result==nil or result==false then return nil,'resolver_rejected' end
        local saved,err=self.store:save(staged);if not saved then return nil,err end
        self.state=staged;return result
    end
    function authority:snapshot() return session.copy(self.state) end
    return authority
end
return A
