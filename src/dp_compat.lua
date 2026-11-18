-- Compatibilidade do GBA-PK 0.10 com o CoreAdapter do build 0.11-9184.
-- Não substitui o objeto emu do contexto nativo: o debugger usa essa referência.
local M={}
function M.wrap(adapter)
    local ok,core=pcall(function() return adapter._core end)
    if not ok or not core then return adapter end
    local extra={setBreakpoint=true,clearBreakpoint=true,setWatchpoint=true,setRangeWatchpoint=true,currentCycle=true}
    -- Áreas de memória por procuração: o GBA-PK guarda emu.memory.cart0 (ROMCARD) uma vez, e o objeto real deixa de
    -- valer depois de carregar um estado ("Invalid object" a cada quadro). Cada chamada busca o objeto vivo.
    local function liveMemory()
        local current=type(adapter)=='userdata' and _G.emu or adapter
        return current.memory
    end
    local domains={}
    local memory=setmetatable({},{__index=function(_,domain)
        local proxy=domains[domain]
        if not proxy then
            proxy=setmetatable({},{__index=function(p,method)
                local f=function(_, ...)
                    local d=liveMemory()[domain]
                    return d[method](d,...)
                end
                rawset(p,method,f);return f
            end})
            domains[domain]=proxy
        end
        return proxy
    end})
    local facade={memory=memory}
    return setmetatable(facade,{__index=function(self,name)
        local liveAdapter=type(adapter)=='userdata' and _G.emu or adapter
        local receiver=extra[name] and liveAdapter or liveAdapter._core
        local success,method=pcall(function() return receiver[name] end)
        if not success then return nil end
        if type(method)~='function' then return method end
        local wrapped=function(_, ...)
            -- _core é uma referência transitória do contexto de scripting.
            -- Buscar de novo em cada chamada evita retê-la entre quadros/GC.
            local current=type(adapter)=='userdata' and _G.emu or adapter
            local live=extra[name] and current or current._core
            local result=table.pack(live[name](live,...))
            if name=='getGameCode' and type(result[1])=='string' and #result[1]==4 then result[1]='AGB-'..result[1] end
            return table.unpack(result,1,result.n)
        end
        rawset(self,name,wrapped);return wrapped
    end})
end
return M
