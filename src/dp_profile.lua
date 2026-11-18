-- Endereços do jogo usados pelo modo Duplas, num lugar só.
-- Os valores abaixo são do FireRed 1.0 (EUA), usados quando não há perfil. Para outra ROM, a ferramenta gera um perfil
-- (perfil.lua) localizando cada endereço por assinatura de código; DP_PROFILE aponta para esse arquivo e os valores
-- dele substituem estes. Nenhum módulo deve ter endereço fixo fora daqui.
local P={
    name='FireRed 1.0 (EUA)', family='FRLG', gameCode=0x45525042, revision=0,   --'BPRE'
    -- rotinas da ROM (pontos de parada e ponteiros de função comparados)
    readKeysR1=0x080005ee,          --ReadKeys, logo depois de ler REG_KEYINPUT em r1
    cb2InitBattle=0x0800fd9c,       --CB2_InitBattle
    cb2Overworld=0x080565b4,        --CB2_Overworld (mapa livre)
    cb2EndWildBattle=0x0807fb40,    --volta de batalha selvagem comum (salva em gMain.savedCallback)
    encounterKindHook=0x08082aec,   --gerador de selvagens: tipo do encontro em r1
    fishingHook=0x08082b64,         --pesca: vara em r1
    battleReplenish=0x08011100,     --troca de Pokémon desmaiado
    battleEnemyCount=0x080112e0,    --quantidade de inimigos
    battleSkipRoutine=0x080443f4,   --rotina pulada durante a batalha em dupla
    partyOtCheck=0x0804425c,        --dono original (obediência)
    partyMenuHook=0x080cdda8,       --menu de equipe na batalha
    ctrlRunCommand=0x0802e3b4,      --controlador do jogador: executa o comando recebido (ocioso)
    ctrlActionInput=0x0802e438,     --controlador: escolha de ação
    ctrlTargetInput=0x0802e674,     --controlador: escolha de alvo
    ctrlMoveInput=0x0802ea10,       --controlador: escolha de golpe
    battleCloseParty=0x0802e33c,    --fim da escolha de Pokémon
    textController=0x08030610,      --controlador esperando o texto da batalha
    itemEffect=0x080413c0,          --ExecuteTableBasedItemEffect
    removeBagItem=0x0809a1d8,       --RemoveBagItem
    -- tabelas da ROM
    controllersTable=0x0825089c,    --funções dos controladores do jogador
    commandsTable=0x0825011c,       --comandos de script de batalha
    itemsTable=0x083db028,          --gItems (44 bytes por item; bolso no byte 26)
    wildHeaders=0x087331c0,         --cabeçalhos de encontros selvagens
    -- espaço livre da ROM usado pelo modo Duplas (0x200 bytes)
    cave=0x08ef0000,
    -- memória (RAM)
    gMain=0x030030f0,               --callback1; +4 callback2; +8 savedCallback; +0x28.. botões
    saveBlock1Ptr=0x03005008, saveBlock2Ptr=0x0300500c, storagePtr=0x03005010,
    rngValue=0x03005000,
    controllerFuncs=0x03004fe0,     --função atual do controlador de cada batalhador
    party=0x02024284, partyCount=0x02024029,
    enemyParty=0x0202402c, enemyPartyCount=0x0202402a,
    battleTypeFlags=0x02022b4c,
    battleBufferA=0x02022bc4, battleBufferB=0x020233c4,
    activeBattler=0x02023bc4, battlerPartyIndexes=0x02023bce, battleMons=0x02023be4,
    attacker=0x02023d6b, target=0x02023d6c, absentFlags=0x02023d70, battlescriptPtr=0x02023d74,
    battleOutcome=0x02023e8a,
}
-- Organização do save por família (pret: include/global.h, constants/flags.h e vars.h de cada jogo).
-- sb = deslocamento no SaveBlock1 (dex = SaveBlock2). keyOffset: chave que embaralha dinheiro e quantidades (Ruby/Sapphire
-- não têm). sharedFlags: faixas de flags da campanha da dupla; sharedFlagList: flags avulsas (sistema); excludeFlags:
-- flags que dependem dos Pokémon de cada um (ovo da creche). sharedVars: variáveis de cena/história.
local function faixa(a,b) local t={} for v=a,b do t[#t+1]=v end return t end
local function juntar(...) local t={} for _,l in ipairs({...}) do for _,v in ipairs(l) do t[#t+1]=v end end return t end
-- Emerald e Ruby/Sapphire numeram os bolsos na tabela de itens como Itens, Poké Balls, TM/HM, Frutas, Itens-chave;
-- no save a ordem é Itens, Itens-chave, Poké Balls, TM/HM, Frutas (a do FireRed/LeafGreen nas duas)
local HOENN_POCKETS={[1]=1,[2]=3,[3]=4,[4]=5,[5]=2}
local LAYOUTS={
    FRLG={keyOffset=0xF20, money=0x290, coins=0x294, flags=0xEE0, vars=0x1000,
        pockets={{0x310,42},{0x3B8,30},{0x430,13},{0x464,58},{0x54C,43}},
        dexOwned=0x28, dexSeen=0x5C, seenCopies={0x5F8,0x3A18},
        nationalFlag=0x840, nationalMagicOffset=0x1B, nationalMagicValue=0xB9,
        sharedFlags={{0x020,0x4FF},{0x500,0x7FF},{0x820,0x8FF}}, sharedFlagList={}, excludeFlags={0x266},
        rewardFlags={{0x020,0x4FF},{0x500,0x7FF},{0x820,0x829}}, flagMax=0x8FF,
        sharedVars=juntar({0x4024,0x4031,0x4033,0x4036,0x4038,0x4039,0x403B,0x403E,0x404E,0x40B4},faixa(0x4050,0x408B)),
        excludeVars={0x406D,0x406F,0x4072,0x4077,0x407A,0x4087}},
    E={keyOffset=0xAC, money=0x490, coins=0x494, flags=0x1270, vars=0x139C,
        pockets={{0x560,30},{0x5D8,30},{0x650,16},{0x690,64},{0x790,46}},
        pocketFromTable=HOENN_POCKETS,
        dexOwned=0x28, dexSeen=0x5C, seenCopies={0x988,0x3B24},
        nationalFlag=0x896, nationalMagicOffset=0x1A, nationalMagicValue=0xDA,
        sharedFlags={{0x020,0x4FF},{0x500,0x85F}},
        sharedFlagList=juntar({0x860,0x861,0x862,0x864},faixa(0x867,0x87E),{0x896,0x8C0}), excludeFlags={0x86},
        rewardFlags={{0x020,0x4FF},{0x500,0x85F},{0x860,0x86E}}, flagMax=0x95F,
        sharedVars=juntar({0x4023,0x4046},faixa(0x4050,0x4060),{0x4063,0x4069,0x406F,0x4071,0x4072,0x4074,0x407B},
            {0x4082},faixa(0x4084,0x4087),faixa(0x408C,0x4099),{0x409A,0x409C,0x409E,0x409F,0x40A0},faixa(0x40A2,0x40A7),
            faixa(0x40A9,0x40B7),faixa(0x40B9,0x40BA),faixa(0x40BC,0x40D4),faixa(0x40D6,0x40DA)),
        excludeVars={0x4087}},
    RS={keyOffset=nil, money=0x490, coins=0x494, flags=0x1220, vars=0x1340,
        pockets={{0x560,20},{0x5B0,20},{0x600,16},{0x640,64},{0x740,46}},
        pocketFromTable=HOENN_POCKETS,
        dexOwned=0x28, dexSeen=0x5C, seenCopies={0x938,0x3A8C},
        nationalFlag=0x836, nationalMagicOffset=0x1A, nationalMagicValue=0xDA,
        sharedFlags={{0x021,0x4FF},{0x500,0x7B4}},
        sharedFlagList=juntar({0x800,0x801,0x802,0x804},faixa(0x807,0x81E),{0x836,0x860}), excludeFlags={0x86},
        rewardFlags={{0x021,0x4FF},{0x500,0x7B4},{0x800,0x80E}}, flagMax=0x8FF,
        sharedVars=juntar({0x4023,0x4046},faixa(0x4050,0x405A),{0x405E,0x4060,0x4062,0x4069,0x406F,0x4071,0x4072,0x4074,0x407B,0x4082},
            faixa(0x4084,0x4087),faixa(0x408C,0x4099),faixa(0x409A,0x409C),{0x40A0},faixa(0x40A2,0x40A7),
            faixa(0x40A9,0x40B7),faixa(0x40B9,0x40BA),faixa(0x40BC,0x40C7)),
        excludeVars={0x4087}},
}
if DP_PROFILE then
    local ok,custom=pcall(dofile,DP_PROFILE)
    assert(ok and type(custom)=='table','perfil inválido: '..tostring(DP_PROFILE)..' '..tostring(custom))
    -- perfil gerado para esta ROM: só os valores dele (um ponto que faltar fica sem valor, nunca herda o do FireRed)
    P={}
    for k,v in pairs(custom) do P[k]=v end
end
P.layout=assert(LAYOUTS[P.family],'família sem organização de save: '..tostring(P.family))
-- SaveBlocks e PC: por ponteiro (FireRed/LeafGreen/Emerald) ou em endereço fixo (Ruby/Sapphire: saveBlock1/saveBlock2/storage)
function P.readSaveBlocks(memory)
    if P.saveBlock1 then return P.saveBlock1,P.saveBlock2 end
    return memory:read32(P.saveBlock1Ptr),memory:read32(P.saveBlock2Ptr)
end
function P.readStorage(memory)
    if P.storage then return P.storage end
    return memory:read32(P.storagePtr)
end
-- derivados
P.idle=P.cave               --bx lr: o jogo espera sem girar a CPU
P.spin=P.cave+0x20          --b .: CPU parada esperando a reserva
P.battleScript=P.cave+0x100 --script de captura
P.callback2=P.gMain+4
P.savedCallback=P.gMain+8
return P
