-- Avisos do modo Duplas para os momentos em que o jogo está parado esperando o parceiro (não dá para abrir a caixa
-- de texto do próprio jogo). Destinos:
--   1. faixa desenhada sobre a tela (API canvas + Painter do mGBA), quando o build desenha;
--   2. arquivo aviso.txt na pasta de dados, mostrado por tools/aviso-overlay.ps1 numa faixa sobre a janela do jogo;
--   3. aba "Duplas" na janela de Scripting do mGBA (Ferramentas > Scripting).
-- O mGBA de desenvolvimento incluído (build 9184) cria camadas mas não desenha nelas (Painter e Image falham com
-- "invoking failed"), então nele vale a aba. Os avisos também vão para o console. O jogo nunca depende disto.
local B={layer=nil,painter=nil,buffer=nil,text=nil,hint=nil,untilFrame=nil,frame=0,ok=nil}
local H=28
local FONTS={'C:/Windows/Fonts/segoeuib.ttf','C:/Windows/Fonts/segoeui.ttf','C:/Windows/Fonts/arial.ttf'}

-- faixa sobre a tela: só se o Painter realmente desenha (testado na criação)
local function initOverlay()
    if B.ok~=nil then return B.ok end
    B.ok=false
    if not canvas or not image then B.err='canvas_api_missing';return false end
    local ok,err=pcall(function()
        local w,h=canvas:screenWidth(),canvas:screenHeight()
        B.w=w
        local layer=canvas:newLayer(w,H)
        local painter=image.newPainter(layer.image)
        for _,font in ipairs(FONTS) do
            local f=io.open(font,'rb')
            if f then f:close();painter:loadFont(font);break end
        end
        painter:setFontSize(9)
        painter:setFill(true);painter:setFillColor(0x00000000);painter:drawRectangle(0,0,w,H)
        layer:setPosition(0,h-H);layer:update()
        B.layer,B.painter=layer,painter
    end)
    B.ok=ok;B.err=not ok and tostring(err) or nil
    return ok
end

local function drawOverlay(text,hint)
    pcall(function()
        local p=B.painter
        p:setBlend(false);p:setFill(true);p:setStrokeWidth(0)
        p:setFillColor(0x00000000);p:drawRectangle(0,0,B.w,H)
        if text then
            p:setFillColor(0xD8141210);p:drawRectangle(0,0,B.w,H)        --faixa escura translúcida
            p:setFillColor(0xFFE8783F);p:drawRectangle(0,0,B.w,1)        --linha de destaque quente
            p:setBlend(true)
            p:setFillColor(0xFFF4EDE2);p:drawText(text,6,hint and 3 or 8,1|16)
            if hint then p:setFillColor(0xFFB8AFA2);p:drawText(hint,6,15,1|16) end
        end
        B.layer:update()
    end)
end

-- aba "Duplas" na janela de Scripting
local function drawBuffer(text,hint)
    if not console or not console.createBuffer then return end
    pcall(function()
        if not B.buffer then B.buffer=console:createBuffer('Duplas') end
        B.buffer:clear()
        B.buffer:moveCursor(0,0);B.buffer:print('Modo Duplas')
        B.buffer:moveCursor(0,2);B.buffer:print(text or 'Sem avisos.')
        if hint then B.buffer:moveCursor(0,3);B.buffer:print(hint) end
    end)
end

-- arquivo lido pela faixa sobre a janela do jogo (tools/aviso-overlay.ps1, aberta pelo iniciar-demo.ps1)
local function drawFile(text,hint)
    local dir=DP and DP.Data
    if not dir then return end
    pcall(function()
        local f=io.open(dir..'/aviso.txt','wb')
        if f then f:write(text and (text..'\n'..(hint or '')) or '');f:close() end
    end)
end

local function draw(text,hint)
    if initOverlay() then drawOverlay(text,hint) end
    drawBuffer(text,hint)
    drawFile(text,hint)
end

-- mostra um aviso (hint = segunda linha); frames=nil mantém até o próximo show/hide
function B.show(text,frames,hint)
    B.untilFrame=frames and (B.frame+frames) or nil
    if B.text==text and B.hint==hint then return end
    if console then console:log('[Duplas] '..text..(hint and (' — '..hint) or '')) end
    B.text,B.hint=text,hint;draw(text,hint)
end

function B.hide()
    if not B.text then return end
    B.text,B.hint,B.untilFrame=nil,nil,nil;draw(nil)
end

function B.tick()
    B.frame=B.frame+1
    if B.untilFrame and B.frame>=B.untilFrame then B.hide() end
end

return B
