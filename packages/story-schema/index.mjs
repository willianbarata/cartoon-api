import { z } from 'zod';

export const actions = ['idle','walk','walk_to','run','jump','turn_left','turn_right','look_at','wave','nod','shake_head','celebrate','sad','surprised','sit','stand','bend_down','talk','cry','hug','point','think','dance','laugh'];
export const emotions = ['neutral','happy','sad','angry','surprised','curious','scared'];
export const cameras = ['fixed','follow','tracking','close_up','orbit','group'];
// Elenco fixo (modelos GLB em engine/godot/assets/characters, origem em assets/characters/cast.json)
export const castModels = ['davi','noah','caio','tony'];
// Cenários montados (engine/godot/assets/environments/layouts/<tipo>.json): pontos nomeados e assentos.
// tests/story.test.mjs confere que estas listas batem com os layouts.
export const environmentAnchors = {"living_room": ["sofa", "armchair", "tv", "table", "door", "window", "center", "path_start", "path_end"], "bedroom": ["bed", "bed_2", "window", "shelf", "center", "path_start", "path_end"], "street": ["bench", "crosswalk", "road", "streetlight", "hydrant", "center", "path_start", "path_end"]};
export const environmentSeats = {"living_room": ["sofa", "armchair"], "bedroom": ["bed", "bed_2"], "street": ["bench"]};
// Objetos de cena (assets/props/props.json -> engine/godot/assets/props/<id>.glb).
export const propModels = ["carro", "carrinho_corrida", "caminhao", "caminhao_bombeiro", "onibus_escolar", "bicicleta", "foguete", "helicoptero", "aviao", "televisao", "notebook", "celular", "fone", "cachorro", "cachorrinho", "passarinho", "pombo", "videogame", "pipa"];
const id = z.string().regex(/^[a-zA-Z][a-zA-Z0-9_]{0,63}$/);
const color = z.string().regex(/^#[0-9a-fA-F]{6}$/);
const vector = z.tuple([z.number().min(-100).max(100),z.number().min(-10).max(20),z.number().min(-100).max(100)]);
const event = z.object({
  time:z.number().min(0), actor:id, action:z.enum(actions).optional(),
  target:id.optional(), duration:z.number().positive().max(120).optional(),
  emotion:z.enum(emotions).optional()
}).strict().superRefine((e,ctx)=>{
  if(!e.action && !e.emotion) ctx.addIssue({code:'custom',message:'Evento sem ação ou emoção'});
  if(e.action && !e.duration) ctx.addIssue({code:'custom',message:'Ação exige duration'});
  if(['walk','walk_to','run','look_at','bend_down','hug','point'].includes(e.action) && !e.target) ctx.addIssue({code:'custom',message:'Ação exige target'});
});
const scene = z.object({
  sceneId:id, duration:z.number().positive().max(120),
  environment:z.union([
    z.object({type:z.literal('forest'), seed:z.number().int().nonnegative(), treeCount:z.number().int().min(1).max(50),flowerCount:z.number().int().min(1).max(50)}).strict(),
    z.object({type:z.enum(Object.keys(environmentAnchors))}).strict()
  ]),
  props:z.array(z.object({id, model:z.enum(propModels), position:vector, rotation:z.number().min(-360).max(360).optional(), animation:z.enum(['idle','walk','attack','dead']).optional(), faceMove:z.boolean().optional(),
    moves:z.array(z.object({time:z.number().nonnegative(),duration:z.number().positive().max(60),to:vector,animation:z.enum(['idle','walk','attack','dead']).optional(),speed:z.number().min(0.2).max(4).optional()}).strict()).max(20).optional()}).strict()).max(30).default([]),
  characters:z.array(id).min(1).max(8), placements:z.record(id,vector),
  camera:z.object({preset:z.enum(cameras),target:id,distance:z.number().min(2).max(30),height:z.number().min(0.5).max(20),fov:z.number().min(20).max(80),
    push:z.number().min(0).max(0.8).optional(), handheld:z.number().min(0).max(2).optional(),
    shake:z.array(z.object({time:z.number().nonnegative(),duration:z.number().positive().max(3),strength:z.number().min(0).max(3).default(1)}).strict()).max(20).optional()}).strict(),
  events:z.array(event).max(500),
  dialogues:z.array(z.object({time:z.number().nonnegative(),duration:z.number().positive(),text:z.string().max(300),speaker:id.optional()}).strict()).default([]),
  sounds:z.array(z.object({time:z.number().nonnegative(),path:z.string().min(1),volume:z.number().min(0).max(2).default(1)}).strict()).default([])
}).strict();

const robotCharacter = z.object({id,name:z.string().min(1).max(64),type:z.literal('robot'),height:z.number().min(0.5).max(3),headScale:z.number().min(0.5).max(1.5),bodyColor:color,eyeColor:color,eyeSize:z.number().min(0.08).max(0.22),armLength:z.number().min(0.25).max(0.7),legLength:z.number().min(0.25).max(0.6),personality:z.string().max(64)}).strict();
const kidCharacter = z.object({id,name:z.string().min(1).max(64),type:z.literal('kid'),model:z.enum(castModels),personality:z.string().max(64).default('')}).strict();

export const StorySchema = z.object({
  version:z.literal(1), title:z.string().min(1).max(120), duration:z.number().positive().max(120),
  video:z.object({width:z.number().int().min(240).max(1920).multipleOf(2),height:z.number().int().min(240).max(1920).multipleOf(2),fps:z.union([z.literal(24),z.literal(30)])}).strict(),
  characters:z.array(z.discriminatedUnion('type',[robotCharacter,kidCharacter])).min(1).max(16),
  scenes:z.array(scene).min(1).max(24)
}).strict().superRefine((story,ctx)=>{
  const issue=(message,path=[])=>ctx.addIssue({code:'custom',message,path});
  if(Math.abs(story.scenes.reduce((n,s)=>n+s.duration,0)-story.duration)>1e-6) issue('Soma das cenas difere de duration');
  const ids=story.characters.map(c=>c.id);
  if(new Set(ids).size!==ids.length) issue('IDs de personagens duplicados');
  if(new Set(story.scenes.map(s=>s.sceneId)).size!==story.scenes.length) issue('IDs de cenas duplicados');
  story.scenes.forEach((s,i)=>{
    const path=['scenes',i];
    const env=s.environment;
    const places=env.type==='forest'
      ?['path_start','path_end','interaction_001',...Array.from({length:env.treeCount},(_,n)=>`tree_${String(n+1).padStart(3,'0')}`),...Array.from({length:env.flowerCount},(_,n)=>`flower_${String(n+1).padStart(3,'0')}`)]
      :environmentAnchors[env.type];
    const propIds=s.props.map(p=>p.id);
    const targets=new Set([...s.characters,...places,...propIds]);
    if(new Set(propIds).size!==propIds.length || propIds.some(p=>s.characters.includes(p)||places.includes(p))) issue('IDs de objetos repetidos ou iguais a personagens/pontos do cenário',path);
    if(new Set(s.characters).size!==s.characters.length) issue('Personagens repetidos na cena',path);
    for(const actor of s.characters) if(!ids.includes(actor) || !s.placements[actor]) issue(`Personagem/posição ausente: ${actor}`,path);
    if(!s.characters.includes(s.camera.target)) issue('Alvo da câmera inválido',path);
    const ends=new Map(); let previous=-1;
    for(const e of s.events){
      if(e.time<previous) issue('Eventos precisam estar ordenados por time',path);
      previous=e.time;
      if(!s.characters.includes(e.actor)) issue(`Ator ausente: ${e.actor}`,path);
      if(e.target && !targets.has(e.target)) issue(`Destino ausente: ${e.target}`,path);
      if(['walk','walk_to','run'].includes(e.action) && s.characters.includes(e.target)) issue('Movimento exige um ponto fixo do cenário; perseguir atores ainda não é suportado',path);
      if(e.target===e.actor) issue('Personagem não pode se mover até si mesmo',path);
      if(e.action==='sit' && e.target && !(env.type!=='forest' && environmentSeats[env.type].includes(e.target))) issue(`Não há assento em: ${e.target}`,path);
      if(e.actor && propIds.includes(e.actor)) issue('Objetos não executam ações',path);
      if(e.time+(e.duration??0)>s.duration+1e-6) issue('Evento ultrapassa duração da cena',path);
      if(e.action){
        if(e.time<(ends.get(e.actor)??0)-1e-6) issue('Ações corporais sobrepostas',path);
        ends.set(e.actor,e.time+e.duration);
      }
    }
    for(const d of s.dialogues) if(d.time+d.duration>s.duration) issue('Legenda fora da cena',path);
    for(const d of s.dialogues) if(d.speaker && !s.characters.includes(d.speaker)) issue(`Quem fala não está na cena: ${d.speaker}`,path);
    for(const p of s.props){let t=-1;for(const m of p.moves??[]){if(m.time<t) issue(`Movimentos de ${p.id} fora de ordem ou sobrepostos`,path);if(m.time+m.duration>s.duration+1e-6) issue(`Movimento de ${p.id} ultrapassa a cena`,path);t=m.time+m.duration;}}
    for(const sound of s.sounds) if(sound.time>=s.duration) issue('Áudio fora da cena',path);
  });
});
export const validateStory = value => StorySchema.parse(value);
