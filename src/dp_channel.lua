-- Canal TCP não bloqueante. Uma chamada tick tem orçamento fixo; socket lento
-- nunca prende o emulador num laço de espera. Credencial vem do pareamento.
local C={MAX_QUEUE=8*1024*1024,MAX_RX=4*1024*1024,IO_BUDGET=256*1024}
function C.new(codec,config)
    assert(config.localId and config.peerId and config.token and #config.token>=16,'pairing_required')
    local ch={codec=codec,config=config,socket=nil,server=nil,rx='',tx={},offset=1,queued=0,
        authenticated=false,helloSent=false,closed=false,lastReceive=0}
    function ch:drop(reason)
        if self.socket then pcall(function() self.socket:close() end) end
        self.socket=nil;self.rx='';self.tx={};self.offset=1;self.queued=0
        self.authenticated=false;self.helloSent=false
        if self.config.onDrop then self.config.onDrop(reason) end
    end
    function ch:attach(sock,now)
        if self.socket then return false,'already_connected' end
        self.socket=sock;self.lastReceive=now or 0
        return self:send({kind='hello',version=1,id=self.config.localId,peer=self.config.peerId,
            token=self.config.token},true)
    end
    function ch:send(message,handshake)
        if not self.socket then return false,'offline' end
        if not self.authenticated and not handshake then return false,'not_paired' end
        local ok,bytes=pcall(self.codec.encode,message);if not ok then return false,'invalid_message: '..tostring(bytes) end
        bytes=string.pack('>I4',#bytes)..bytes
        if self.queued+#bytes>C.MAX_QUEUE then return false,'backpressure' end
        self.tx[#self.tx+1]=bytes;self.queued=self.queued+#bytes;return true
    end
    function ch:feed(bytes,now)
        if #self.rx+#bytes>C.MAX_RX then self:drop('receive_limit');return false end
        self.rx=self.rx..bytes
        local processed=0
        while #self.rx>=4 and processed<64 do
            local length=string.unpack('>I4',self.rx)
            if length==0 or length>self.codec.MAX_BYTES then self:drop('frame_limit');return false end
            if #self.rx<length+4 then break end
            local payload=self.rx:sub(5,length+4);self.rx=self.rx:sub(length+5)
            local ok,message=pcall(self.codec.decode,payload)
            if not ok or type(message)~='table' then self:drop('invalid_frame');return false end
            self.lastReceive=now;processed=processed+1
            if not self.authenticated then
                if message.kind~='hello' or message.version~=1 or message.id~=self.config.peerId
                    or message.peer~=self.config.localId or message.token~=self.config.token then
                    self:drop('pairing_mismatch');return false
                end
                self.authenticated=true
                if self.config.onReady then self.config.onReady() end
            elseif message.kind=='hello' then self:drop('duplicate_handshake');return false
            elseif message.kind~='ping' and self.config.onMessage then self.config.onMessage(message) end
        end
        return true
    end
    function ch:tick(now,again)
        if not self.socket then return end
        local sock=self.socket;local budget=C.IO_BUDGET
        while self.tx[1] and budget>0 do
            local bytes=self.tx[1];local last=math.min(#bytes,self.offset+budget-1)
            -- Enviar uma substring faz o retorno ser relativo à própria string,
            -- independentemente da semântica de índices opcionais do mGBA.
            local sent,err=sock:send(bytes:sub(self.offset,last))
            if sent and sent>0 then
                self.offset=self.offset+sent;self.queued=self.queued-sent;budget=budget-sent
                if self.offset>#bytes then table.remove(self.tx,1);self.offset=1 end
            elseif err and err~=again then self:drop('send_error');return
            else break end
        end
        budget=C.IO_BUDGET
        while budget>0 and self.socket==sock do
            local bytes,err=sock:receive(math.min(65536,budget))
            if bytes and #bytes>0 then
                self.lastReceive=now
                budget=budget-#bytes;if not self:feed(bytes,now) then return end
            elseif err and err~=again then self:drop('receive_error');return
            else break end
        end
        -- Processar também os quadros já completos que sobraram do orçamento.
        if self.socket and not self:feed('',now) then return end
        if self.socket and now-self.lastReceive>(self.config.timeout or 600) then self:drop('timeout') end
    end
    function ch:close()
        self:drop('closed');self.closed=true
        if self.server then pcall(function() self.server:close() end);self.server=nil end
    end
    return ch
end
return C
