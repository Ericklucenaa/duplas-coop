"""Duplas: aplicativo de janela para preparar uma ROM de Pokémon de GBA para jogar em dupla.

Abre a mesma tela da ferramenta numa janela própria (WebView2 do Windows), com o servidor interno numa porta livre.
Como .exe (PyInstaller), fica na pasta coop e usa os arquivos dela (scripts, GBA-PK, emulador).
"""
from __future__ import annotations

import os
import sys
import threading
from pathlib import Path


def raiz() -> Path:
    if getattr(sys, 'frozen', False):          # Duplas.exe: a pasta coop é a do executável
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parents[1]


def icone_da_janela(ico: Path) -> None:
    """Põe o cartucho na barra de título (a janela do WebView2 nasce com o ícone genérico). Procura as janelas deste
    processo por alguns segundos, porque a definitiva aparece depois do evento de janela mostrada."""
    import ctypes
    import time
    from ctypes import wintypes
    user32 = ctypes.windll.user32
    user32.LoadImageW.restype = ctypes.c_void_p
    if not ico.exists():
        return
    grande = user32.LoadImageW(None, str(ico), 1, 32, 32, 0x10)      # IMAGE_ICON, LR_LOADFROMFILE
    pequeno = user32.LoadImageW(None, str(ico), 1, 16, 16, 0x10)
    pid = os.getpid()
    Proc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    def aplicar(hwnd, _):
        dono = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(dono))
        if dono.value == pid and user32.IsWindowVisible(hwnd):
            user32.SendMessageW(hwnd, 0x80, 1, ctypes.c_void_p(grande))    # WM_SETICON, ICON_BIG
            user32.SendMessageW(hwnd, 0x80, 0, ctypes.c_void_p(pequeno))   # ICON_SMALL
        return True
    for _ in range(10):
        user32.EnumWindows(Proc(aplicar), 0)
        time.sleep(0.5)


def carregar_da_pasta(pasta: Path):
    """A ferramenta vem sempre dos arquivos da pasta "ferramenta", nunca da cópia embutida no .exe: o PyInstaller põe
    os módulos dentro do executável e eles teriam prioridade, então atualizar a pasta não mudaria nada para quem usa o
    Duplas.exe. A cópia embutida só é usada se o arquivo da pasta faltar."""
    import importlib
    import importlib.util
    for nome in ('assinaturas', 'pacote', 'atualizar', 'servidor'):   # servidor importa os outros três
        arquivo = pasta / f'{nome}.py'
        if arquivo.exists():
            spec = importlib.util.spec_from_file_location(nome, arquivo)
            modulo = importlib.util.module_from_spec(spec)
            sys.modules[nome] = modulo
            spec.loader.exec_module(modulo)
        else:
            importlib.import_module(nome)
    return sys.modules['servidor']


def main():
    base = raiz()
    os.environ['DUPLAS_RAIZ'] = str(base)
    os.chdir(base)
    if not (base / 'ferramenta' / 'index.html').exists() or not (base / 'src' / 'dp_profile.lua').exists():
        import ctypes
        ctypes.windll.user32.MessageBoxW(None, 'O Duplas.exe precisa ficar na pasta "coop" do projeto, junto das pastas '
                                         '"ferramenta", "src" e "tools".', 'Duplas', 0x10)
        return
    sys.path.insert(0, str(base / 'ferramenta'))
    servidor = carregar_da_pasta(base / 'ferramenta')   # precisa de DUPLAS_RAIZ definido antes
    import webview  # noqa: E402

    http = servidor.criar_servidor(0)                       # porta livre: nunca conflita com outra cópia aberta
    threading.Thread(target=http.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{http.server_address[1]}/'
    janela = webview.create_window('Duplas', url, width=1040, height=860, min_size=(420, 600), background_color='#E7E7E2')
    janela.events.shown += lambda: threading.Thread(target=icone_da_janela, args=(base / 'ferramenta' / 'duplas.ico',), daemon=True).start()
    webview.start()
    http.shutdown()


if __name__ == '__main__':
    main()
