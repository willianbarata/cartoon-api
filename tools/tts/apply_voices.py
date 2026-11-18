"""Gera as falas de um roteiro com vozes infantis e produz o story.json final.

Uso: tools/bin/venv-tts/Scripts/python.exe tools/tts/apply_voices.py <roteiro_com_falas.json> <story.json>

Motores por personagem (assets/characters/voices.json, campo "engine"):
- "kokoro": offline (padrão);
- "edge": Edge TTS (Microsoft, online, gratuito e não oficial). Envia apenas o texto de cada fala.

No roteiro de entrada, cada cena pode ter "lines": [{"time": 1.2, "speaker": "davi", "text": "..."}].
Para cada fala: Kokoro (offline) -> perfil infantil do personagem (assets/characters/voices.json,
subida de tom/formantes com rubberband do FFmpeg do projeto) -> assets/audio/<slug>/<cena>_<n>.wav.
A saída troca "lines" por "dialogues" (legenda + boca mexendo, com speaker) e "sounds" (o WAV),
com a duração real de cada áudio. Nada é enviado para a internet: modelo e vozes ficam em tools/bin/kokoro.
Pronúncia: correções pt-BR do espeak reaproveitadas do voz.py do usuário.
"""
import json, os, re, subprocess, sys, tempfile, glob, shutil
import numpy as np
import soundfile as sf

ROOT = os.environ.get("APP_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
KOKORO = os.environ.get("KOKORO_DIR") or os.path.join(ROOT, "tools", "bin", "kokoro")
_win = glob.glob(os.path.join(ROOT, "tools", "bin", "ffmpeg", "*", "bin", "ffmpeg.exe"))
FFMPEG = os.environ.get("FFMPEG_PATH") or (_win[0] if _win else shutil.which("ffmpeg") or "ffmpeg")
# Edge TTS via módulo Python (funciona igual no Windows e no Linux/Docker)
EDGE = [sys.executable, "-m", "edge_tts"]
SR = 24000
V = "aeiouɐɛɔɪʊɨõãẽĩũ̃"


def br(ph):
    ph = ph.replace("æ", "ɐ").replace("y", "ɪ").replace("r", "ɾ")
    ph = re.sub(r"ɾə(?=[^\s" + V + r"ˈˌ,.!?;:])", "h", ph)
    ph = re.sub(r"(?<=[" + V + r"])ɾ(?=[\s,.!?;:]|$)", "h", ph)
    return ph.replace("ə", "")


def slugify(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:40] or "historia"


def main():
    src, dst = sys.argv[1], sys.argv[2]
    story = json.load(open(src, encoding="utf-8"))
    profiles = json.load(open(os.path.join(ROOT, "assets", "characters", "voices.json"), encoding="utf-8"))
    kokoro = None
    if any(p.get("engine", "kokoro") == "kokoro" for k, p in profiles.items() if isinstance(p, dict) and "voice" in p):
        from kokoro_onnx import Kokoro  # opcional: só para vozes offline
        kokoro = Kokoro(os.path.join(KOKORO, "model.onnx"), os.path.join(KOKORO, "vozes_ptbr.npz"))
    slug = story.get("audioSlug") or slugify(story["title"])
    out_dir = os.path.join(ROOT, "assets", "audio", slug)
    os.makedirs(out_dir, exist_ok=True)
    tmp = tempfile.mkdtemp()
    report = []
    for scene in story["scenes"]:
        lines = scene.pop("lines", [])
        scene.setdefault("dialogues", [])
        scene.setdefault("sounds", [])
        for n, line in enumerate(lines, 1):
            prof = profiles[line["speaker"]]
            if prof.get("engine", "kokoro") == "edge":
                # Edge TTS (vozes neurais da Microsoft, online): só o texto da fala é enviado.
                raw = os.path.join(tmp, "raw.mp3")
                subprocess.run([*EDGE, "--voice", prof["voice"], f"--pitch={prof.get('edgePitch', '+0Hz')}",
                                f"--rate={prof.get('edgeRate', '+0%')}", "--text", line["text"], "--write-media", raw],
                               check=True, shell=False, capture_output=True)
            else:
                y, _ = kokoro.create(br(kokoro.tokenizer.phonemize(line["text"], "pt-br")), voice=prof["voice"],
                                     speed=float(line.get("speed", prof.get("speed", 1.0))), is_phonemes=True)
                nz = np.where(np.abs(y) > 0.01)[0]
                y = y[max(0, nz[0] - 240): nz[-1] + 480] if len(nz) else y
                raw = os.path.join(tmp, "raw.wav")
                sf.write(raw, y.astype(np.float32), SR)
            name = f"{scene['sceneId']}_{n:02d}_{line['speaker']}.wav"
            path = os.path.join(out_dir, name)
            shift = f"rubberband=pitch={prof['pitch']}:formant={prof.get('formant', 'shifted')}:pitchq=quality," \
                if abs(float(prof.get("pitch", 1.0)) - 1.0) > 1e-3 else ""
            # Corta silêncio do começo/fim (Edge acrescenta) para a fala cair no tempo do roteiro.
            trim = "silenceremove=start_periods=1:start_threshold=-45dB,areverse," \
                   "silenceremove=start_periods=1:start_threshold=-45dB,areverse,"
            af = f"{trim}{shift}atempo={prof.get('tempo', 1.0)},loudnorm=I=-16:TP=-1.5"
            subprocess.run([FFMPEG, "-v", "error", "-y", "-i", raw, "-af", af, "-ar", str(SR), "-ac", "1", path],
                           check=True, shell=False)
            duration = sf.info(path).duration
            end = min(float(line["time"]) + duration + 0.15, float(scene["duration"]))
            if float(line["time"]) + duration > float(scene["duration"]) + 1e-6:
                sys.exit(f"ERRO: fala '{line['text']}' ({duration:.2f}s) não cabe na cena {scene['sceneId']}")
            scene["dialogues"].append({"time": line["time"], "duration": round(end - float(line["time"]), 3),
                                       "text": line["text"], "speaker": line["speaker"]})
            scene["sounds"].append({"time": line["time"], "path": f"{slug}/{name}", "volume": line.get("volume", 1.0)})
            report.append((scene["sceneId"], line["speaker"], round(duration, 2), line["text"]))
        scene["dialogues"].sort(key=lambda d: d["time"])
    story.pop("audioSlug", None)
    json.dump(story, open(dst, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    for r in report:
        print("FALA %-10s %-5s %5.2fs  %s" % r)
    print("STORY", dst, "falas", len(report), "pasta", out_dir)


if __name__ == "__main__":
    main()
