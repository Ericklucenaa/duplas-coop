-- Livro-razão da bolsa e da carteira compartilhadas do modo Duplas.
-- Lógica pura (sem emu/console): o anfitrião guarda o estado oficial e aplica cada operação dos jogadores uma única vez;
-- o cliente transforma o que mudou na própria RAM em operações e reconcilia quando o estado oficial chega.
--
-- Chaves do estado: "M" dinheiro, "C" fichas do Cassino, "p:id" item `id` no bolso `p` (1 itens, 2 chaves, 3 Poké Balls,
-- 4 TMs/HMs, 5 frutas). Quantidade 0 = ausente.
local L = {}

L.MAX = {M = 999999, C = 9999}
L.ITEM_MAX = 999

function L.max(key)
	return L.MAX[key] or L.ITEM_MAX
end

local function clamp(key, v)
	if v < 0 then return 0 end
	local m = L.max(key)
	if v > m then return m end
	return v
end

-- ---------------------------------------------------------------- anfitrião (autoridade)
function L.newHost(initial)
	local s = {ver = 0, values = {}, acks = {}, claims = {}, merged = {}, log = {}}
	for k, v in pairs(initial or {}) do
		if v > 0 then s.values[k] = clamp(k, v) end
	end
	return s
end

-- Aplica uma operação de `player`. op = {seq, key, delta, claim}
--   seq    número crescente por jogador: repetido ou antigo é ignorado (a mesma operação nunca vale duas vezes)
--   claim  opcional: flag do item do mapa que gerou o ganho; um segundo pedido da mesma flag é recusado (sem duplicar)
-- Retorna "ok" | "dup" | "claimed" | "clamped" e a quantidade efetivamente aplicada.
function L.apply(s, player, op)
	if type(op) ~= 'table' or type(op.seq) ~= 'number' or op.seq % 1 ~= 0 or op.seq < 1
		or not L.validKey(op.key) or type(op.delta) ~= 'number' or op.delta % 1 ~= 0
		or math.abs(op.delta) > 999999 then return 'invalid', 0 end
	local last = s.acks[player] or 0
	if op.seq <= last then return "dup", 0 end
	-- ACK cumulativo só pode avançar sobre uma sequência contínua.
	if op.seq ~= last + 1 then return 'gap', 0 end
	s.acks[player] = op.seq
	if op.claim and op.delta > 0 then
		local owner = s.claims[op.claim]
		if owner then
			s.log[#s.log + 1] = string.format("claim %s recusada para %s (já é de %s)", tostring(op.claim), player, owner)
			return "claimed", 0
		end
		s.claims[op.claim] = player
	end
	local before = s.values[op.key] or 0
	local after = clamp(op.key, before + op.delta)
	local applied = after - before
	if after == 0 then s.values[op.key] = nil else s.values[op.key] = after end
	if applied ~= 0 then s.ver = s.ver + 1 end
	if applied ~= op.delta then
		s.log[#s.log + 1] = string.format("%s: %s pediu %+d, aplicado %+d (tinha %d)", op.key, player, op.delta, applied, before)
		return "clamped", applied
	end
	return "ok", applied
end

-- Cópia rasa dos valores (o que é enviado aos jogadores)
function L.snapshot(s)
	local t = {}
	for k, v in pairs(s.values) do t[k] = v end
	return t
end

-- Chaves que mudaram entre duas fotos (a primeira pode ser nil: tudo)
function L.changed(old, new)
	local out = {}
	old = old or {}
	for k, v in pairs(new) do if old[k] ~= v then out[k] = v end end
	for k in pairs(old) do if new[k] == nil then out[k] = 0 end end
	return out
end

-- ---------------------------------------------------------------- cliente
-- shown = o que este jogador considera já contabilizado (estado oficial + operações enviadas e ainda não confirmadas)
function L.newClient()
	return {seq = 0, shown = nil, pending = {}}
end

-- Diferença entre a RAM e `shown`: vira operações numeradas (já somadas em shown e guardadas como pendentes).
-- claims: tabela opcional key -> flag (itens do mapa recolhidos neste intervalo).
function L.diff(c, ram, claims)
	local ops = {}
	if not c.shown then return ops end
	local keys = {}
	for k in pairs(ram) do keys[k] = true end
	for k in pairs(c.shown) do keys[k] = true end
	local sorted = {}
	for k in pairs(keys) do sorted[#sorted + 1] = k end
	table.sort(sorted)
	for _, k in ipairs(sorted) do
		local d = (ram[k] or 0) - (c.shown[k] or 0)
		while d ~= 0 do        --o pacote leva no máximo 6 dígitos: um salto maior vira várias operações
			local part = math.max(-999999, math.min(999999, d))
			c.seq = c.seq + 1
			local op = {seq = c.seq, key = k, delta = part, claim = part > 0 and claims and claims[k] or nil}
			ops[#ops + 1] = op
			c.pending[#c.pending + 1] = op
			d = d - part
		end
		c.shown[k] = ram[k] or 0
	end
	return ops
end

-- Registra uma mudança vista na RAM (base escolhida por quem chama). Igual a diff, para uma chave.
function L.record(c, key, d, claim)
	local ops = {}
	while d ~= 0 do
		local part = math.max(-999999, math.min(999999, d))
		c.seq = c.seq + 1
		local op = {seq = c.seq, key = key, delta = part, claim = part > 0 and claim or nil}
		ops[#ops + 1] = op
		c.pending[#c.pending + 1] = op
		c.shown[key] = clamp(key, (c.shown[key] or 0) + part)
		if c.shown[key] == 0 then c.shown[key] = nil end
		d = d - part
	end
	return ops
end

-- Operações ainda não confirmadas (reenviadas depois de uma reconexão; o anfitrião ignora as que já tinha aplicado)
function L.unacked(c)
	return c.pending
end

-- Primeira foto completa depois de conectar: a numeração continua de onde o anfitrião parou.
-- merge = true quando este jogador entra pela primeira vez na sessão: a bolsa dele é somada à da dupla (nada se perde).
function L.join(c, ack, merge)
	if ack > c.seq then c.seq = ack end
	if merge then c.shown = {} elseif not c.shown then c.shown = nil end
end

-- Foto completa recebida (entrada na sessão ou reconexão). Ordem importa: primeiro o que este jogador tem de seu vira
-- operação (na primeira entrada, a bolsa inteira; depois, nada além das pendentes), só então a RAM recebe o oficial.
-- Retorna as operações a enviar (novas + pendentes para reenviar) e o que a RAM deve passar a ter.
function L.onFull(c, ram, official, ack, merge, claims)
	L.join(c, ack, merge)
	if c.shown then L.diff(c, ram, claims) end
	local target = L.reconcile(c, official, ack)
	return c.pending, target
end

-- Chegou o estado oficial `official` com as operações deste jogador confirmadas até `ack`.
-- Retorna o que a RAM deve passar a ter: oficial + operações ainda não confirmadas.
function L.reconcile(c, official, ack)
	local keep = {}
	for _, op in ipairs(c.pending) do
		if op.seq > ack then keep[#keep + 1] = op end
	end
	c.pending = keep
	local target = {}
	for k, v in pairs(official) do target[k] = v end
	for _, op in ipairs(keep) do
		target[op.key] = clamp(op.key, (target[op.key] or 0) + op.delta)
		if target[op.key] == 0 then target[op.key] = nil end
	end
	c.shown = {}
	for k, v in pairs(target) do c.shown[k] = v end
	return target
end

-- ---------------------------------------------------------------- formato dos pacotes (cabem nos 43 caracteres do GBA-PK)
-- Operação: "DPO" seq(6) key(8, à direita com '.') delta(sinal+6) claim(4 hex ou "----")
function L.encodeOp(op)
	local key = op.key .. string.rep(".", 8 - #op.key)
	local claim = op.claim and string.format("%04X", op.claim) or "----"
	return string.format("DPO%06d%s%s%06d%s", op.seq % 1000000, key, op.delta < 0 and "-" or "+", math.abs(op.delta), claim)
end

function L.decodeOp(p)
	if string.sub(p, 1, 3) ~= "DPO" then return nil end
	local seq = tonumber(string.sub(p, 4, 9))
	local key = string.gsub(string.sub(p, 10, 17), "%.+$", "")
	local sign, num = string.sub(p, 18, 18), tonumber(string.sub(p, 19, 24))
	local claimText = string.sub(p, 25, 28)
	if not seq or not num or (sign ~= "+" and sign ~= "-") or not L.validKey(key) then return nil end
	return {seq = seq, key = key, delta = sign == "-" and -num or num, claim = claimText ~= "----" and tonumber(claimText, 16) or nil}
end

-- Entrada do estado oficial: "DPS" ver(6) key(8) qty(6)
function L.encodeEntry(ver, key, qty)
	return string.format("DPS%06d%s%06d", ver % 1000000, key .. string.rep(".", 8 - #key), qty)
end

function L.decodeEntry(p)
	if string.sub(p, 1, 3) ~= "DPS" then return nil end
	local ver = tonumber(string.sub(p, 4, 9))
	local key = string.gsub(string.sub(p, 10, 17), "%.+$", "")
	local qty = tonumber(string.sub(p, 18, 23))
	if not ver or not qty or not L.validKey(key) then return nil end
	return ver, key, qty
end

-- Fim de lote: "DPE" ver(6) ack(6) modo(1): 0 só mudanças, 1 foto completa, 2 foto completa + primeira entrada (somar a bolsa)
-- O cliente só aplica o lote inteiro.
function L.encodeEnd(ver, ack, mode)
	if mode == true then mode = 1 elseif not mode then mode = 0 end
	return string.format("DPE%06d%06d%d", ver % 1000000, ack % 1000000, mode)
end

function L.decodeEnd(p)
	if string.sub(p, 1, 3) ~= "DPE" then return nil end
	local ver, ack, mode = tonumber(string.sub(p, 4, 9)), tonumber(string.sub(p, 10, 15)), tonumber(string.sub(p, 16, 16))
	if not ver or not ack or not mode or mode > 2 then return nil end
	return ver, ack, mode
end

function L.validKey(k)
	if type(k) ~= 'string' then return false end
	if k == "M" or k == "C" then return true end
	local p, id = string.match(k, "^(%d):(%d+)$")
	p, id = tonumber(p), tonumber(id)
	return p ~= nil and p >= 1 and p <= 5 and id ~= nil and id > 0 and id < 1024
end

-- ---------------------------------------------------------------- persistência do anfitrião (texto simples, uma chave por linha)
function L.serialize(s)
	local lines = {"ver=" .. s.ver}
	local keys = {}
	for k in pairs(s.values) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do lines[#lines + 1] = "v." .. k .. "=" .. s.values[k] end
	local ps = {}
	for p in pairs(s.acks) do ps[#ps + 1] = p end
	table.sort(ps)
	for _, p in ipairs(ps) do lines[#lines + 1] = "ack." .. p .. "=" .. s.acks[p] end
	local cs = {}
	for f in pairs(s.claims) do cs[#cs + 1] = f end
	table.sort(cs)
	for _, f in ipairs(cs) do lines[#lines + 1] = "claim." .. f .. "=" .. s.claims[f] end
	local ms = {}
	for p in pairs(s.merged) do ms[#ms + 1] = p end
	table.sort(ms)
	for _, p in ipairs(ms) do lines[#lines + 1] = "merged." .. p .. "=1" end
	return table.concat(lines, "\n") .. "\n"
end

function L.deserialize(text)
	local s = L.newHost()
	for line in string.gmatch(text, "[^\n]+") do
		local k, v = string.match(line, "^(.-)=(.*)$")
		if k == "ver" then s.ver = tonumber(v) or 0
		elseif k and string.sub(k, 1, 2) == "v." then
			local key, n = string.sub(k, 3), tonumber(v)
			if L.validKey(key) and n and n > 0 then s.values[key] = clamp(key, n) end
		elseif k and string.sub(k, 1, 4) == "ack." then s.acks[string.sub(k, 5)] = tonumber(v) or 0
		elseif k and string.sub(k, 1, 6) == "claim." then s.claims[tonumber(string.sub(k, 7))] = v
		elseif k and string.sub(k, 1, 7) == "merged." then s.merged[string.sub(k, 8)] = true end
	end
	return s
end

return L
