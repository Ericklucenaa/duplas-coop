-- Modo Duplas. Abra no mGBA: Ferramentas > Scripting > Arquivo > Carregar script... > este arquivo.
-- Carrega o GBA-PK-multiplayer (vendor/gba-pk, sem alterações, CC BY-NC 4.0) e o modo Duplas por cima.
-- No menu MULTI do jogo: modo Coop e o código do parceiro. Sem parceiro conectado, o jogo segue individual.
-- Variáveis opcionais definidas antes: DP_GBAPK (caminho do GBA-PK_Multiplayer.lua), DP_DATA (pasta da sessão e backups).
local src = debug.getinfo(1, "S").source
DP_DIR = DP_DIR or (string.match(string.sub(src, 2), "^(.*)[/\\]") or ".")
local gbapk = DP_GBAPK or (DP_DIR .. "/../vendor/gba-pk/GBA-PK_Multiplayer.lua")
local function trace(stage)
    if DP_TRACE then local out=io.open(DP_TRACE,'a');if out then out:write(stage..'\n');out:close() end end
end

-- O GBA-PK guarda parte do estado em variáveis locais do arquivo. Esta ponte, acrescentada ao fim do mesmo trecho
-- (sem editar o arquivo), expõe só leitura para o modo Duplas.
local bridge = [[

function DPFrame() return TotalFrame end
function DPHosting() return Hosting end
function DPConnected() return Connected end
function DPGameID() return GameID end
function DPLock() return LockFromScript end
function DPServerAddress() return MPLastIP or IPAddress end
-- O fornecedor lê a porta do INI ao conectar, mas host() usa o local Port.
-- Fazer os dois lados respeitarem a mesma configuração evita hosts cruzados.
if MPIni and MPIni.port then Port=MPIni.port end
if MPIni and MPIni.ip then IPAddress=MPIni.ip end
-- O formato de rede legado usa palavras decimais; o adaptador nativo escreve
-- exatamente 100 bytes no slot, nunca os 250 caracteres desse formato.
function DPDecodeMon(raw) return MPStdParse(MPBytesFromRaw(raw)) end
function DPEncodeMon(fields)
    local bytes = MPStdBuild(fields)
    local out = {}
    for i = 0, 99 do out[#out + 1] = string.char(bytes[i]) end
    return table.concat(out)
end
function DPDecodeBytes(raw)
    assert(type(raw)=='string' and #raw==100, 'invalid Pokemon size')
    local bytes={};for i=0,99 do bytes[i]=raw:byte(i+1) end
    return MPStdParse(bytes)
end
]]
-- Testes na mesma máquina: com DP_BIND_ADDR (ex.: '127.0.0.1') as portas que o GBA-PK abre com endereço vazio
-- ficam só nesse endereço. Escutar apenas no próprio PC não dispara o aviso do Firewall do Windows.
-- No jogo de verdade entre dois PCs isto fica desligado (a porta precisa aceitar a rede).
if DP_BIND_ADDR and socket then
    pcall(function()
        local probe = socket.tcp()
        local mt = getmetatable(probe)
        local holder = mt and (type(mt.__index) == 'table' and mt.__index or mt)
        if holder and type(holder.bind) == 'function' and not holder.__dpBind then
            local bind = holder.bind
            holder.bind = function(self, address, port) return bind(self, address or DP_BIND_ADDR, port) end
            holder.__dpBind = true
        end
        if probe.close then probe:close() end
        if type(socket.bind) == 'function' and not socket.__dpBind then
            local moduleBind = socket.bind
            socket.bind = function(address, port) return moduleBind(address or DP_BIND_ADDR, port) end
            socket.__dpBind = true
        end
    end)
end
local f = assert(io.open(gbapk, "r"))
local code = f:read("a")
f:close()
local chunk = assert(load('local emu=DP_EMU or emu\n' .. code .. bridge, "@" .. gbapk))
trace('vendor-start')
chunk()
trace('vendor-ready')
dofile(DP_DIR .. "/duplas.lua")
trace('duplas-ready')
