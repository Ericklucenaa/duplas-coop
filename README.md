# Duplas — co-op for GBA Pokémon games

[![Download](https://img.shields.io/github/v/release/Ericklucenaa/duplas-coop?label=download&style=flat-square)](https://github.com/Ericklucenaa/duplas-coop/releases/latest)
[![Ko-fi](https://img.shields.io/badge/support-Ko--fi-FF5E5B?style=flat-square&logo=ko-fi&logoColor=white)](https://ko-fi.com/ericklucena)

**English** · [Português](#português) · [Español](#español)

> **Beta.** Duplas is still in beta (versions 0.x): expect bugs, and please report them in
> [Issues](https://github.com/Ericklucenaa/duplas-coop/issues). If a version breaks a game for you, the app can return to the previous one.

Duplas turns a 3rd-generation GBA Pokémon game into a two-player co-op adventure: both players walk the same
world, share the bag, money and story, and fight wild Pokémon and trainers in **real double battles**, each player
commanding their own Pokémon.

Works with FireRed, LeafGreen, Emerald, Ruby and Sapphire — original, translated or modified (ROM hacks based on them).

> Duplas does **not** include any game. Use a ROM of a game you own.

## How to use

1. Download `Duplas-<version>.zip` from the [latest release](https://github.com/Ericklucenaa/duplas-coop/releases/latest)
   and extract it anywhere (Windows 10/11).
2. Open `Duplas.exe`.
3. Drop your `.gba` ROM on the cartridge. The app checks what works in that ROM.
4. Optionally add your save (`.sav`) to continue your adventure.
5. Click **Build package**. You get a folder with the game, the emulator and three shortcuts:
   **Host game**, **Join game** (by IP — local network, Tailscale or ZeroTier) and **Test on this PC**.
6. Copy the package folder to your partner's PC and play.

The **compatibility test** (inside the app) plays all the co-op scenarios by itself with two hidden copies of the game,
so you can check a ROM before playing. You can test several packages at the same time.

## Updates

The app checks for new versions when it opens and asks **"Do you want to update?"**. Updating keeps your packages,
saves and progress. If a new version gives you trouble with a game, use **Return to version X** in the app to go back
to the previous one.

## Languages

English (default), Português and Español — for the app and for the notices inside the game.

## Support

Duplas is free. If it made your adventure better, you can [support it on Ko-fi](https://ko-fi.com/ericklucena).

## Credits and licenses

- Duplas code: MIT (`LICENSE`).
- [GBA-PK-multiplayer](https://github.com/TheHunterManX/GBA-PK-multiplayer) by TheHunterManX: CC BY-NC 4.0, non-commercial.
- [mGBA](https://mgba.io) (included in the releases): MPL 2.0.

Details in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Pokémon is a trademark of Nintendo, Creatures Inc. and
GAME FREAK inc.; this is a fan project, not affiliated with them.

## For developers

- `ferramenta/` — the app (Python, local web page; `Duplas.exe` is built with PyInstaller from `build-app/Duplas.spec`).
- `src/` — the co-op mode (Lua scripts for mGBA on top of GBA-PK).
- `tests/` — unit tests (`python -m pytest tests/unit`) and the two-emulator scenarios used by the compatibility test.
- `publicar.ps1 -Versao 0.1.1 -Notas "..."` (0.x versions are published as beta pre-releases) — builds the release zip and publishes it on GitHub (needs `gh`, Python with
  PyInstaller, and the mGBA development build in `tools/mgba-dev`).

---

## Português

O Duplas transforma um Pokémon de GBA da 3ª geração numa aventura cooperativa para dois jogadores: os dois andam pelo
mesmo mundo, dividem bolsa, dinheiro e história, e enfrentam selvagens e treinadores em **batalhas em dupla de
verdade**, cada um comandando o próprio Pokémon. Funciona com FireRed, LeafGreen, Emerald, Ruby e Sapphire — original,
traduzido ou modificado.

> O Duplas **não** inclui nenhum jogo. Use a ROM de um jogo que você tem.

**Como usar:** baixe o `Duplas-<versão>.zip` da [última release](https://github.com/Ericklucenaa/duplas-coop/releases/latest),
extraia, abra o `Duplas.exe`, solte a ROM no cartucho, adicione o save se quiser e clique em **Gerar pacote**. A pasta
gerada tem o jogo, o emulador e os atalhos **Hospedar partida**, **Entrar na partida** e **Testar no mesmo PC**.
Copie a pasta para o PC do seu parceiro e joguem.

**Atualizações:** ao abrir, o app procura versões novas e pergunta **"Deseja atualizar?"**. Seus pacotes, saves e
progresso são mantidos. Se uma versão nova der problema com algum jogo, use **Voltar para a versão X** no app.

**Idiomas:** inglês (padrão), português e espanhol, no app e nos avisos dentro do jogo. Escolha no canto do app.

**Apoie:** o Duplas é gratuito. Se ele melhorou a sua aventura, [apoie no Ko-fi](https://ko-fi.com/ericklucena).

## Español

Duplas convierte un Pokémon de GBA de 3.ª generación en una aventura cooperativa para dos jugadores: los dos recorren
el mismo mundo, comparten mochila, dinero e historia, y se enfrentan a salvajes y entrenadores en **combates dobles
de verdad**, cada uno controlando su propio Pokémon. Funciona con FireRed, LeafGreen, Emerald, Ruby y Sapphire —
original, traducido o modificado.

> Duplas **no** incluye ningún juego. Usa la ROM de un juego que tengas.

**Cómo usarlo:** descarga `Duplas-<versión>.zip` de la [última versión](https://github.com/Ericklucenaa/duplas-coop/releases/latest),
extráelo, abre `Duplas.exe`, suelta la ROM en el cartucho, añade tu partida si quieres y pulsa **Crear paquete**. La
carpeta creada tiene el juego, el emulador y los accesos **Crear partida**, **Unirse a partida** y **Probar en este PC**.
Copia la carpeta al PC de tu compañero y a jugar.

**Actualizaciones:** al abrirse, la app busca versiones nuevas y pregunta **"¿Quieres actualizar?"**. Tus paquetes,
partidas y progreso se mantienen. Si una versión nueva da problemas con algún juego, usa **Volver a la versión X**.

**Idiomas:** inglés (por defecto), portugués y español, en la app y en los avisos dentro del juego.

**Apoya:** Duplas es gratuito. Si mejoró tu aventura, puedes [apoyarlo en Ko-fi](https://ko-fi.com/ericklucena).
