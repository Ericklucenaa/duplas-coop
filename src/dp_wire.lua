-- Codec de dados, nunca executa Lua recebido pela rede/arquivo.
local function create(limits)
limits=limits or {}
local W={MAX_BYTES=limits.MAX_BYTES or 2*1024*1024,MAX_NODES=limits.MAX_NODES or 100000,MAX_DEPTH=limits.MAX_DEPTH or 24}
function W.encode(value)
    local nodes,seen=0,{}
    local function enc(v,depth)
        nodes=nodes+1;assert(nodes<=W.MAX_NODES and depth<=W.MAX_DEPTH,'wire_budget')
        if v==nil then return 'n' end
        if v==true then return 't' end
        if v==false then return 'f' end
        if type(v)=='number' then assert(math.type(v)=='integer','wire_integer');return 'i'..string.pack('>i8',v) end
        if type(v)=='string' then assert(#v<=W.MAX_BYTES,'wire_string');return 's'..string.pack('>I4',#v)..v end
        assert(type(v)=='table' and not seen[v],'wire_type_or_cycle');seen[v]=true
        local keys={};for k in pairs(v) do
            assert(type(k)=='string' or (type(k)=='number' and math.type(k)=='integer'),'wire_key')
            keys[#keys+1]=k
        end
        table.sort(keys,function(a,b) if type(a)~=type(b) then return type(a)<type(b) end return a<b end)
        local out={'m',string.pack('>I4',#keys)}
        for _,k in ipairs(keys) do out[#out+1]=enc(k,depth+1);out[#out+1]=enc(v[k],depth+1) end
        seen[v]=nil;return table.concat(out)
    end
    local out=enc(value,0);assert(#out<=W.MAX_BYTES,'wire_size');return out
end
function W.decode(bytes)
    assert(type(bytes)=='string' and #bytes<=W.MAX_BYTES,'wire_size')
    local pos,nodes=1,0
    local function take(n) assert(n>=0 and pos+n-1<=#bytes,'wire_truncated');local s=bytes:sub(pos,pos+n-1);pos=pos+n;return s end
    local function dec(depth)
        nodes=nodes+1;assert(nodes<=W.MAX_NODES and depth<=W.MAX_DEPTH,'wire_budget')
        local tag=take(1)
        if tag=='n' then return nil elseif tag=='t' then return true elseif tag=='f' then return false
        elseif tag=='i' then return (string.unpack('>i8',take(8)))
        elseif tag=='s' then local n=string.unpack('>I4',take(4));return take(n)
        elseif tag=='m' then
            local n=string.unpack('>I4',take(4));assert(n<=W.MAX_NODES//2,'wire_entries')
            local out={};for _=1,n do
                local key=dec(depth+1);assert(type(key)=='string' or (type(key)=='number' and math.type(key)=='integer'),'wire_key')
                assert(out[key]==nil,'wire_duplicate_key');local value=dec(depth+1);assert(value~=nil,'wire_nil_value');out[key]=value
            end;return out
        end
        error('wire_tag')
    end
    local result=dec(0);assert(pos==#bytes+1,'wire_trailing');return result
end
return W
end
local W=create()
W.new=create
return W
