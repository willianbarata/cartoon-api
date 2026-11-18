# Cartoon Studio API

API que recebe um **roteiro em JSON**, gera as **vozes** (Edge TTS), **renderiza** o vídeo cartoon 3D no
**Godot 4.7.2** (com música, efeitos e legendas na tela) e devolve o **MP4** para download.
Feita para rodar em Docker (Easypanel) e ser chamada pelo **n8n**.

Elenco: quadrigêmeos `davi`, `caio`, `noah`, `tony`. Cenários: `living_room`, `bedroom`, `street`, `forest`.
A lista completa de personagens, pontos, objetos, ações, emoções e sons sai em `GET /api/v1/catalogo`.

---

## Fluxo com o n8n

```
[n8n] POST /api/v1/historias  ──▶  { "id": "job_xxx", "status": "na_fila" }   (HTTP 202)
[n8n] GET  /api/v1/historias/job_xxx
        ├─ HTTP 202 → { "pronto": false, "mensagem": "Ainda não está pronto... tente novamente em 30 segundos" }
        ├─ HTTP 200 → { "pronto": true, "download": { "video": ".../download", "capa": ..., "legenda": ..., "info": ... } }
        └─ HTTP 422 → { "pronto": false, "status": "erro", "erro": "motivo" }
[n8n] GET  /api/v1/historias/job_xxx/download   →  movie.mp4 (binário)
```

Todas as rotas `/api/v1/*` exigem o cabeçalho **`Authorization: Bearer <API_KEY>`** (ou `X-API-Key`).

### Rotas
| Método | Rota | O que faz |
|---|---|---|
| GET | `/health` | saúde do serviço (sem chave) |
| GET | `/api/v1/catalogo` | tudo que pode ser usado no roteiro |
| POST | `/api/v1/validar` | só valida o roteiro (não renderiza) |
| POST | `/api/v1/historias` | envia a história → devolve `id` (HTTP 202) |
| GET | `/api/v1/historias` | últimos 50 jobs |
| GET | `/api/v1/historias/{id}` | status: **202** processando · **200** pronto · **422** erro |
| GET | `/api/v1/historias/{id}/download` | baixa o MP4 (`?arquivo=capa`, `legenda`, `info`, `video-sem-falas`) |
| DELETE | `/api/v1/historias/{id}` | cancela (se ainda na fila/renderizando) |

### Corpo do POST `/api/v1/historias`
```json
{
  "pasta": "quem-quebrou",
  "vozes": true,
  "versaoSemFalas": false,
  "webhook": null,
  "post": { "titulo": "Quem quebrou o videogame? 🎮", "descricao": "...", "hashtags": ["#desenho"] },
  "roteiro": { "...": "mesmo formato de examples/quem-quebrou/roteiro.json" }
}
```
- `roteiro`: obrigatório. Cenas, ações (`events`), falas a gerar (`lines`), legendas (`dialogues`), sons (`sounds`).
- `vozes`: `true` gera as falas com voz; `false` só legenda.
- `versaoSemFalas`: também gera um segundo MP4 sem as vozes.
- `webhook`: opcional — se informado, a API faz um POST nele quando terminar (além do polling).
- `post`: livre; volta no status e no `info.json` para o fluxo que posta.

Exemplos completos prontos para enviar: `examples/pedido-quem-quebrou.json`, `examples/pedido-ninguem-lembrou.json`.

### Teste rápido com curl
```bash
curl -H "Authorization: Bearer SUA_CHAVE" -H "Content-Type: application/json" \
     --data-binary @examples/pedido-quem-quebrou.json https://SEU_DOMINIO/api/v1/historias
curl -H "Authorization: Bearer SUA_CHAVE" https://SEU_DOMINIO/api/v1/historias/job_xxx
curl -H "Authorization: Bearer SUA_CHAVE" -o video.mp4 https://SEU_DOMINIO/api/v1/historias/job_xxx/download
```

### Montando no n8n (polling)
1. **HTTP Request** — POST `https://SEU_DOMINIO/api/v1/historias`, header `Authorization: Bearer {{API_KEY}}`, body JSON = pedido. Guarde `{{$json.id}}`.
2. **Wait** — 30 segundos (ou o valor de `tenteNovamenteEm`).
3. **HTTP Request** — GET `.../api/v1/historias/{{id}}`. Em *Options*, ative **Include Response Headers and Status** e **Never Error** (para o 422 não quebrar o fluxo).
4. **IF** — `statusCode == 200` → segue; `statusCode == 202` → volta ao **Wait**; `422` → trate o erro.
5. **HTTP Request** — GET `{{$json.download.video}}` com o mesmo header, *Response Format* = **File**.
6. Grave numa pasta / envie para o fluxo de postagem (título e hashtags em `{{$json.post}}`).

---

## Saídas no servidor
Cada vídeo fica em `/data/saida/<data>-<pasta>-<id>/`:
`movie.mp4`, `capa.png`, `legenda.srt`, `info.json`, `roteiro.json` (recebido), `story.json` (final), logs.
Os jobs ficam em `/data/jobs/`. **Monte `/data` como volume** para não perder nada ao reiniciar
(a fila é retomada automaticamente após reinício).

---

## Implantação no Easypanel
1. Coloque esta pasta num repositório Git (GitHub/GitLab) — o `.gitignore` já exclui `node_modules`, `data` e segredos.
2. No Easypanel: **Create Service → App** → *Source*: o repositório → *Build*: **Dockerfile**.
3. *Environment*: copie de `.env.example` — no mínimo `API_KEY` (longa e aleatória) e `PUBLIC_URL` (o domínio do app).
4. *Mounts*: **Volume** montado em **`/data`**.
5. *Domains*: aponte o domínio para a porta **3000**. Confira `https://SEU_DOMINIO/health`.

Sem Git: `docker build -t cartoon-api .` numa máquina com Docker, `docker push` para um registro (Docker Hub
ou GHCR) e, no Easypanel, use *Source* = **Docker Image**.

Teste local antes: `cp .env.example .env`, edite a chave e rode `docker compose up --build`.

### Se o render falhar no servidor
Veja `/data/saida/<pasta>/godot.log` e `ffmpeg.log` (e `GET /api/v1/historias/{id}` traz o erro).
- Godot sem tela: a imagem usa `RENDER_WRAPPER=xvfb-run` com OpenGL por software (llvmpipe). Para testar dentro
  do container: `xvfb-run -a godot --version`.
- Sem vozes: confira se o servidor tem internet (Edge TTS) — `vozes.log` na pasta do vídeo.
- **Status do teste:** o fluxo completo (POST → 202 → 200 → download) foi testado no Windows com os mesmos
  arquivos; a imagem Docker em si ainda não foi construída/testada (Docker indisponível na máquina de origem).
  Rode `docker compose up --build` e envie `examples/pedido-quem-quebrou.json` antes de subir para produção.

### Recursos do servidor
- O render é feito **por CPU** (sem placa de vídeo). Reserve **2+ vCPUs e 2–4 GB de RAM**. Um vídeo de ~40 s
  leva ~1 min num PC desktop; em VPS pode levar **vários minutos** — o polling cuida disso.
- Um vídeo por vez (fila). Disco: ~5–15 MB por vídeo em `/data/saida`; apague pastas antigas quando quiser.
- As vozes usam o **Edge TTS** (precisa de internet; serviço gratuito e não oficial da Microsoft).

---

## Estrutura
```
src/server.mjs          API HTTP (Node puro, sem framework)
src/jobs.mjs            fila persistida em disco, pipeline vozes → render → saída
packages/story-schema   validação Zod do roteiro (personagens, cenários, ações...)
packages/render-worker  Godot (Movie Maker) → FFmpeg (MP4 H.264 + AAC), conferência do vídeo
packages/audio-pipeline mixagem de música/efeitos/vozes e legendas SRT
engine/godot            projeto Godot: cenas, personagens, animações, câmeras, legendas na tela
assets/audio            músicas e efeitos (licenças em assets/audio/LICENSES.md)
assets/characters       perfis de voz (voices.json) e elenco
tools/tts/apply_voices.py  gera as falas e encaixa no roteiro
examples/               roteiros e pedidos de exemplo
tests/                  testes da API (npm test)
```

Licenças dos assets: personagens gerados a partir das folhas do próprio autor (TRELLIS); cenários e objetos
KayKit, Kenney, Quaternius, Gobkit e OpenGameArt sob **CC0**; músicas/efeitos em `assets/audio/LICENSES.md`.
