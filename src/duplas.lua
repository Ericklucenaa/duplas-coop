-- Modo Duplas (cooperativo de Pokémon de GBA da 3ª geração) sobre o GBA-PK-multiplayer.
-- Carregado junto com o script do GBA-PK por iniciar-duplas.lua (o arquivo do fornecedor não é editado).
-- Vale quando o GBA-PK está no modo Coop e pareado com o parceiro. Sem parceiro, nada aqui age: o jogo segue individual.
--
-- O que este arquivo faz:
--   1. Bolsa, carteira e fichas compartilhadas, com o anfitrião como autoridade (dp_ledger.lua).
--   2. Progresso de história: insígnias, líderes/Elite Four/rival/chefes, flags de objetos e da história, itens escondidos,
--      pontos de voo e variáveis de cena (o maior valor vale para os dois).
--   3. Pokédex compartilhada (vistos e capturados).
--   4. Desliga o que o GBA-PK duplicaria com a bolsa compartilhada: cópia do item recolhido e do dinheiro do treinador.
-- Os Pokémon continuam no save de cada jogador (equipe, PC, níveis, IVs/EVs, evoluções).

local emu=DP_EMU or emu
DP = DP or {}
DP.Data = DP_DATA or DP_DIR          --onde ficam o arquivo da sessão e os backups
DP.Ledger = DP.Ledger or dofile(DP_DIR .. "/dp_ledger.lua")
local L = DP.Ledger

-- ------------------------------------------------------------------ endereços (FireRed 1.0 / pokefirered; verificados no save real)
DP.SB1, DP.SB2 = (DP_ADDR and DP_ADDR.saveBlock1Ptr) or 0x03005008, (DP_ADDR and DP_ADDR.saveBlock2Ptr) or 0x0300500C
DP.KEY_OFF = 0xF20                 --SaveBlock2.encryptionKey
DP.MONEY, DP.COINS = 0x290, 0x294
DP.FLAGS, DP.VARS = 0xEE0, 0x1000
DP.POCKETS = {                     --{deslocamento no SaveBlock1, espaços}
	{0x310, 42}, {0x3B8, 30}, {0x430, 13}, {0x464, 58}, {0x54C, 43},
}
DP.DEX_OWNED, DP.DEX_SEEN = 0x28, 0x5C      --SaveBlock2.pokedex
DP.DEX_SEEN1, DP.DEX_SEEN2 = 0x5F8, 0x3A18  --cópias de "vistos" no SaveBlock1
DP.DEX_BYTES = 52

-- ------------------------------------------------------------------ o que é da dupla
-- flags (pokefirered include/constants/flags.h)
DP.SharedFlags = {}
DP.MirrorFlags = {}                --também desligam juntas (objetos que aparecem/somem com a história)
do
	local function add(a, b, mirror)
		for n = a, b do DP.SharedFlags[n] = true if mirror then DP.MirrorFlags[n] = true end end
	end
	add(0x028, 0x0AE, true)        --objetos escondidos/mostrados (NPCs de história, Poké Balls no chão)
	add(0x154, 0x1FE, true)
	add(0x230, 0x2FF)              --eventos da história
	add(0x3E8, 0x4A6)              --itens escondidos já achados
	add(0x4B0, 0x4BC)              --chefes vencidos
	add(0x820, 0x829)              --insígnias, recebeu Pokémon, recebeu Pokédex
	add(0x82C, 0x82C)              --zerou o jogo
	add(0x82F, 0x82F)              --tênis de corrida
	add(0x840, 0x840)              --Pokédex nacional
	add(0x845, 0x84B)              --Ilhas Sevii, Berry Pouch, Deoxys, Tanoby, navios
	add(0x890, 0x8C2)              --pontos de voo
end
-- itens do mapa: flags que, recém-ligadas aqui, marcam a coleta (o anfitrião recusa a segunda coleta da mesma flag)
function DP.IsPickupFlag(n)
	return (n >= 0x028 and n <= 0x0AE) or (n >= 0x154 and n <= 0x1FE) or (n >= 0x3E8 and n <= 0x4A6)
end
-- variáveis de cena/história (vars.h): vale o maior valor. As de passos, recordes e cartão de treinador ficam com cada um.
DP.SharedVars = {[0x4031] = true, [0x4038] = true, [0x4039] = true, [0x403B] = true, [0x40B4] = true}
for v = 0x4050, 0x408B do DP.SharedVars[v] = true end
for _, v in ipairs({0x406D, 0x406F, 0x4072, 0x4077, 0x407A, 0x4087}) do DP.SharedVars[v] = nil end

-- Com o perfil do jogo carregado (modo nativo), tudo vem da organização do save da família: FireRed/LeafGreen,
-- Emerald ou Ruby/Sapphire. Os valores acima ficam só para o modo antigo (FireRed).
if DP_ADDR and DP_ADDR.layout then
	local lay = DP_ADDR.layout
	DP.KEY_OFF = lay.keyOffset                --nil em Ruby/Sapphire: dinheiro e quantidades sem chave
	DP.MONEY, DP.COINS = lay.money, lay.coins
	DP.FLAGS, DP.VARS = lay.flags, lay.vars
	DP.POCKETS = lay.pockets
	DP.DEX_OWNED, DP.DEX_SEEN = lay.dexOwned, lay.dexSeen
	DP.DEX_SEEN1, DP.DEX_SEEN2 = lay.seenCopies[1], lay.seenCopies[2]
	DP.SharedFlags, DP.SharedVars = {}, {}
	for _, r in ipairs(lay.sharedFlags) do for n = r[1], r[2] do DP.SharedFlags[n] = true end end
	for _, n in ipairs(lay.sharedFlagList) do DP.SharedFlags[n] = true end
	for _, n in ipairs(lay.excludeFlags) do DP.SharedFlags[n] = nil end
	for _, v in ipairs(lay.sharedVars) do DP.SharedVars[v] = true end
	for _, v in ipairs(lay.excludeVars or {}) do DP.SharedVars[v] = nil end
end

-- ------------------------------------------------------------------ estado
DP.st = nil
-- keep: livro-razão do anfitrião e estado do cliente (operações pendentes, base) continuam se o parceiro cair e voltar
DP.keep = DP.keep or {}
function DP.Reset()
	DP.st = {
		role = nil, partner = nil, me = nil, them = nil,
		host = DP.keep.host, savedVer = -1, dirty = false, lastSave = 0, lastBroadcast = nil,
		cli = DP.keep.cli, base = DP.keep.base, write = false, joined = false, nextJoin = 0, resendFlags = 0,
		inbox = {}, official = nil,
		flagSnap = nil, remoteFlags = {}, pickups = {},
		vars = {}, varIn = {}, nextVars = 0,
		dexSent = {}, dexIn = {}, nextDex = 0,
		nextBag = 0, nextResend = 0, durable = nil,
	}
end
DP.Reset()

function DP.Log(text) console:log("[Duplas] " .. text) end

-- ------------------------------------------------------------------ RAM
local function same(a, b)
	for k, v in pairs(a) do if b[k] ~= v then return false end end
	for k, v in pairs(b) do if a[k] ~= v then return false end end
	return true
end

function DP.Blocks()
	local sb1, sb2
	if DP_ADDR then sb1, sb2 = DP_ADDR.readSaveBlocks(emu) else sb1, sb2 = emu:read32(DP.SB1), emu:read32(DP.SB2) end
	if not MPInEwram(sb1) or not MPInEwram(sb2) then return nil end
	return sb1, sb2, DP.KEY_OFF and emu:read32(sb2 + DP.KEY_OFF) or 0
end

-- bolsa + dinheiro + fichas como tabela de chaves do livro-razão
function DP.ReadBag()
	local sb1, _, key = DP.Blocks()
	if not sb1 then return nil end
	local k16 = key & 0xFFFF
	local t = {}
	for p, pk in ipairs(DP.POCKETS) do
		for i = 0, pk[2] - 1 do
			local a = sb1 + pk[1] + i * 4
			local id = emu:read16(a)
			if id ~= 0 and id < 1024 then
				local q = emu:read16(a + 2) ~ k16
				if q > 0 then
					local kk = p .. ":" .. id
					t[kk] = (t[kk] or 0) + q
				end
			end
		end
	end
	local m = (emu:read32(sb1 + DP.MONEY) ~ key) & 0xFFFFFFFF
	if m > 0 then t.M = math.min(m, L.MAX.M) end
	local c = emu:read16(sb1 + DP.COINS) ~ k16
	if c > 0 then t.C = math.min(c, L.MAX.C) end
	return t
end

-- escreve a bolsa mantendo a ordem dos itens que o jogador já tem; os novos entram no fim do bolso
function DP.WriteBag(target)
	local sb1, _, key = DP.Blocks()
	if not sb1 then return false end
	local k16 = key & 0xFFFF
	for p, pk in ipairs(DP.POCKETS) do
		local order, seen = {}, {}
		for i = 0, pk[2] - 1 do
			local id = emu:read16(sb1 + pk[1] + i * 4)
			if id ~= 0 and not seen[id] then order[#order + 1] = id seen[id] = true end
		end
		local extra = {}
		for kk, q in pairs(target) do
			local pp, id = string.match(kk, "^(%d):(%d+)$")
			if tonumber(pp) == p and q > 0 and not seen[tonumber(id)] then extra[#extra + 1] = tonumber(id) end
		end
		table.sort(extra)
		for _, id in ipairs(extra) do order[#order + 1] = id end
		local slot = 0
		for _, id in ipairs(order) do
			local q = target[p .. ":" .. id] or 0
			if q > 0 then
				if slot >= pk[2] then
					DP.Log(string.format("bolso %d cheio: item %d (x%d) fica só na bolsa da dupla", p, id, q))
				else
					local a = sb1 + pk[1] + slot * 4
					if emu:read16(a) ~= id then emu:write16(a, id) end
					local enc = (math.min(q, L.ITEM_MAX) ~ k16) & 0xFFFF
					if emu:read16(a + 2) ~= enc then emu:write16(a + 2, enc) end
					slot = slot + 1
				end
			end
		end
		for i = slot, pk[2] - 1 do
			local a = sb1 + pk[1] + i * 4
			if emu:read16(a) ~= 0 then emu:write16(a, 0) end
			if emu:read16(a + 2) ~= k16 then emu:write16(a + 2, k16) end
		end
	end
	emu:write32(sb1 + DP.MONEY, ((target.M or 0) ~ key) & 0xFFFFFFFF)
	emu:write16(sb1 + DP.COINS, ((target.C or 0) ~ k16) & 0xFFFF)
	return true
end

function DP.FlagOn(sb1, n)
	return (emu:read8(sb1 + DP.FLAGS + (n >> 3)) & (1 << (n & 7))) ~= 0
end

-- o jogador está livre (no mapa, sem script, menu, batalha ou mensagem): pode escrever na RAM
function DP.FreeParts()
	local g = gAddress[DPGameID()]
	return string.format("menu=%d lock=%d script=%d lockScript=%d msg=%d after=%s post=%s", IsInMenu(), emu:read8(g.gLockControls),
		emu:read8(g.gScriptLoad), DPLock(), ServerMsgStart, tostring(MPVs and MPVs.after ~= nil), tostring(MPVs and MPVs.post ~= nil))
end
function DP.Free()
	local g = gAddress[DPGameID()]
	return IsInMenu() == 0 and emu:read8(g.gLockControls) == 0 and emu:read8(g.gScriptLoad) == 2
		and DPLock() == 0 and ServerMsgStart < 0 and not (MPVs and (MPVs.after or MPVs.post))
end

-- ------------------------------------------------------------------ rede (pacotes "PRGS" do GBA-PK com o prefixo DP)
function DP.Send(payload)
	if not DP.st.partner then return false end
	return MPSendPacket("PRGS", DP.st.partner, payload)
end

local origProgressReceive = MPProgressReceive
function MPProgressReceive(id, data)
	if string.sub(data, 21, 22) == "DP" then
		local ok, err = pcall(DP.Receive, id, string.sub(data, 21, 63))
		if not ok then DP.Log("erro ao receber: " .. tostring(err)) end
		return
	end
	return origProgressReceive(id, data)
end

function DP.Receive(id, p)
	local st = DP.st
	if not st.role or id ~= st.partner then return end
	local kind = string.sub(p, 1, 3)
	if kind == "DPO" and st.role == "host" then
		local op = L.decodeOp(p)
		if op then st.inbox[#st.inbox + 1] = op end
	elseif kind == "DPJ" and st.role == "host" then
		st.wantFull = true
	elseif kind == "DPM" and st.role == "host" then
		st.host.merged[st.them] = true
		st.dirty = true
		DP.Log("bolsa do parceiro somada à da dupla")
	elseif kind == "DPS" and st.role == "guest" then
		local _, key, qty = L.decodeEntry(p)
		if key then st.batch = st.batch or {} st.batch[key] = qty end
	elseif kind == "DPE" and st.role == "guest" then
		local ver, ack, mode = L.decodeEnd(p)
		if ver then DP.GuestOfficial(ack, mode, st.batch or {}) end
		st.batch = nil
	elseif kind == "DPV" then
		local var, val = tonumber(string.sub(p, 4, 7), 16), tonumber(string.sub(p, 8, 11), 16)
		if var and val and DP.SharedVars[var] then st.varIn[var] = math.max(st.varIn[var] or 0, val) end
	elseif kind == "DPD" then
		local which, part, hex = string.sub(p, 4, 4), tonumber(string.sub(p, 5, 5)), string.sub(p, 6, 41)
		if (which == "o" or which == "s") and part and part <= 2 then
			st.dexIn[#st.dexIn + 1] = {which = which, at = part * 18, hex = hex}
		end
	end
end

-- ------------------------------------------------------------------ bolsa: anfitrião
function DP.SessionPath()
	return DP.Data .. "/duplas-sessao-" .. tostring(MPIni.code) .. ".txt"
end

function DP.HostStart(ram)
	local st = DP.st
	local f = io.open(DP.SessionPath(), "r")
	if f then
		st.host = L.deserialize(f:read("a"))
		f:close()
		DP.Log("sessão carregada: versão " .. st.host.ver)
	else
		st.host = L.newHost(ram)
		st.host.merged[st.me] = true
		st.dirty = true
		DP.Log("sessão nova a partir da bolsa do anfitrião")
	end
	st.cli = L.newClient()
	L.join(st.cli, st.host.acks[st.me] or 0, false)
	st.cli.shown = L.snapshot(st.host)
	st.base = ram
	st.write = true                   --a RAM do anfitrião passa a ser a da sessão (igual na sessão nova)
	st.wantFull = false
	DP.keep.host, DP.keep.cli = st.host, st.cli
end

function DP.HostSave(force)
	local st = DP.st
	if not st.dirty then return true end
	if not force and DPFrame() - st.lastSave < 120 then return false end
	local path = DP.SessionPath()
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then return false end
	local written = f:write(L.serialize(st.host))
	local flushed = f:flush()
	local closed = f:close()
	if not written or not flushed or not closed then return false end
	local old = io.open(path, 'r')
	local hadOld = old ~= nil
	if old then old:close() end
	os.remove(path .. ".bak")
	if hadOld and not os.rename(path, path .. '.bak') then return false end
	if os.rename(tmp, path) then
		st.dirty = false
		st.lastSave = DPFrame()
		return true
	end
	if hadOld then os.rename(path .. '.bak', path) end
	return false
end

function DP.HostBroadcast(full)
	local st = DP.st
	-- Não reconhecer operações apenas na RAM: uma queda não deve permitir
	-- reaplicar um ganho que o parceiro já considerou confirmado.
	local durable = L.serialize(st.host)
	if durable ~= st.durable then st.dirty = true end
	if not DP.HostSave(true) then return false end
	st.durable = durable
	local snap = L.snapshot(st.host)
	-- Uma campanha tem uma única bolsa. Somar a bolsa de uma cópia do mesmo
	-- save na primeira conexão duplicava todos os itens e o dinheiro.
	local merge = false
	local changes = full and snap or L.changed(st.lastBroadcast, snap)
	local any = full
	for k, v in pairs(changes) do
		DP.Send(L.encodeEntry(st.host.ver, k, v))
		any = true
	end
	local ack = st.host.acks[st.them] or 0
	if any or ack ~= st.lastAck then
		DP.Send(L.encodeEnd(st.host.ver, ack, merge and 2 or (full and 1 or 0)))
	end
	st.lastAck = ack
	st.lastBroadcast = snap
end

-- ------------------------------------------------------------------ bolsa: convidado
function DP.GuestOfficial(ack, mode, entries)
	local st = DP.st
	local ram = DP.ReadBag()
	if not ram then return end
	if mode >= 1 then
		if not st.joined then DP.Backup(ram) end
		st.official = entries
		local ops
		if mode ~= 2 and st.cli.shown and st.base then
			-- volta do mesmo parceiro: o que mudou enquanto estava fora vira operação; as pendentes são reenviadas
			-- (o anfitrião ignora as que já tinha aplicado)
			DP.Capture(ram)
			L.join(st.cli, ack, false)
			for _, op in ipairs(L.unacked(st.cli)) do DP.Send(L.encodeOp(op)) end
			L.reconcile(st.cli, entries, ack)
			ops = L.unacked(st.cli)
		else
			ops = L.onFull(st.cli, ram, entries, ack, mode == 2, DP.Claims(ram))
			for _, op in ipairs(ops) do DP.Send(L.encodeOp(op)) end
		end
		DP.keep.cli = st.cli
		if mode == 2 then
			DP.Backup(ram)
			DP.Send("DPM")
			MPSay("Duplas: sua bolsa e seu dinheiro\nforam somados aos da dupla.")
		elseif not st.joined then
			MPSay("Duplas: bolsa da dupla\nsincronizada.")
		end
		st.joined = true
		st.base = ram
		st.write = true
		DP.Log(string.format("foto completa (modo %d, %d operações pendentes)", mode, #ops))
		return
	end
	if not st.joined then return end
	for k, v in pairs(entries) do
		if v == 0 then st.official[k] = nil else st.official[k] = v end
	end
	DP.Capture(ram)
	L.reconcile(st.cli, st.official, ack)
	if not same(st.cli.shown, ram) then st.write = true end
end

function DP.Backup(ram)
	local f = io.open(DP.Data .. "/duplas-backup-bolsa-" .. tostring(MPIni.code) .. "-" .. os.date("%Y%m%d-%H%M%S") .. ".txt", "w")
	if not f then return end
	local keys = {}
	for k in pairs(ram) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do f:write(k .. "=" .. ram[k] .. "\n") end
	f:close()
end

-- ------------------------------------------------------------------ bolsa: os dois lados
-- itens do mapa recolhidos desde a última leitura: chave da bolsa -> flag (só quando há um ganho e uma flag, sem ambiguidade)
function DP.Claims(ram)
	local st = DP.st
	local claims = {}
	if #st.pickups == 1 and st.base then
		local gained = {}
		for k, v in pairs(ram) do
			if k ~= "M" and k ~= "C" and v > (st.base[k] or 0) then gained[#gained + 1] = k end
		end
		if #gained == 1 then claims[gained[1]] = st.pickups[1] end
	end
	st.pickups = {}
	return claims
end

-- o que mudou na RAM desde a base vira operação (anfitrião: aplica direto; convidado: envia)
function DP.Capture(ram)
	local st = DP.st
	if not st.cli or not st.cli.shown or not st.base then return end
	local claims = DP.Claims(ram)
	local keys = {}
	for k in pairs(ram) do keys[k] = true end
	for k in pairs(st.base) do keys[k] = true end
	local list = {}
	for k in pairs(keys) do list[#list + 1] = k end
	table.sort(list)
	for _, k in ipairs(list) do
		local d = (ram[k] or 0) - (st.base[k] or 0)
		if d ~= 0 then
			for _, op in ipairs(L.record(st.cli, k, d, claims[k])) do
				if st.role == "host" then
					local res = L.apply(st.host, st.me, op)
					if res ~= "ok" then DP.Log("operação própria " .. k .. ": " .. res) end
				else
					DP.Send(L.encodeOp(op))
				end
			end
		end
	end
	st.base = ram
	DP.keep.base = ram
end

function DP.BagTick()
	local st = DP.st
	if DPFrame() < st.nextBag then return end
	st.nextBag = DPFrame() + 15
	local ram = DP.ReadBag()
	if not ram then return end
	if st.role == "host" then
		if not st.host then DP.HostStart(ram) end
		DP.Capture(ram)                   --mudanças do próprio anfitrião: aplicadas direto
		table.sort(st.inbox, function(a,b) return a.seq < b.seq end)
		local waiting = {}
		for _, op in ipairs(st.inbox) do
			local res, applied = L.apply(st.host, st.them, op)
			if res == 'gap' and #waiting < 1024 then waiting[#waiting+1] = op end
			if res ~= "ok" and res ~= "dup" then DP.Log(string.format("operação do parceiro %s %+d: %s (%+d)", op.key, op.delta, res, applied)) end
		end
		st.inbox = waiting
		L.reconcile(st.cli, L.snapshot(st.host), st.host.acks[st.me] or 0)
		if not same(st.cli.shown, ram) then st.write = true end
		if st.wantFull then
			st.wantFull = false
			DP.HostBroadcast(true)
		elseif st.lastBroadcast then
			DP.HostBroadcast(false)
		end
		if st.host.ver ~= st.savedVer then st.dirty = true st.savedVer = st.host.ver end
		DP.HostSave()
	else
		if not st.joined then
			if DPFrame() >= st.nextJoin then
				st.nextJoin = DPFrame() + 180
				if not st.cli then st.cli = L.newClient() DP.keep.cli = st.cli end
				DP.Send("DPJ")
			end
			return
		end
		DP.Capture(ram)
		if DPFrame() >= st.nextResend then
			st.nextResend = DPFrame() + 180
			for _,op in ipairs(L.unacked(st.cli)) do DP.Send(L.encodeOp(op)) end
		end
	end
	if st.write and DP.Free() then
		DP.Capture(DP.ReadBag())          --o que o jogador fez desde a última leitura entra antes de escrever
		if st.role == "host" then L.reconcile(st.cli, L.snapshot(st.host), st.host.acks[st.me] or 0) end
		DP.WriteBag(st.cli.shown)
		st.base = DP.ReadBag()
		DP.keep.base = st.base
		st.write = false
	end
end

-- ------------------------------------------------------------------ flags (via o canal de flags do GBA-PK)
local origWorldSet = MPCoopWorldSet
function MPCoopWorldSet()
	local t = origWorldSet()
	if DP.Active() and DP.extended ~= t then        --a tabela do GBA-PK só pode ter números de flag
		for n in pairs(DP.SharedFlags) do t[n] = true end
		DP.extended = t
	end
	return t
end
for n in pairs(DP.MirrorFlags) do MPCoopToggle[n] = true end

-- os líderes, a Elite Four, o rival e os chefes também ficam vencidos para os dois
local origTrainerShared = MPCoopTrainerShared
function MPCoopTrainerShared(trainer)
	if DP.Active() then return true end
	return origTrainerShared(trainer)
end

-- com a bolsa compartilhada, o GBA-PK não pode dar uma cópia do item nem do dinheiro ao parceiro
local origItemTick = MPCoopItemTick
function MPCoopItemTick()
	if DP.Active() then MPCoopItemQueue = {} return end
	return origItemTick()
end
local origAddMoney = MPAddMoney
function MPAddMoney(n)
	if DP.Active() then return 0 end
	return origAddMoney(n)
end

-- flags que chegam do parceiro não são coleta deste jogador
local origCoopTick = MPCoopTick
function MPCoopTick()
	for _, n in ipairs(MPCoopIn) do DP.st.remoteFlags[n] = true end
	return origCoopTick()
end

function DP.FlagTick(sb1)
	local st = DP.st
	local now = {}
	for n in pairs(DP.SharedFlags) do
		if DP.IsPickupFlag(n) then now[n] = DP.FlagOn(sb1, n) end
	end
	if st.flagSnap then
		for n, on in pairs(now) do
			if on and not st.flagSnap[n] and not st.remoteFlags[n] then st.pickups[#st.pickups + 1] = n end
		end
	end
	st.flagSnap = now
	st.remoteFlags = {}
end

-- ------------------------------------------------------------------ variáveis de história
function DP.VarTick(sb1)
	local st = DP.st
	if DPFrame() < st.nextVars then return end
	st.nextVars = DPFrame() + 30
	local free = DP.Free()
	for v in pairs(DP.SharedVars) do
		local a = sb1 + DP.VARS + (v - 0x4000) * 2
		local val = emu:read16(a)
		local inc = st.varIn[v]
		if inc and inc > val and free then
			emu:write16(a, inc)
			val = inc
		end
		if inc and (inc <= val) then st.varIn[v] = nil end
		if st.vars[v] ~= val then
			if st.vars[v] ~= nil or val ~= 0 then DP.Send(string.format("DPV%04X%04X", v, val)) end
			st.vars[v] = val
		end
	end
end

-- ------------------------------------------------------------------ Pokédex
function DP.DexTick(sb1, sb2)
	local st = DP.st
	for _, d in ipairs(st.dexIn) do
		for i = 0, 17 do
			local at = d.at + i
			local byte = tonumber(string.sub(d.hex, i * 2 + 1, i * 2 + 2), 16)
			if at < DP.DEX_BYTES and byte and byte ~= 0 then
				local targets = d.which == "o" and {sb2 + DP.DEX_OWNED} or {sb2 + DP.DEX_SEEN, sb1 + DP.DEX_SEEN1, sb1 + DP.DEX_SEEN2}
				for _, base in ipairs(targets) do
					local old = emu:read8(base + at)
					if old | byte ~= old then emu:write8(base + at, old | byte) end
				end
			end
		end
	end
	st.dexIn = {}
	if DPFrame() < st.nextDex then return end
	st.nextDex = DPFrame() + 300
	for which, off in pairs({o = DP.DEX_OWNED, s = DP.DEX_SEEN}) do
		for part = 0, 2 do
			local hex = {}
			for i = 0, 17 do
				local at = part * 18 + i
				hex[#hex + 1] = string.format("%02X", at < DP.DEX_BYTES and emu:read8(sb2 + off + at) or 0)
			end
			local text = table.concat(hex)
			local tag = which .. part
			if st.dexSent[tag] ~= text then
				st.dexSent[tag] = text
				DP.Send("DPD" .. which .. part .. text)
			end
		end
	end
end

-- ------------------------------------------------------------------ ciclo
function DP.Active()
	return DP.st.role ~= nil
end

function DP.Tick()
	if DP.RuntimeManaged then return end
	local st = DP.st
	local partner = MPCoopActive and MPCoopPartner or nil
	if not partner or MPGameMode() ~= "Coop" or not (DPHosting() or DPConnected()) then
		if st.role then DP.Log("parceiro saiu: modo Duplas em pausa") DP.HostSave(true) end
		if st.role then DP.Reset() MPCoopWorldFlags = nil end
		return
	end
	if not st.role then
		st.role = DPHosting() and "host" or "guest"
		st.partner = partner
		st.me = tostring(MPIni.code)
		st.them = tostring(MPFriendCodes[partner] or partner)
		MPCoopWorldFlags = nil           --a lista de flags compartilhadas passa a incluir as do modo Duplas
		DP.Log("ativo como " .. (st.role == "host" and "anfitrião" or "convidado") .. ", parceiro " .. st.them)
		MPCoopSendAll()
		st.resendFlags = DPFrame() + 300
	end
	if st.resendFlags > 0 and DPFrame() >= st.resendFlags then
		-- o parceiro pode ter ativado o modo Duplas depois de mandar as flags dele: pede de novo, uma vez
		st.resendFlags = 0
		MPSendPacket("TRRQ", partner, "")
		MPCoopSendAll()
	end
	local sb1, sb2 = DP.Blocks()
	if not sb1 then return end
	DP.FlagTick(sb1)
	DP.BagTick()
	DP.VarTick(sb1)
	DP.DexTick(sb1, sb2)
end

local origTick = MPTick
function MPTick()
	origTick()
	local ok, err = pcall(DP.Tick)
	if not ok and tostring(err) ~= DP.lastError then      --cada erro diferente aparece uma vez
		DP.lastError = tostring(err)
		DP.Log("erro: " .. DP.lastError)
	end
end

DP.Log("modo Duplas carregado")
