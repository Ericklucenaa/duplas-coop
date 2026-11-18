-- Cria um jogo novo sozinho e grava o estado do emulador quando o personagem fica livre no mapa.
-- Serve para testar jogos sem save (Emerald, Ruby, Sapphire...). Antes do dofile: NOVO_OUT (arquivo do estado a gravar),
-- NOVO_LOG (log), DP_PROFILE (perfil do jogo) e DP_GBAPK (GBA-PK, para saber se o jogador está livre).
-- Na introdução, A a cada meio segundo resolve tudo: escolhas no padrão e, no teclado do nome, as letras enchem o nome e
-- o cursor vai sozinho para OK. No mapa, o A só é apertado quando um texto prende o jogador (para não falar com objetos).
local here=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
local frame=0
local function log(t) local f=io.open(NOVO_LOG,'a') if f then f:write(string.format('[%06d] %s\n',frame,t)) f:close() end end
DP_EMU=dofile(here..'/../../src/dp_compat.lua').wrap(emu)
DP_ADDR=dofile(here..'/../../src/dp_profile.lua')
local P=DP_ADDR
local machine=DP_EMU
local carregado=false
local livreDesde,presoDesde=nil,nil
local feito=false
local tecla,soltar=nil,0
local function apertar(k) machine:addKey(k);tecla=k;soltar=frame+5 end
log('jogo novo: '..P.name)
callbacks:add('frame',function()
    local ok,err=pcall(function()
    frame=frame+1
    if tecla and frame>=soltar then machine:clearKey(tecla);tecla=nil end
    if feito then return end
    local noMapa=machine:read32(P.callback2)==(P.cb2Overworld|1)
    if noMapa and not carregado and frame>60 then
        -- no mapa: carrega GBA-PK + DP só para usar a mesma regra de "jogador livre" do modo Duplas
        DP_DIR=here..'/../../src'
        local okd,errd=pcall(dofile,here..'/../../src/iniciar-duplas.lua')
        carregado=true;log('no mapa; regra de jogador livre carregada '..tostring(okd)..' '..tostring(errd or ''))
    end
    if not noMapa then
        livreDesde=nil
        if frame%30==0 then apertar(C.GBA_KEY.A) end
        if frame%600==0 then log(string.format('introdução cb2=%08x',machine:read32(P.callback2))) end
        return
    end
    local livre=carregado and DP and DP.Free and DP.Free()
    if livre then
        presoDesde=nil;livreDesde=livreDesde or frame
        if frame-livreDesde>=240 then
            local estado=machine:saveStateBuffer(0)
            local f=assert(io.open(NOVO_OUT,'wb'));f:write(estado);f:close()
            log(string.format('PRONTO estado gravado (%d bytes)',#estado));feito=true
        end
    else
        livreDesde=nil;presoDesde=presoDesde or frame
        if frame-presoDesde>=120 and frame%30==0 then apertar(C.GBA_KEY.A) end   --texto ou cena prendendo: avança
    end
    end)
    if not ok then log('ERRO '..tostring(err)) end
end)
