import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { validateRequest, previewStory } from '../src/jobs.mjs';

const load = async name => JSON.parse(await readFile(new URL(`../examples/${name}`, import.meta.url), 'utf8'));

test('pedidos de exemplo são válidos', async () => {
  for (const name of ['pedido-quem-quebrou.json', 'pedido-ninguem-lembrou.json']) {
    assert.deepEqual(validateRequest(await load(name)), [], name);
  }
});

test('ação desconhecida é recusada com explicação', async () => {
  const body = await load('pedido-quem-quebrou.json');
  body.roteiro.scenes[0].events[0].action = 'voar';
  const errors = validateRequest(body);
  assert.ok(errors.length > 0 && errors.some(e => e.includes('action')));
});

test('fala de quem não está na cena é recusada', async () => {
  const body = await load('pedido-quem-quebrou.json');
  body.roteiro.scenes[0].lines[0].speaker = 'tony';
  assert.ok(validateRequest(body).some(e => e.includes('não está na cena')));
});

test('previewStory transforma lines em legendas com speaker', async () => {
  const body = await load('pedido-quem-quebrou.json');
  const story = previewStory(body.roteiro);
  assert.equal(story.scenes[0].lines, undefined);
  assert.ok(story.scenes[0].dialogues.some(d => d.speaker === 'caio'));
});

test('corpo sem roteiro é recusado', () => {
  assert.ok(validateRequest({}).length > 0);
});
