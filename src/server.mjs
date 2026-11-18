// API HTTP do Cartoon Studio (Node puro). Uso pelo n8n:
//   POST /api/v1/historias            -> 202 { id }
//   GET  /api/v1/historias/:id        -> 202 "ainda não está pronto" | 200 pronto + links | 422 erro
//   GET  /api/v1/historias/:id/download[?arquivo=video|capa|legenda|info|video-sem-falas]
import http from 'node:http';
import { createReadStream, promises as fs } from 'node:fs';
import path from 'node:path';
import { root } from '../packages/render-worker/index.mjs';
import { actions, emotions, cameras, castModels, environmentAnchors, environmentSeats, propModels } from '../packages/story-schema/index.mjs';
import { initJobs, createJob, getJob, listJobs, cancelJob, queuePosition, stats, validateRequest, outputFile, previewStory } from './jobs.mjs';

const PORT = Number(process.env.PORT || 3000);
const API_KEY = process.env.API_KEY || '';
const RETRY_SECONDS = Number(process.env.RETRY_SECONDS || 30);
const MAX_BODY = 2 * 1024 * 1024;
if (!API_KEY && process.env.ALLOW_NO_AUTH !== '1') {
  console.error('Defina API_KEY (ou ALLOW_NO_AUTH=1 apenas para testes locais).');
  process.exit(1);
}

const send = (res, code, body, headers = {}) => {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', ...headers });
  res.end(JSON.stringify(body, null, 2));
};
const baseUrl = req => process.env.PUBLIC_URL?.replace(/\/$/, '') ||
  `${req.headers['x-forwarded-proto'] || 'http'}://${req.headers['x-forwarded-host'] || req.headers.host}`;
const authorized = req => {
  if (!API_KEY) return true;
  const auth = req.headers.authorization || '';
  const key = auth.startsWith('Bearer ') ? auth.slice(7) : req.headers['x-api-key'];
  return key === API_KEY;
};
async function readJson(req) {
  let size = 0; const chunks = [];
  for await (const c of req) { size += c.length; if (size > MAX_BODY) throw Object.assign(Error('Corpo maior que 2 MB'), { code: 413 }); chunks.push(c); }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); }
  catch { throw Object.assign(Error('JSON inválido'), { code: 400 }); }
}

function statusBody(req, job) {
  const base = `${baseUrl(req)}/api/v1/historias/${job.id}`;
  const common = { id: job.id, titulo: job.titulo, status: job.status, etapa: job.etapa, criadoEm: job.criadoEm, atualizadoEm: job.atualizadoEm };
  if (job.status === 'concluido') {
    const links = { video: `${base}/download`, capa: `${base}/download?arquivo=capa`, legenda: `${base}/download?arquivo=legenda`, info: `${base}/download?arquivo=info` };
    if (job.opcoes.versaoSemFalas) links.videoSemFalas = `${base}/download?arquivo=video-sem-falas`;
    return [200, { pronto: true, ...common, pasta: job.pasta, resultado: job.resultado, post: job.opcoes.post, download: links }];
  }
  if (job.status === 'erro' || job.status === 'cancelado') return [422, { pronto: false, ...common, erro: job.erro }];
  const pos = queuePosition(job.id);
  return [202, { pronto: false, ...common, posicaoNaFila: pos || undefined,
    mensagem: `Ainda não está pronto (${job.etapa}). Tente novamente em ${RETRY_SECONDS} segundos.`, tenteNovamenteEm: RETRY_SECONDS },
  { 'Retry-After': String(RETRY_SECONDS) }];
}

async function catalog() {
  const list = async dir => (await fs.readdir(path.join(root, 'assets', 'audio', dir)).catch(() => [])).filter(f => f.endsWith('.wav')).map(f => `${dir}/${f}`);
  const voices = JSON.parse(await fs.readFile(path.join(root, 'assets', 'characters', 'voices.json'), 'utf8'));
  return {
    personagens: castModels, vozes: Object.keys(voices).filter(k => voices[k]?.voice),
    cenarios: { forest: 'floresta procedural (seed, treeCount, flowerCount)', ...Object.fromEntries(Object.entries(environmentAnchors).map(([k, v]) => [k, { pontos: v, assentos: environmentSeats[k] }])) },
    objetos: propModels, acoes: actions, emocoes: emotions, cameras,
    sons: [...await list('music'), ...await list('sfx')]
  };
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const parts = url.pathname.replace(/\/+$/, '').split('/').filter(Boolean); // ['api','v1','historias',id,'download']
  try {
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/health')) return send(res, 200, { ok: true, servico: 'cartoon-studio-api', ...stats() });
    if (parts[0] !== 'api' || parts[1] !== 'v1') return send(res, 404, { erro: 'Rota não encontrada' });
    if (!authorized(req)) return send(res, 401, { erro: 'Chave inválida. Envie Authorization: Bearer <API_KEY>.' });
    const [, , resource, id, sub] = parts;

    if (resource === 'catalogo' && req.method === 'GET') return send(res, 200, await catalog());
    if (resource === 'validar' && req.method === 'POST') {
      const body = await readJson(req);
      const errors = validateRequest(body.roteiro ? body : { roteiro: body });
      return send(res, errors.length ? 400 : 200, errors.length ? { valido: false, erros: errors } : { valido: true });
    }
    if (resource !== 'historias') return send(res, 404, { erro: 'Rota não encontrada' });

    if (!id && req.method === 'POST') {
      const body = await readJson(req);
      const errors = validateRequest(body);
      if (errors.length) return send(res, 400, { erro: 'Roteiro inválido', detalhes: errors });
      const job = await createJob(body);
      const [, payload, headers] = statusBody(req, job);
      return send(res, 202, { ...payload, statusUrl: `${baseUrl(req)}/api/v1/historias/${job.id}` }, headers);
    }
    if (!id && req.method === 'GET') return send(res, 200, listJobs().slice(0, 50).map(j => ({ id: j.id, titulo: j.titulo, status: j.status, criadoEm: j.criadoEm })));

    const job = getJob(id);
    if (!job) return send(res, 404, { erro: 'Job não encontrado' });
    if (req.method === 'DELETE' && !sub) return send(res, 200, { id, status: (await cancelJob(id)).status });
    if (req.method === 'GET' && !sub) { const [code, body, headers] = statusBody(req, job); return send(res, code, body, headers); }
    if (req.method === 'GET' && sub === 'download') {
      if (job.status !== 'concluido') { const [code, body, headers] = statusBody(req, job); return send(res, code, body, headers); }
      const kind = url.searchParams.get('arquivo') || 'video';
      const file = outputFile(job, kind);
      if (!file) return send(res, 404, { erro: `Arquivo "${kind}" indisponível` });
      const stat = await fs.stat(file);
      const type = { '.mp4': 'video/mp4', '.png': 'image/png', '.srt': 'application/x-subrip', '.json': 'application/json' }[path.extname(file)];
      res.writeHead(200, { 'Content-Type': type, 'Content-Length': stat.size,
        'Content-Disposition': `attachment; filename="${job.pasta}${kind === 'video' ? '' : '-' + kind}${path.extname(file)}"` });
      return createReadStream(file).pipe(res);
    }
    return send(res, 405, { erro: 'Método não permitido' });
  } catch (error) {
    return send(res, error.code && Number.isInteger(error.code) ? error.code : 500, { erro: String(error.message || error) });
  }
});

await initJobs();
server.listen(PORT, () => console.log(`Cartoon Studio API na porta ${PORT}`));
