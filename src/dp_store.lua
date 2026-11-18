-- Escrita recuperável no Windows. ACKs só devem sair após save() retornar true.
local M={}
function M.new(path,codec)
    assert(type(path)=='string' and codec)
    local store={path=path,codec=codec}
    function store:load()
        local errors={}
        for _,name in ipairs({self.path,self.path..'.bak'}) do
            local f=io.open(name,'rb')
            if f then
                local bytes=f:read('a');f:close();local ok,data=pcall(self.codec.decode,bytes)
                if ok and type(data)=='table' and data.schema==1 then return data,name end
                errors[#errors+1]=name..': invalid checkpoint'
            end
        end
        return nil,#errors>0 and table.concat(errors,'; ') or 'not_found'
    end
    function store:save(data)
        local ok,bytes=pcall(self.codec.encode,data);if not ok then return false,bytes end
        local temp=self.path..'.tmp';local f,err=io.open(temp,'wb');if not f then return false,err end
        local written,writeErr=f:write(bytes)
        local flushed,flushErr=f:flush();local closed,closeErr=f:close()
        if not written or not flushed or not closed then return false,writeErr or flushErr or closeErr end
        local old=io.open(self.path,'rb');local hadOld=old~=nil;if old then old:close() end
        if hadOld then
            os.remove(self.path..'.bak')
            local moved,moveErr=os.rename(self.path,self.path..'.bak');if not moved then return false,moveErr end
        end
        local replaced,replaceErr=os.rename(temp,self.path)
        if not replaced then
            if hadOld then os.rename(self.path..'.bak',self.path) end
            return false,replaceErr
        end
        return true
    end
    return store
end
return M
