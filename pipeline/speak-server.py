#!/usr/bin/env python
"""若娜瓦音色常驻 TTS 服务（qq-bridge 用）

设计目标：模型只加载一次常驻显存，之后按请求合成；产物直接落进 qq-bridge 的语音库，
让桥接用它既有的 qq_send_voice 通道发出去（额度/白名单/回读校验全部复用）。

启动（用 setup-ronova-tts.ps1 建好的 venv）：
    $env:COSYVOICE_DIR = "E:\\新建文件夹 (2)\\ronova-cosyvoice3\\ronova-cosyvoice3\\CosyVoice"
    & "E:\\新建文件夹 (2)\\ronova-cosyvoice3\\ronova-cosyvoice3\\.venv\\Scripts\\python.exe" `
        "D:\\Backup\\Documents\\deepseek-harness\\default-workspace\\speak-server.py" `
        --audio-dir "D:\\Backup\\Documents\\deepseek-harness\\qq-bridge\\audio" --port 8188

接口（只监听 127.0.0.1）：
    GET  /health -> {ok, sampleRate, langs, cleanOnly, queue}
    POST /tts    {text, lang?, speed?, seed?, clean?, name?} -> {ok, file, bytes, seconds, ms, cleaned}
    POST /clean  {text} -> {ok, cleaned}        # 只看文本清洗结果，不合成

并发：GPU 推理串行化（一把锁 + 排队计数），避免同卡并发把显存打爆。
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# The service is launched by a PowerShell supervisor and its stdout is tee'd into a log file.
# On Windows the child defaults to the ANSI code page, which mangles CJK log lines; force
# UTF-8 so the log stays readable.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = Path(r"E:\新建文件夹 (2)\ronova-cosyvoice3\ronova-cosyvoice3")
DEFAULT_AUDIO = Path(r"D:\Backup\Documents\deepseek-harness\qq-bridge\audio")

sys.path[:0] = [str(DEFAULT_ROOT)]

# ---------------------------------------------------------------- 文本清洗
# 规则来自用户选择：「剥离并转成短停顿」。
# 括号动作、Markdown、链接、CQ 码都不该被念出来，但要保留自然停顿。

_PAUSE = "，"
_CQ = re.compile(r"\[CQ:[^\]]*\]")
_FENCE = re.compile(r"```.*?```", re.S)
_INLINE_CODE = re.compile(r"`([^`]*)`")
_MD_LINK = re.compile(r"\[([^\]]*)\]\((?:[^)]*)\)")           # [文字](url) -> 文字
_URL = re.compile(r"(?:https?://|www\.)\S+", re.I)
_HEADING = re.compile(r"^\s{0,3}#{1,6}\s*", re.M)
_QUOTE = re.compile(r"^\s{0,3}>\s?", re.M)
_BULLET = re.compile(r"^\s{0,3}(?:[-*+•·]|\d+[.)])\s+", re.M)
_EMPHASIS = re.compile(r"(\*\*|__|\*|~~)")                    # 粗体/斜体/删除线标记
_BRACKETS = [
    re.compile(r"（[^（）]*）"),   # 全角圆括号：动作/旁白
    re.compile(r"\([^()]*\)"),     # 半角圆括号
    re.compile(r"【[^【】]*】"),   # 方头括号
    re.compile(r"〔[^〔〕]*〕"),
]
_EMOJI = re.compile(
    "[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F000-\U0001F2FF\uFE0F\u200d]+"
)
_WS = re.compile(r"[ \t\u3000]+")
_MULTI_PUNCT = re.compile(r"[，,。.！!？?；;、]{2,}")


def clean_text(text: str) -> str:
    """把不该念出来的东西剥掉，并换成自然停顿。用户已确认此策略。"""
    s = str(text or "")

    s = _FENCE.sub(_PAUSE, s)          # 代码块整段丢弃
    s = _CQ.sub("", s)                 # CQ 码
    s = _MD_LINK.sub(r"\1", s)         # 链接只留文字
    s = _INLINE_CODE.sub(r"\1", s)     # 行内代码留内容
    s = _HEADING.sub("", s)            # # 标题标记
    s = _QUOTE.sub("", s)              # > 引用标记
    s = _BULLET.sub("", s)             # 列表符号
    s = _EMPHASIS.sub("", s)           # **加粗** 等标记（注：<strong> 是 CosyVoice 的朗读标注，不清）
    s = _URL.sub(_PAUSE, s)            # 裸 URL
    for rx in _BRACKETS:               # 括号动作 -> 停顿
        s = rx.sub(_PAUSE, s)
    s = _EMOJI.sub("", s)

    s = s.replace("\r\n", "\n").replace("\r", "\n")
    s = s.replace("\n", _PAUSE)        # 换行 -> 停顿
    s = _WS.sub(" ", s)
    s = _MULTI_PUNCT.sub(_PAUSE, s)
    s = re.sub(rf"^\s*{_PAUSE}+|{_PAUSE}+\s*$", "", s)
    s = re.sub(rf"{_PAUSE}\s*{_PAUSE}", _PAUSE, s)
    return s.strip()


# ---------------------------------------------------------------- TTS 引擎
class Engine:
    def __init__(self, root: Path, model: str | None, audio_dir: Path, speed: float = 1.0):
        self.root = root
        self.audio_dir = audio_dir
        self.speed = float(speed)
        self.lock = threading.Lock()          # GPU 串行
        self.queued = 0
        self.by_lang: dict[str, list[Path]] = {}   # 语言 -> 生成的音频（供 qq_list_voices 风格浏览）

        audio_dir.mkdir(parents=True, exist_ok=True)
        t0 = time.time()
        print(f"[tts] 加载模型 …（{root}）", flush=True)
        from ronova_tts import Ronova
        self.voice = Ronova(model)
        print(
            f"[tts] 模型就绪 {time.time() - t0:.1f}s  sampleRate={self.voice.sample_rate}",
            flush=True,
        )

    @property
    def sample_rate(self) -> int:
        return int(self.voice.sample_rate)

    def langs(self) -> list[str]:
        try:
            return sorted(self.voice.cfg["refs"].keys())
        except Exception:
            return ["zh"]

    def synth(self, text: str, lang: str = "zh", speed: float | None = None,
              seed: int = 1, clean: bool = True) -> dict:
        spoken = clean_text(text) if clean else str(text).strip()
        if not spoken:
            raise ValueError("清洗后没有可朗读的内容")
        sp = self.speed if speed is None else float(speed)
        key = hashlib.sha1(f"{spoken}|{lang}|{sp}|{seed}".encode("utf-8")).hexdigest()[:16]
        out = self.audio_dir / f"ronova-{key}.wav"
        if out.exists() and out.stat().st_size > 1024:
            return {"file": out.name, "path": str(out), "seconds": None, "ms": 0, "cached": True,
                    "cleaned": spoken, "lang": lang}

        import soundfile as sf

        self.queued += 1
        try:
            with self.lock:
                t0 = time.time()
                wav = self.voice.say(spoken, lang=lang, seed=int(seed), speed=sp)
                samples = int(wav.shape[1])
                sf.write(str(out), wav[0].cpu().numpy(), self.sample_rate)
                ms = int((time.time() - t0) * 1000)
        finally:
            self.queued -= 1

        self.by_lang.setdefault(lang, []).append(out)
        return {"file": out.name, "path": str(out), "seconds": round(samples / self.sample_rate, 2),
                "ms": ms, "cached": False, "cleaned": spoken, "lang": lang}


# ---------------------------------------------------------------- GPT-SoVITS 引擎
# 与若娜瓦（CosyVoice）并存：默认仍走 ronova，请求里带 engine="gpt-sovits" 才走这里。
#
# 为什么不常驻：GPT-SoVITS 的 api_v2 进程要额外吃 2~3 GB 显存，且启动要 20~40 秒。
# 所以**惰性启动**——第一次被调用时才拉起，之后复用；闲置不影响若娜瓦的响应速度。
GSV_ROOT = Path(r"E:\voice-engines\gpt-sovits\GPT-SoVITS-v2pro-20261006nvidia50x0")
GSV_PORT = 9880
# 每个音色：GPT 权重 + SoVITS 权重 + 参考音频 + 参考音频里那句话（prompt_text，必须对得上）
GSV_VOICES = {
    "qingque": {
        "gpt": GSV_ROOT / "GPT_weights_v2" / "青雀-e10.ckpt",
        "sov": GSV_ROOT / "SoVITS_weights_v2" / "青雀_e15_s405.pth",
        "ref": Path(r"E:\voice-engines\qingque_ref.wav"),
        "prompt": "杨先生问的好问题，我一时半会儿也答不上来。容我想想……",
        "label": "青雀",
    },
    "tingyun": {
        "gpt": GSV_ROOT / "GPT_weights_v2" / "停云-e10.ckpt",
        "sov": GSV_ROOT / "SoVITS_weights_v2" / "停云_e15_s525.pth",
        "ref": Path(r"E:\voice-engines\tingyun_ref.wav"),
        "prompt": "若是没个合理的解释，一旁这几位云骑大哥怕是不得不押各位一程啦。",
        "label": "停云（=忘归人）",
    },
}


class GptSovitsEngine:
    """GPT-SoVITS 推理封装：按需启动 api_v2，按音色切权重，返回 wav 文件。"""

    def __init__(self, audio_dir: Path, port: int = GSV_PORT):
        self.audio_dir = audio_dir
        self.port = int(port)
        self.lock = threading.Lock()
        self.proc = None
        self.current = None          # 当前已加载的音色
        self.queued = 0

    # -- 内部 --
    def _listening(self) -> bool:
        import socket
        with socket.socket() as s:
            s.settimeout(0.6)
            return s.connect_ex(("127.0.0.1", self.port)) == 0

    def _ensure_api(self):
        if self._listening():
            return
        py = GSV_ROOT / "runtime" / "python.exe"
        if not py.exists():
            raise RuntimeError(f"找不到 GPT-SoVITS 的 python: {py}")
        log = open(GSV_ROOT / "api.from-server.log", "ab")
        self.proc = subprocess.Popen(
            [str(py), "api_v2.py", "-a", "127.0.0.1", "-p", str(self.port)],
            cwd=str(GSV_ROOT), stdout=log, stderr=log,
        )
        for _ in range(80):                     # 最多等 240 秒
            time.sleep(3)
            if self._listening():
                print(f"[gsv] api_v2 就绪 :{self.port}", flush=True)
                return
            if self.proc.poll() is not None:
                raise RuntimeError("api_v2 启动即退出，看 api.from-server.log")
        raise RuntimeError("api_v2 启动超时")

    def _get(self, path: str, params: dict):
        import urllib.parse, urllib.request
        q = urllib.parse.urlencode(params)
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}?{q}", timeout=120) as r:
            return json.loads(r.read().decode("utf-8"))

    def _set_weights(self, voice: str):
        if self.current == voice:
            return
        v = GSV_VOICES.get(voice)
        if not v:
            raise ValueError(f"未知音色: {voice}（可用: {', '.join(GSV_VOICES)}）")
        for path, key in ((v["gpt"], "/set_gpt_weights"), (v["sov"], "/set_sovits_weights")):
            if not Path(path).exists():
                raise RuntimeError(f"权重文件缺失: {path}")
            r = self._get(key, {"weights_path": str(path)})
            if r.get("message") != "success":
                raise RuntimeError(f"{key} 失败: {r}")
        self.current = voice
        print(f"[gsv] 已切换到音色 {voice}", flush=True)

    def voices(self):
        return [{"id": k, "label": v.get("label", k)} for k, v in GSV_VOICES.items()]

    # -- 对外 --
    def synth(self, text: str, voice: str = "qingque", speed: float | None = None,
              clean: bool = True) -> dict:
        import urllib.request
        spoken = clean_text(text) if clean else str(text).strip()
        if not spoken:
            raise ValueError("清洗后没有可朗读的内容")
        v = GSV_VOICES.get(voice)
        if not v:
            raise ValueError(f"未知音色: {voice}（可用: {', '.join(GSV_VOICES)}）")
        sp = 1.0 if speed is None else float(speed)
        key = hashlib.sha1(f"{spoken}|{voice}|{sp}".encode("utf-8")).hexdigest()[:16]
        out = self.audio_dir / f"gsv-{voice}-{key}.wav"
        if out.exists() and out.stat().st_size > 1024:
            return {"file": out.name, "path": str(out), "seconds": self._wav_seconds(out),
                    "ms": 0, "cached": True, "cleaned": spoken, "engine": "gpt-sovits", "voice": voice}

        self.queued += 1
        try:
            with self.lock:
                t0 = time.time()
                self._ensure_api()
                self._set_weights(voice)
                payload = json.dumps({
                    "text": spoken, "text_lang": "zh",
                    "ref_audio_path": str(v["ref"]), "prompt_text": v["prompt"], "prompt_lang": "zh",
                    "text_split_method": "cut5", "batch_size": 1,
                    "speed_factor": sp, "media_type": "wav", "streaming_mode": False,
                }, ensure_ascii=False).encode("utf-8")
                req = urllib.request.Request(
                    f"http://127.0.0.1:{self.port}/tts", data=payload,
                    headers={"Content-Type": "application/json"}, method="POST")
                with urllib.request.urlopen(req, timeout=300) as r:
                    wav = r.read()
                if len(wav) < 2000:
                    raise RuntimeError(f"api_v2 返回内容过小（{len(wav)} 字节）")
                out.write_bytes(wav)
                ms = int((time.time() - t0) * 1000)
        finally:
            self.queued -= 1

        return {"file": out.name, "path": str(out), "seconds": self._wav_seconds(out),
                "ms": ms, "cached": False, "cleaned": spoken, "engine": "gpt-sovits", "voice": voice}

    @staticmethod
    def _wav_seconds(path: Path) -> float | None:
        try:
            import wave
            with wave.open(str(path), "rb") as w:
                return round(w.getnframes() / float(w.getframerate()), 2)
        except Exception:
            return None


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    engine: Engine = None  # type: ignore
    gsv: "GptSovitsEngine | None" = None

    def log_message(self, fmt, *args):  # 安静一点
        print(f"[http] {self.address_string()} {fmt % args}", flush=True)

    def _send(self, code: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        return json.loads(self.rfile.read(n).decode("utf-8"))

    def do_GET(self):
        if self.path.split("?")[0] == "/health":
            e = self.engine
            gsv = self.gsv
            self._send(200, {"ok": True, "sampleRate": e.sample_rate, "langs": e.langs(),
                             "queue": e.queued + (gsv.queued if gsv else 0), "audioDir": str(e.audio_dir),
                             "engines": ["ronova"] + (["gpt-sovits"] if gsv else []),
                             "voices": {"ronova": e.langs(), "gpt-sovits": gsv.voices() if gsv else []}})
        else:
            self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        route = self.path.split("?")[0]
        try:
            body = self._body()
        except Exception as exc:
            self._send(400, {"ok": False, "error": f"bad json: {exc}"})
            return
        try:
            if route == "/tts":
                text = str(body.get("text") or "")
                lang = str(body.get("lang") or "zh")
                speed = body.get("speed")
                seed = int(body.get("seed") or 1)
                clean = body.get("clean", True) is not False
                # 引擎选择：默认 ronova（若娜瓦，CosyVoice）；带 engine="gpt-sovits" 才走克隆音色
                engine = str(body.get("engine") or "ronova").strip().lower()
                voice = body.get("voice")
                if engine in ("gpt-sovits", "gptsovits", "gsv", "sovits"):
                    if not self.gsv:
                        raise ValueError("GPT-SoVITS 引擎未启用")
                    r = self.gsv.synth(text, voice=str(voice or "qingque"), speed=speed, clean=clean)
                else:
                    r = self.engine.synth(text, lang=lang, speed=speed, seed=seed, clean=clean)
                self._send(200, {"ok": True, **r})
            elif route == "/clean":
                self._send(200, {"ok": True, "cleaned": clean_text(str(body.get("text") or ""))})
            else:
                self._send(404, {"ok": False, "error": "not found"})
        except Exception as exc:
            traceback.print_exc()
            self._send(500, {"ok": False, "error": f"{type(exc).__name__}: {exc}"})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(DEFAULT_ROOT), help="若娜瓦模型包目录")
    ap.add_argument("--audio-dir", default=str(DEFAULT_AUDIO), help="输出目录（= qq-bridge 语音库）")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8188)
    ap.add_argument("--model", default=None, help="本地 Fun-CosyVoice3-0.5B-2512 目录")
    ap.add_argument("--speed", type=float, default=1.0, help="默认语速")
    ap.add_argument("--no-gsv", action="store_true", help="不启用 GPT-SoVITS 第二引擎")
    ap.add_argument("--gsv-port", type=int, default=GSV_PORT, help="GPT-SoVITS api_v2 端口")
    ap.add_argument("--clean-check", default=None, help="只打印清洗结果后退出（调试用）")
    a = ap.parse_args()

    if a.clean_check is not None:
        print(clean_text(a.clean_check))
        return

    os.environ.setdefault("COSYVOICE_DIR", str(Path(a.root) / "CosyVoice"))
    engine = Engine(Path(a.root), a.model, Path(a.audio_dir), speed=a.speed)
    Handler.engine = engine

    # GPT-SoVITS 作为第二引擎：目录存在就启用（惰性启动，不占启动时间）
    if not a.no_gsv and GSV_ROOT.exists():
        try:
            Handler.gsv = GptSovitsEngine(Path(a.audio_dir), port=a.gsv_port)
            print(f"[gsv] 引擎已注册（惰性启动）音色: {[v['id'] for v in Handler.gsv.voices()]}", flush=True)
        except Exception as exc:
            print(f"[gsv] 注册失败，跳过: {exc}", flush=True)

    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    print(f"[tts] 监听 http://{a.host}:{a.port}  音频输出 -> {engine.audio_dir}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("[tts] 退出", flush=True)


if __name__ == "__main__":
    main()
