// Fila de jobs persistida em disco (DATA_DIR/jobs/<id>.json). Um render por vez.
import { promises as fs } from 'node:fs';
import { existsSync } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { root, dataDir, renderStory } from '../packages/render-worker/index.mjs';
import { validateStory } from '../packages/story-schema/index.mjs';

export const jobsDir = path.join(dataDir, 'jobs');
export const outputRoot = path.join(dataDir, 'saida');
const PYTHON = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const ACTIVE = new Set(['na_fila', 'gerando_vozes', 'renderizando']);

const queue = [];
let running = null;          // { id, controller }
const memory = new Map();    // id -> job

const now = () => new Date().toISOString();
const slug = text => String(text || 'historia').normalize('NFD').replace(/[̀-ͯ]/g, '')
  .toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48) || 'historia';

async function save(job) {
  job.atualizadoEm = now();
  memory.set(job.id, job);
  await fs.writeFile(path.join(jobsDir, `${job.id}.json`), JSON.stringify(job, null, 2));
}

export function getJob(id) { return memory.get(id); }
export function listJobs() { return [...memory.values()].sort((a, b) => b.criadoEm.localeCompare(a.criadoEm)); }
export function queuePosition(id) { const i = queue.indexOf(id); return i < 0 ? 0 : i + 1; }
export function stats() { return { fila: queue.length, renderizando: running?.id || null }; }

// Converte "lines" (falas a gerar) em legendas estimadas, só para validar antes de gastar TTS/render.
export function previewStory(roteiro) {
  const story = structuredClone(roteiro);
  delete story.audioSlug;
  for (const scene of story.scenes || []) {
    const lines = scene.lines || [];
    delete scene.lines;
    scene.dialogues = scene.dialogues || [];
    scene.sounds = scene.sounds || [];
    for (const line of lines) {
      const words = String(line.text || '').split(/\s+/).filter(Boolean).length;
      const end = Math.min(Number(line.time) + 0.6 + words * 0.32, Number(scene.duration));
      scene.dialogues.push({ time: line.time, duration: Math.max(0.2, Number((end - line.time).toFixed(3))), text: line.text, speaker: line.speaker });
    }
    scene.dialogues.sort((a, b) => a.time - b.time);
  }
  return story;
}

export function validateRequest(body) {
  const errors = [];
  if (!body || typeof body !== 'object') return ['Corpo deve ser um objeto JSON.'];
  if (!body.roteiro || typeof body.roteiro !== 'object') errors.push('Campo "roteiro" é obrigatório.');
  if (body.webhook && !/^https?:\/\//.test(body.webhook)) errors.push('"webhook" deve ser uma URL http(s).');
  if (errors.length) return errors;
  try { validateStory(previewStory(body.roteiro)); }
  catch (error) {
    const issues = error.issues || error.errors;
    if (issues) return issues.map(i => `${(i.path || []).join('.') || 'roteiro'}: ${i.message}`);
    return [String(error.message || error)];
  }
  for (const scene of body.roteiro.scenes || []) for (const line of scene.lines || []) {
    if (!(scene.characters || []).includes(line.speaker)) errors.push(`${scene.sceneId}: quem fala (${line.speaker}) não está na cena.`);
    if (!line.text) errors.push(`${scene.sceneId}: fala sem texto.`);
  }
  return errors;
}

export async function createJob(body) {
  const id = `job_${crypto.randomBytes(5).toString('hex')}`;
  const date = new Date().toISOString().slice(0, 10);
  const folder = `${date}-${slug(body.pasta || body.roteiro.title)}-${id.slice(4)}`;
  const job = {
    id, status: 'na_fila', etapa: 'aguardando a vez', criadoEm: now(), atualizadoEm: now(),
    titulo: body.roteiro.title, pasta: folder,
    opcoes: { vozes: body.vozes !== false, versaoSemFalas: !!body.versaoSemFalas, webhook: body.webhook || null, post: body.post || null },
    erro: null, resultado: null
  };
  await fs.writeFile(path.join(jobsDir, `${id}.request.json`), JSON.stringify(body, null, 2));
  await save(job);
  queue.push(id);
  pump();
  return job;
}

export async function cancelJob(id) {
  const job = memory.get(id);
  if (!job) return null;
  if (running?.id === id) { running.controller.abort(); return job; }
  const i = queue.indexOf(id);
  if (i >= 0) { queue.splice(i, 1); job.status = 'cancelado'; job.etapa = 'cancelado'; await save(job); }
  return job;
}

function run(cmd, args, { cwd = root, env = {}, signal, log } = {}) {
  return new Promise((resolve, reject) => {
    const out = [];
    const child = spawn(cmd, args, { cwd, shell: false, windowsHide: true, signal, env: { ...process.env, ...env } });
    child.stdout.on('data', c => out.push(c.toString()));
    child.stderr.on('data', c => out.push(c.toString()));
    child.on('error', reject);
    child.on('close', async code => {
      const text = out.join('');
      if (log) await fs.writeFile(log, text).catch(() => {});
      code === 0 ? resolve(text) : reject(Error(`${path.basename(cmd)} terminou com código ${code}\n${text.slice(-2000)}`));
    });
  });
}

async function processJob(job) {
  const controller = new AbortController();
  running = { id: job.id, controller };
  const outDir = path.join(outputRoot, job.pasta);
  const audioSlug = `jobs/${job.id}`;
  const audioDir = path.join(root, 'assets', 'audio', 'jobs', job.id);
  await fs.mkdir(outDir, { recursive: true });
  try {
    const body = JSON.parse(await fs.readFile(path.join(jobsDir, `${job.id}.request.json`), 'utf8'));
    const roteiro = structuredClone(body.roteiro);
    await fs.writeFile(path.join(outDir, 'roteiro.json'), JSON.stringify(roteiro, null, 2));
    let story;
    const hasLines = (roteiro.scenes || []).some(s => (s.lines || []).length);
    if (job.opcoes.vozes && hasLines) {
      job.status = 'gerando_vozes'; job.etapa = 'gerando as falas'; await save(job);
      roteiro.audioSlug = audioSlug;
      const src = path.join(outDir, 'roteiro_vozes.json');
      const dst = path.join(outDir, 'story.json');
      await fs.writeFile(src, JSON.stringify(roteiro));
      await run(PYTHON, [path.join(root, 'tools', 'tts', 'apply_voices.py'), src, dst],
        { env: { APP_ROOT: root, PYTHONUTF8: '1' }, signal: controller.signal, log: path.join(outDir, 'vozes.log') });
      story = JSON.parse(await fs.readFile(dst, 'utf8'));
      await fs.rm(src, { force: true });
    } else {
      story = previewStory(roteiro);
    }
    validateStory(story);
    job.status = 'renderizando'; job.etapa = 'renderizando o vídeo'; await save(job);
    const result = await renderStory(story, {
      outDir, signal: controller.signal,
      onStage: stage => { job.etapa = { rendering: 'renderizando o vídeo', encoding: 'codificando o MP4', validating: 'conferindo o vídeo' }[stage] || job.etapa; save(job); }
    });
    await fs.rename(path.join(outDir, 'poster.png'), path.join(outDir, 'capa.png')).catch(() => {});
    await fs.rename(path.join(outDir, 'subtitles.srt'), path.join(outDir, 'legenda.srt')).catch(() => {});
    if (job.opcoes.versaoSemFalas) {
      job.etapa = 'renderizando a versão sem falas'; await save(job);
      const silent = structuredClone(story);
      for (const s of silent.scenes) s.sounds = s.sounds.filter(x => !x.path.startsWith(`${audioSlug}/`));
      const silentDir = path.join(outDir, 'sem-falas');
      await renderStory(silent, { outDir: silentDir, signal: controller.signal });
    }
    job.status = 'concluido';
    job.etapa = 'pronto';
    job.resultado = { duracao: result.metrics.duration, bytes: result.metrics.outputBytes, segundosDeProcessamento: Math.round(result.metrics.elapsedSeconds) };
    await fs.writeFile(path.join(outDir, 'info.json'), JSON.stringify({ id: job.id, titulo: job.titulo, post: job.opcoes.post, ...job.resultado, criadoEm: job.criadoEm, concluidoEm: now() }, null, 2));
  } catch (error) {
    const cancelled = controller.signal.aborted;
    job.status = cancelled ? 'cancelado' : 'erro';
    job.etapa = cancelled ? 'cancelado' : 'falhou';
    job.erro = cancelled ? 'Cancelado pelo usuário.' : String(error.message || error).slice(0, 4000);
  } finally {
    await fs.rm(audioDir, { recursive: true, force: true }).catch(() => {});
    running = null;
    await save(job);
    notify(job).catch(() => {});
  }
}

async function notify(job) {
  if (!job.opcoes.webhook || !['concluido', 'erro'].includes(job.status)) return;
  const base = process.env.PUBLIC_URL || '';
  await fetch(job.opcoes.webhook, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: job.id, status: job.status, erro: job.erro, pasta: job.pasta, post: job.opcoes.post,
      download: job.status === 'concluido' ? `${base}/api/v1/historias/${job.id}/download` : null }),
    signal: AbortSignal.timeout(15000)
  });
}

async function pump() {
  if (running) return;
  const id = queue.shift();
  if (!id) return;
  const job = memory.get(id);
  if (job && job.status === 'na_fila') await processJob(job);
  setImmediate(pump);
}

export async function initJobs() {
  await fs.mkdir(jobsDir, { recursive: true });
  await fs.mkdir(outputRoot, { recursive: true });
  await fs.rm(path.join(dataDir, '.render.lock'), { force: true }); // trava de um processo que caiu
  const files = (await fs.readdir(jobsDir)).filter(f => /^job_[a-f0-9]+\.json$/.test(f));
  const pending = [];
  for (const f of files) {
    const job = JSON.parse(await fs.readFile(path.join(jobsDir, f), 'utf8'));
    if (ACTIVE.has(job.status)) { job.status = 'na_fila'; job.etapa = 'retomado após reinício'; pending.push(job); }
    memory.set(job.id, job);
  }
  pending.sort((a, b) => a.criadoEm.localeCompare(b.criadoEm));
  for (const job of pending) { await save(job); queue.push(job.id); }
  pump();
}

export function outputFile(job, name) {
  const allowed = { video: 'movie.mp4', capa: 'capa.png', legenda: 'legenda.srt', info: 'info.json', roteiro: 'story.json', 'video-sem-falas': 'sem-falas/movie.mp4' };
  const file = allowed[name];
  if (!file) return null;
  const full = path.join(outputRoot, job.pasta, file);
  return existsSync(full) ? full : null;
}
