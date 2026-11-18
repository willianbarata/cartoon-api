# Fluxo n8n: Google Drive → Cartoon API → YouTube

Arquivo: `fluxo-drive-youtube.json` (no n8n: **Workflows → Import from File**).

```
A cada 4h → Config → Buscar 1 JSON em "pendentes" → mover p/ "processando" → baixar → Preparar dados
  → POST /api/v1/historias (202) → [Aguardar 30s → GET status]
        200 → baixar MP4 → publicar no YouTube → mover p/ "postado" → Resumo
        202 → ainda pode tentar? sim → volta ao Aguardar | não → erro
        outro (400/401/404/422) → erro
  erro (qualquer etapa) → mover p/ "erro" → Parar com erro (motivo na execução)
```

## Configurar
1. **Google Drive**: crie 4 pastas — `pendentes`, `processando`, `postado`, `erro` — e copie o ID de cada uma
   (o trecho da URL depois de `/folders/`).
2. Nó **Config**: preencha `apiBaseUrl` (ex.: `https://cartoon-api.seudominio.com`, sem `/` no fim) e os 4 IDs.
   `esperaSegundos` × `maxTentativas` = tempo máximo de espera (padrão 30 s × 120 = 1 h).
3. **Credenciais**:
   - *Cartoon API (Bearer)* — tipo **Header Auth**: Name `Authorization`, Value `Bearer SUA_API_KEY`.
     Usada nos 3 nós HTTP.
   - *Google Drive account* — nos 5 nós do Drive.
   - *YouTube account* — no nó Publicar no YouTube.
4. Se as pastas estiverem num **Drive compartilhado**, troque o `Drive` (`My Drive`) dos nós "Mover p/ ...".
5. Execute uma vez manualmente (**Test workflow**) com um JSON na pasta `pendentes` e depois ative o fluxo.

## Formato do JSON na pasta `pendentes`
Exemplo completo: [`examples/drive-quem-quebrou.json`](../examples/drive-quem-quebrou.json).

```json
{
  "pasta": "quem-quebrou",
  "vozes": true,
  "versaoSemFalas": false,
  "youtube": {
    "titulo": "Quem quebrou o videogame? 🎮 #Shorts",
    "descricao": "Os quadrigêmeos juram inocência...",
    "hashtags": ["#desenho", "#quadrigemeos"],
    "tags": ["desenho animado", "animação 3d"],
    "categoria": "1",
    "privacidade": "private",
    "paraCriancas": true,
    "notificarInscritos": true
  },
  "roteiro": { "...": "mesmo formato de examples/quem-quebrou/roteiro.json" }
}
```

| Campo | Obrigatório | Regra |
|---|---|---|
| `roteiro` | sim | vai direto para a API |
| `youtube.titulo` | sim | máx. 100 caracteres, sem `<` `>` |
| `youtube.paraCriancas` | sim | `true`/`false` (declaração exigida pelo YouTube) |
| `youtube.descricao` | não | as `hashtags` são adicionadas no final; máx. 5000 bytes |
| `youtube.hashtags` | não | também viram tags |
| `youtube.tags` | não | total ≤ 500 caracteres |
| `youtube.categoria` | não | `1` Filmes e animação (padrão), `24` Entretenimento |
| `youtube.privacidade` | não | `private` (padrão), `unlisted`, `public` |
| `pasta`, `vozes`, `versaoSemFalas` | não | iguais ao pedido da API |

Se o JSON estiver inválido, ele vai para a pasta `erro` e o motivo aparece na execução.
