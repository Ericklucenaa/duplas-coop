-- Coordena convocação automática; nenhuma entrada de batalha usa aceite manual.
-- O backend só é liberado depois de checkpoint durável + dois participantes
-- prontos. Falha de transporte mantém a batalha suspensa.
local R={}
function R.new(authority,backend,send)
    local r={authority=authority,backend=backend,send=send,pending={},active=nil}
    function r:request(player,request,enemies,kind)
        local response=self.authority:dispatch(player,{kind='battle',id=request,enemies=enemies,battleKind=kind})
        -- A API da autoridade usa kind para selecionar o comando; o tipo da
        -- batalha é um campo separado para não sobrescrever o discriminador.
        if not response.ok then return response end
        self.active=response.battle.id
        for _,who in ipairs(response.battle.participants) do
            self.send(who,{kind='summon',battle=response.battle})
        end
        return response
    end
    function r:ready(player,battle,position)
        local result=self.authority:dispatch(player,{kind='ready',battle=battle,position=position})
        if not result.ok then return result end
        if result.phase=='committed' and not self.pending[battle] then
            local document=self.authority:snapshot()
            local prepared,err=self.backend:prepare(document.battle,document.players)
            if not prepared then return {ok=false,reason=err or 'native_prepare_failed'} end
            -- prepare não executa um turno: só valida e constrói os dados.
            -- checkpoint é gravado antes do primeiro passo do motor.
            local checkpoint=self.backend:checkpoint()
            local durable,storeError=self.authority:resolve(function(s)
                s.battle.checkpoint=checkpoint;return true
            end)
            if not durable then return {ok=false,reason='storage_unavailable',detail=storeError} end
            self.pending[battle]=true
            for _,who in ipairs(document.battle.participants) do self.send(who,{kind='commit_battle',battle=battle}) end
            self.backend:start()
        end
        return result
    end
    function r:disconnect(player)
        local result=self.authority:dispatch(player,{kind='disconnect'})
        if self.active then self.backend:pause() end
        return result
    end
    function r:finish(battle,outcome)
        local result,err=self.authority:resolve(function(s,session)
            return session.finish(s,battle,outcome)
        end)
        if not result then return nil,err end
        self.backend:pause()
        for _,who in ipairs(self.authority.state.history[battle].participants or {}) do
            self.send(who,{kind='battle_result',result=result})
        end
        self.pending[battle]=nil;self.active=nil;return result
    end
    return r
end
return R
