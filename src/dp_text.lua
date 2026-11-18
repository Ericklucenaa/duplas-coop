-- Textos que o jogador vê dentro do jogo, em inglês (padrão), português e espanhol.
-- O idioma vem de DP_LANG ('en', 'pt' ou 'es'), definido pelo iniciar-demo.ps1 a partir do idioma escolhido no app.
local TEXTS={
    wait_partner_offline={en='Partner disconnected: waiting for them to come back.',
        pt='Parceiro desconectado: aguardando a volta.',es='Compañero desconectado: esperando a que vuelva.'},
    wait_no_usable_pokemon={en='One of you has no Pokémon able to battle.',
        pt='Um dos dois está sem Pokémon em condições.',es='Uno de los dos no tiene Pokémon en condiciones.'},
    wait_battle_busy={en='Your partner is already in a battle.',
        pt='O parceiro já está em uma batalha.',es='Tu compañero ya está en un combate.'},
    wait_two_players_required={en='The battle needs both players connected.',
        pt='A batalha precisa dos dois conectados.',es='El combate necesita a los dos conectados.'},
    wait_other={en='Battle on hold (%s).',pt='Batalha em espera (%s).',es='Combate en espera (%s).'},
    solo_hint={en='Hold L+R+SELECT to battle alone.',pt='Segure L+R+SELECT para batalhar sozinho.',
        es='Mantén L+R+SELECT para combatir solo.'},
    last_unit={en='Your partner used the last one of this item.',pt='O parceiro usou a última unidade desse item.',
        es='Tu compañero usó la última unidad de este objeto.'},
    connection_lost={en='Connection lost. Waiting for your partner...',pt='Conexão perdida. Aguardando o parceiro...',
        es='Conexión perdida. Esperando a tu compañero...'},
    preparing={en='Preparing double battle...',pt='Preparando batalha em dupla...',es='Preparando combate doble...'},
    partner_found={en='Your partner found a battle!',pt='Seu parceiro encontrou uma batalha!',
        es='¡Tu compañero encontró un combate!'},
    partner_found_hint={en='Finish the dialogue or leave this menu to join.',
        pt='Termine o diálogo ou saia deste menu para entrar.',es='Termina el diálogo o sal de este menú para entrar.'},
    entering={en='Joining the battle...',pt='Entrando na batalha...',es='Entrando en el combate...'},
    double_battle={en='Double battle!',pt='Batalha em dupla!',es='¡Combate doble!'},
    release_buttons={en='Release the buttons to play alone.',pt='Solte os botões para jogar sozinho.',
        es='Suelta los botones para jugar solo.'},
    coop_ends={en='Co-op will end for this session.',pt='O cooperativo será encerrado nesta sessão.',
        es='El cooperativo terminará en esta sesión.'},
    coop_ended={en='Co-op ended for this session.',pt='Cooperativo encerrado nesta sessão.',
        es='Cooperativo terminado en esta sesión.'},
    next_battles_solo={en='Your next battles are single-player.',pt='As próximas batalhas são individuais.',
        es='Tus próximos combates son individuales.'},
    partner_busy={en='Waiting for your partner to finish what they are doing...',
        pt='Aguardando o parceiro terminar o que está fazendo...',es='Esperando a que tu compañero termine lo que está haciendo...'},
    partner_busy_hint={en='The battle starts as soon as your partner is free.',
        pt='A batalha começa assim que o parceiro estiver livre.',es='El combate empieza en cuanto tu compañero esté libre.'},
    partner_back={en='Partner is back. Resuming the battle...',pt='Parceiro de volta. Retomando a batalha...',
        es='Tu compañero volvió. Reanudando el combate...'},
    partner_no_pokemon={en="Your partner has no Pokémon yet: this battle is yours alone.",
        pt='Seu parceiro ainda não tem Pokémon: esta batalha é só sua.',es='Tu compañero aún no tiene Pokémon: este combate es solo tuyo.'},
    waiting_connect={en='Waiting for your partner to connect...',pt='Aguardando o parceiro conectar...',
        es='Esperando a que tu compañero se conecte...'},
    old_mgba={en='DUPLAS MODE OFF: this mGBA lacks the double battle features.\n'..
        'Close this emulator and open the game with "Host game.bat", "Join game.bat" or\n'..
        '"Test on this PC.bat" from the package. They use the bundled mGBA (coop/tools/mgba-dev).',
        pt='MODO DUPLAS DESLIGADO: este mGBA não tem os recursos da batalha em dupla.\n'..
        'Feche este emulador e abra o jogo pelo arquivo "Hospedar partida.bat", "Entrar na partida.bat" ou\n'..
        '"Testar no mesmo PC.bat" do pacote. Eles usam o mGBA que vem junto (coop/tools/mgba-dev).',
        es='MODO DUPLAS DESACTIVADO: este mGBA no tiene las funciones del combate doble.\n'..
        'Cierra este emulador y abre el juego con "Crear partida.bat", "Unirse a partida.bat" o\n'..
        '"Probar en este PC.bat" del paquete. Usan el mGBA incluido (coop/tools/mgba-dev).'},
}
local function T(key,...)
    local entry=TEXTS[key];if not entry then return key end
    local text=entry[DP_LANG or 'en'] or entry.en
    if select('#',...)>0 then return string.format(text,...) end
    return text
end
return T
