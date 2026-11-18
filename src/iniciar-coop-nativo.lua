-- Carregador do cooperativo nativo. Requer mGBA com a API de breakpoints.
local source=debug.getinfo(1,'S').source:sub(2)
DP_DIR=DP_DIR or source:match('^(.*)[/\\]') or '.'
if DP and DP.RuntimeManaged and DP.Runtime then return end
DP_EMU=DP_EMU or dofile(DP_DIR..'/dp_compat.lua').wrap(emu)
DP_ADDR=DP_ADDR or dofile(DP_DIR..'/dp_profile.lua')
local P=DP_ADDR
local emu=DP_EMU
-- --script pode ser avaliado antes de o Core estar anexado à ROM. Os métodos
-- do adaptador existem nessa fase, mas os métodos da máquina ainda não.
local coreReady=pcall(function() return emu:getGameCode() end)
local sb=coreReady and P.readSaveBlocks(emu) or 0
local fieldReady=coreReady and sb>=0x02000000 and sb<0x02040000
    and emu:read32(P.callback2)==(P.cb2Overworld|1)
if not fieldReady then
    callbacks:oneshot('frame',function() dofile(source) end)
    return
end
if not emu.setBreakpoint then
    -- mGBA comum (0.10.x): o parceiro aparece no mapa (GBA-PK), mas a batalha em dupla não tem como ser montada.
    -- Avisa de forma visível em vez de seguir com uma batalha sozinho que parece defeito.
    local texto=dofile(DP_DIR..'/dp_text.lua')('old_mgba')
    pcall(function() console:error(texto) end)
    pcall(function() local b=console:createBuffer('Duplas');b:clear();b:print(texto..'\n') end)
    pcall(function() local f=io.open(DP_DIR..'/../aviso.txt','w');if f then f:write(texto);f:close() end end)
    return
end
dofile(DP_DIR..'/iniciar-duplas.lua')
local runtime=dofile(DP_DIR..'/dp_runtime.lua')
runtime.install()
