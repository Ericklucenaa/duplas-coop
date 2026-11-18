"""Ferramenta do modo Duplas: página local para enviar uma ROM e sair com o jogo pronto para jogar em dupla.

Uso: python ferramenta/servidor.py   (abre http://127.0.0.1:8765 no navegador). O Duplas.exe abre a mesma página numa janela.
Tudo fica no PC: a ROM e o save vão para ferramenta/trabalho/ e o pacote para pacotes/. Só a procura por atualizações
fala com a internet (a página de releases do projeto no GitHub).
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).parent))
import assinaturas as A  # noqa: E402
import pacote as Pk  # noqa: E402
import atualizar as Up  # noqa: E402

L, Erro = Pk.L, Pk.Erro
AQUI = Path(os.environ['DUPLAS_RAIZ']) / 'ferramenta' if os.environ.get('DUPLAS_RAIZ') else Path(__file__).parent
TRABALHO = AQUI / 'trabalho'
PORTA = 8765
LIMITE = 40 * 1024 * 1024
ANCORAS = json.loads((AQUI / 'assinaturas.json').read_text(encoding='utf-8'))
OFICIAIS = json.loads((AQUI / 'perfis.json').read_text(encoding='utf-8')) if (AQUI / 'perfis.json').exists() else {}
DOACAO = 'https://ko-fi.com/ericklucena'
NAO_E_ROM = L("This does not look like a GBA ROM. Choose the game's .gba file.",
              'Isto não parece uma ROM de GBA. Escolha o arquivo .gba do jogo.',
              'Esto no parece una ROM de GBA. Elige el archivo .gba del juego.')


def idioma() -> str:
    return Pk.idioma_valido(Up.ler_prefs().get('idioma'))


def analisar(rom: bytes) -> dict:
    if len(rom) < 0x200 or len(rom) > LIMITE or rom[0xB2] != 0x96:
        raise Erro(NAO_E_ROM)
    ident = hashlib.sha1(rom).hexdigest()[:12]
    pasta = TRABALHO / ident
    pasta.mkdir(parents=True, exist_ok=True)
    (pasta / 'rom.gba').write_bytes(rom)
    r = A.resolver(rom, ANCORAS, OFICIAIS)
    recursos = Pk.avaliar(r)
    dados = {'id': ident, 'cabecalho': r['cabecalho'], 'recursos': recursos, 'pronto': Pk.pronto(recursos),
             'tem_save': (pasta / 'save.sav').exists()}
    (pasta / 'perfil.lua').write_text(A.perfil_lua(r['perfil']), encoding='utf-8')
    (pasta / 'analise.json').write_text(json.dumps(dados, ensure_ascii=False, indent=1), encoding='utf-8')
    return dados


def listar_pacotes() -> list[dict]:
    out = []
    for p in Pk.pacotes():
        rom = next((p / 'jogo').glob('*.gba'), None)
        cab = {}
        if rom:
            with open(rom, 'rb') as f:
                cab = A.cabecalho(f.read(0xC0))
        out.append({'nome': p.name, 'tem_save': any((p / 'jogo').glob('*.sav')), 'teste': Pk.estado_teste(p.name),
                    'pasta': str(p), 'velocidade': Pk.ler_velocidade(p),
                    'codigo': cab.get('codigo', ''), 'jogo': cab.get('jogo'), 'idioma': cab.get('idioma')})
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # sem poluir o terminal
        pass

    def _json(self, dados, status=200):
        corpo = json.dumps(dados, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def _corpo(self) -> bytes:
        n = int(self.headers.get('Content-Length') or 0)
        if n > LIMITE:
            raise Erro(L('File too large.', 'Arquivo grande demais.', 'Archivo demasiado grande.'))
        return self.rfile.read(n)

    def _pedido(self) -> dict:
        return json.loads(self._corpo() or b'{}')

    def do_GET(self):
        try:
            if self.path in ('/', '/index.html'):
                corpo = (AQUI / 'index.html').read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(corpo)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(corpo)
            elif self.path == '/api/config':
                self._json({'idioma': idioma(), 'versao': Up.versao_atual(), 'doacao': DOACAO,
                            'projeto': f'https://github.com/{Up.REPO}', 'anterior': Up.versao_anterior()})
            elif self.path == '/api/pacotes':
                self._json({'pacotes': listar_pacotes()})
            elif self.path.startswith('/api/teste/'):
                self._json(Pk.estado_teste(unquote(self.path[len('/api/teste/'):])) or {})
            elif self.path == '/api/atualizacao':
                self._json(Up.verificar())
            elif self.path == '/api/atualizacao/estado':
                self._json(Up.estado)
            else:
                self._json({'erro': 'não encontrado'}, 404)
        except Erro as e:
            self._json({'erro': e.textos}, 400)

    def do_POST(self):
        try:
            if self.path == '/api/analisar':
                self._json(analisar(self._corpo()))
            elif self.path.startswith('/api/save/'):
                ident = self.path[len('/api/save/'):]
                pasta = TRABALHO / ident
                dados = self._corpo()
                if not ident.isalnum() or not pasta.exists():
                    raise Erro(L('Send the ROM before the save.', 'Envie a ROM antes do save.', 'Envía la ROM antes de la partida.'))
                if len(dados) not in (0x8000, 0x10000, 0x20000, 0x20010):
                    raise Erro(L('This does not look like a GBA save (unexpected size).',
                                 'Isto não parece um save de GBA (tamanho inesperado).',
                                 'Esto no parece una partida de GBA (tamaño inesperado).'))
                (pasta / 'save.sav').write_bytes(dados)
                self._json({'ok': True})
            elif self.path == '/api/gerar':
                pedido = self._pedido()
                pasta = TRABALHO / str(pedido.get('id', ''))
                if not str(pedido.get('id', '')).isalnum() or not (pasta / 'analise.json').exists():
                    raise Erro(L('Send the ROM first.', 'Envie a ROM primeiro.', 'Envía la ROM primero.'))
                analise = json.loads((pasta / 'analise.json').read_text(encoding='utf-8'))
                destino = Pk.montar(pasta, pedido.get('nome') or analise['cabecalho']['titulo'],
                                    (pasta / 'perfil.lua').read_text(encoding='utf-8'), analise['recursos'], idioma())
                self._json({'pacote': destino.name, 'pasta': str(destino)})
            elif self.path == '/api/testar':
                chave = Pk.iniciar_teste(Pk.pasta_do_pacote(self._pedido().get('pacote')))
                self._json(Pk.estado_teste(chave))
            elif self.path == '/api/velocidade':
                pedido = self._pedido()
                destino = Pk.pasta_do_pacote(pedido.get('pacote'))
                self._json({'velocidade': Pk.gravar_velocidade(destino, int(pedido.get('valor', 0)))})
            elif self.path == '/api/apagar':
                Pk.apagar(str(self._pedido().get('pacote', '')))
                self._json({'ok': True})
            elif self.path == '/api/abrir':
                pedido = self._pedido()
                destino = Pk.pasta_do_pacote(pedido.get('pacote'))
                if pedido.get('acao') == 'pasta':
                    os.startfile(destino)
                elif pedido.get('acao') == 'local':
                    subprocess.Popen(['cmd', '/c', 'start', '', str(Pk.nome_bat_local(destino))], cwd=destino)
                self._json({'ok': True})
            elif self.path == '/api/idioma':
                novo = Pk.idioma_valido(self._pedido().get('idioma'))
                Up.gravar_prefs(idioma=novo)
                Pk.trocar_idioma(novo)
                self._json({'idioma': novo})
            elif self.path == '/api/atualizar':
                self._json(Up.iniciar_atualizacao())
            elif self.path == '/api/ignorar':
                self._json(Up.gravar_prefs(ignorar_versao=str(self._pedido().get('versao', '')) or None))
            elif self.path == '/api/voltar':
                self._json(Up.voltar())
            elif self.path == '/api/reiniciar':
                self._json({'reiniciando': Up.reiniciar()})
            elif self.path == '/api/link':
                url = str(self._pedido().get('url', ''))
                if url in (DOACAO, f'https://github.com/{Up.REPO}', f'https://github.com/{Up.REPO}/releases'):
                    webbrowser.open(url)   # só os links do próprio app, no navegador de quem usa
                self._json({'ok': True})
            else:
                self._json({'erro': 'não encontrado'}, 404)
        except Erro as e:
            self._json({'erro': e.textos}, 400)
        except (ValueError, KeyError, FileNotFoundError, StopIteration) as e:
            self._json({'erro': str(e) or e.__class__.__name__}, 400)


def criar_servidor(porta: int = PORTA) -> ThreadingHTTPServer:
    TRABALHO.mkdir(exist_ok=True)
    return ThreadingHTTPServer(('127.0.0.1', porta), Handler)


def main():
    servidor = criar_servidor()
    url = f'http://127.0.0.1:{PORTA}'
    print(f'Duplas: {url}')
    if '--sem-navegador' not in sys.argv:
        webbrowser.open(url)
    servidor.serve_forever()


if __name__ == '__main__':
    main()
