#!/usr/bin/env python3
"""把 RenderMonitorIconFrames 导出的 PNG 组装成自包含预览页。

用法:
    python3 Scripts/BuildMonitorIconPreview.py

产物: Design/MonitorInputIcon/preview.html（所有帧内嵌为 base64，可离线打开）
"""

import base64
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FRAMES = ROOT / "Design" / "MonitorInputIcon" / "frames"
OUTPUT = ROOT / "Design" / "MonitorInputIcon" / "preview.html"

FRAME_NOTES = [
    "按压蓄力 · 源芯片 0.93×",
    "起跳 · 信号球 1.25×",
    "入轨 · 16%",
    "中段 · 50%",
    "接近 · 84%",
    "落位 · 过冲 + 屏幕失步",
    "新画面点亮 · 55%",
    "稳定 · LED 换色",
    "扫光起",
    "扫光过",
    "收",
    "静息",
]


def png_b64(path: Path) -> str:
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode()


def jpeg_b64(path: Path, quality: int = 92) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / (path.stem + ".jpg")
        subprocess.run(
            ["sips", "-s", "format", "jpeg", "-s", "formatOptions", str(quality),
             str(path), "--out", str(out)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return "data:image/jpeg;base64," + base64.b64encode(out.read_bytes()).decode()


def sequence(prefix: str) -> list[str]:
    return [jpeg_b64(FRAMES / f"{prefix}-{i:02d}.png") for i in range(12)]


def ambient(source: str) -> list[str]:
    return [jpeg_b64(FRAMES / f"ambient-{source}-{i:02d}.png") for i in range(6)]


data = {
    "idle": {
        "mac": png_b64(FRAMES / "idle-mac-448.png"),
        "pc": png_b64(FRAMES / "idle-pc-448.png"),
    },
    "m2p": sequence("m2p"),
    "p2m": sequence("p2m"),
    "ambient": {"mac": ambient("mac"), "pc": ambient("pc")},
    "notes": FRAME_NOTES,
}

TEMPLATE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Toggle Monitor — 动效键面 / OpenDeck</title>
<style>
  :root{
    --bg:#07080b; --panel:#0b0d12; --panel-2:#0f1218;
    --line:rgba(255,255,255,.075); --line-strong:rgba(255,255,255,.14);
    --text:#e8ebf1; --muted:#8d95a6; --faint:#5a6272;
    --mac:#4da3ff; --pc:#ffa94d; --accent:var(--mac);
    --mono:"SF Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
  }
  *{box-sizing:border-box}
  html{background:var(--bg)}
  body{
    margin:0; color:var(--text);
    font:15px/1.62 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;
    background:
      radial-gradient(1100px 720px at 18% -12%, #101a2b 0%, rgba(7,8,11,0) 62%),
      radial-gradient(900px 620px at 92% 8%, rgba(255,169,77,.055) 0%, rgba(7,8,11,0) 58%),
      var(--bg);
    min-height:100vh;
  }
  body::before{
    content:""; position:fixed; inset:0; pointer-events:none; z-index:0;
    background-image:
      linear-gradient(rgba(255,255,255,.028) 1px, transparent 1px),
      linear-gradient(90deg, rgba(255,255,255,.028) 1px, transparent 1px);
    background-size:36px 36px;
    mask-image:radial-gradient(720px 520px at 30% 0%, #000 0%, transparent 78%);
  }
  .wrap{position:relative; z-index:1; max-width:1180px; margin:0 auto; padding:44px 28px 64px}
  .eyebrow{
    font:600 11px/1 var(--mono); letter-spacing:.18em; text-transform:uppercase;
    color:var(--faint); display:flex; align-items:center; gap:10px; margin-bottom:18px;
  }
  .eyebrow i{width:22px; height:1px; background:linear-gradient(90deg,var(--mac),var(--pc)); display:block}
  h1{
    margin:0 0 10px; font-size:clamp(34px,5vw,54px); line-height:1.06; letter-spacing:-.03em; font-weight:650;
    background:linear-gradient(100deg,#fff 12%,var(--mac) 52%,var(--pc) 92%);
    -webkit-background-clip:text; background-clip:text; color:transparent;
  }
  .lede{margin:0; color:var(--muted); max-width:640px; font-size:16px}
  .lede code{font-family:var(--mono); font-size:.92em; color:#c6ccda}

  .hero{display:grid; grid-template-columns:minmax(0,1.03fr) minmax(0,.97fr); gap:52px; align-items:center; margin-top:44px}
  @media(max-width:880px){.hero{grid-template-columns:1fr; gap:32px}}

  .stage-wrap{display:flex; flex-direction:column; align-items:center; gap:14px}
  .stage{
    position:relative; width:336px; max-width:100%; aspect-ratio:1;
    border-radius:20px; overflow:hidden; background:#04060a;
    border:1px solid var(--line-strong);
    box-shadow:
      0 40px 100px -42px var(--accent),
      0 12px 34px -18px rgba(0,0,0,.9),
      inset 0 1px 0 rgba(255,255,255,.06);
    transition:box-shadow .5s ease;
  }
  .stage img{width:100%; height:100%; display:block; object-fit:contain}
  .stage .zoom{
    position:absolute; top:10px; right:12px; font:600 10px/1 var(--mono); letter-spacing:.08em;
    color:rgba(255,255,255,.42); background:rgba(0,0,0,.42); border:1px solid rgba(255,255,255,.08);
    padding:5px 7px; border-radius:999px; backdrop-filter:blur(6px);
  }
  .stage-caption{display:flex; align-items:center; gap:12px; color:var(--faint); font:11px/1 var(--mono); letter-spacing:.06em}
  .native{
    width:112px; height:112px; border-radius:12px; overflow:hidden; background:#04060a;
    border:1px solid var(--line); box-shadow:0 10px 26px -14px rgba(0,0,0,.9);
  }
  .native img{width:100%; height:100%; display:block}

  .info{display:flex; flex-direction:column; gap:20px}
  .state-row{display:flex; align-items:center; gap:12px; flex-wrap:wrap}
  .pill{
    display:inline-flex; align-items:center; gap:9px; padding:7px 12px 7px 10px;
    border-radius:999px; border:1px solid var(--line-strong); background:rgba(255,255,255,.03);
    font:600 12px/1 var(--mono); letter-spacing:.04em;
  }
  .pill .dot{width:7px; height:7px; border-radius:50%; background:var(--accent); box-shadow:0 0 12px var(--accent)}
  .frame-tag{font:11px/1 var(--mono); color:var(--faint); letter-spacing:.06em}
  .info h2{margin:2px 0 0; font-size:24px; letter-spacing:-.015em; font-weight:620}
  .info p{margin:0; color:var(--muted); font-size:14.5px}
  .info p b{color:#d8dde8; font-weight:600}

  .controls{display:flex; flex-wrap:wrap; gap:10px; margin-top:4px}
  button{
    appearance:none; cursor:pointer; border-radius:10px; border:1px solid var(--line-strong);
    background:rgba(255,255,255,.035); color:var(--text); font:600 12.5px/1 -apple-system,sans-serif;
    padding:11px 14px; display:inline-flex; align-items:center; gap:8px;
    transition:transform .16s cubic-bezier(.23,1,.32,1), background .16s, border-color .16s;
  }
  button:hover{transform:translateY(-1px); background:rgba(255,255,255,.06)}
  button:active{transform:translateY(0) scale(.985)}
  button.primary{border-color:rgba(77,163,255,.45); background:linear-gradient(180deg,rgba(77,163,255,.20),rgba(77,163,255,.10))}
  button.warm{border-color:rgba(255,169,77,.42); background:linear-gradient(180deg,rgba(255,169,77,.17),rgba(255,169,77,.08))}
  button.ghost{border-color:var(--line); color:var(--muted)}
  .kbd{font:10px/1 var(--mono); color:var(--faint); border:1px solid var(--line); border-radius:4px; padding:3px 5px}
  .toggle-row{display:flex; align-items:center; gap:14px; color:var(--muted); font-size:12.5px; margin-top:2px}
  .toggle-row label{display:inline-flex; align-items:center; gap:7px; cursor:pointer}
  input[type=checkbox]{accent-color:var(--accent); width:14px; height:14px}

  .section{margin-top:64px}
  .section-head{display:flex; align-items:baseline; justify-content:space-between; gap:16px; border-bottom:1px solid var(--line); padding-bottom:12px; margin-bottom:20px}
  .section-head h3{margin:0; font-size:15px; letter-spacing:.01em; font-weight:620}
  .section-head span{font:11px/1 var(--mono); color:var(--faint); letter-spacing:.06em}
  .filmstrip{display:grid; grid-template-columns:repeat(12,minmax(0,1fr)); gap:7px}
  @media(max-width:880px){.filmstrip{grid-template-columns:repeat(6,minmax(0,1fr))}}
  .cell{
    appearance:none; padding:5px; border-radius:9px; border:1px solid transparent; background:rgba(255,255,255,.02);
    display:flex; flex-direction:column; gap:5px; align-items:stretch; cursor:pointer;
  }
  .cell:hover{background:rgba(255,255,255,.05)}
  .cell.active{border-color:var(--accent); background:rgba(255,255,255,.05); box-shadow:0 0 0 1px rgba(0,0,0,.6) inset}
  .cell img{width:100%; aspect-ratio:1; display:block; border-radius:5px; background:#04060a}
  .cell b{font:600 9.5px/1 var(--mono); color:var(--faint); letter-spacing:.06em; text-align:center}
  .cell.active b{color:var(--accent)}
  .note-line{margin-top:12px; font:11.5px/1.5 var(--mono); color:var(--faint); min-height:18px}
  .note-line b{color:#c9d0dd; font-weight:600}

  .spec-grid{display:grid; grid-template-columns:minmax(0,1.35fr) minmax(0,.65fr); gap:38px}
  @media(max-width:880px){.spec-grid{grid-template-columns:1fr}}
  table{width:100%; border-collapse:collapse; font-size:13px}
  th{text-align:left; font:600 10px/1 var(--mono); letter-spacing:.1em; text-transform:uppercase; color:var(--faint); padding:0 10px 9px 0; border-bottom:1px solid var(--line)}
  td{padding:10px 10px 10px 0; border-bottom:1px solid rgba(255,255,255,.045); vertical-align:top; color:var(--muted)}
  td.f{font-family:var(--mono); color:#cfd5e1; white-space:nowrap; font-size:12px}
  td.t{font-family:var(--mono); color:var(--faint); white-space:nowrap; font-size:11.5px}
  td b{color:#e3e7ef; font-weight:600}
  .tokens{display:flex; flex-direction:column; gap:0}
  .token{display:flex; justify-content:space-between; gap:16px; padding:10px 0; border-bottom:1px solid rgba(255,255,255,.045); font-size:12.5px}
  .token span{color:var(--faint)}
  .token b{font-family:var(--mono); font-weight:600; color:#cfd5e1; font-size:11.5px; text-align:right}
  .swatches{display:flex; gap:8px; margin-top:14px; flex-wrap:wrap}
  .swatch{display:flex; align-items:center; gap:7px; font:10.5px/1 var(--mono); color:var(--faint); border:1px solid var(--line); border-radius:7px; padding:6px 8px}
  .swatch i{width:10px; height:10px; border-radius:3px; display:block}
  .note{font-size:12.5px; color:var(--faint); line-height:1.7}
  .note b{color:#c9d0dd; font-weight:600}
  .footer{margin-top:56px; padding-top:18px; border-top:1px solid var(--line); display:flex; justify-content:space-between; gap:20px; flex-wrap:wrap; font:11px/1.6 var(--mono); color:var(--faint)}
  .footer a{color:var(--muted); text-decoration:none}
</style>
</head>
<body>
<div class="wrap">
  <div class="eyebrow"><i></i>OpenDeck · 槽位 1 · 112 × 112</div>
  <h1>Toggle Monitor</h1>
  <p class="lede">LG 27GP95U 输入源切换。不是“显示器开关”，而是 <b>信号从一台机器搬到另一台</b>：Mac 的 DP 与 PC 的 HDMI1。键面在静息时回答“现在谁在屏”，按压时把这次搬家演给你看。</p>

  <section class="hero">
    <div class="stage-wrap">
      <div class="stage" id="stage">
        <img id="screen" alt="动效键面预览">
        <span class="zoom">×3</span>
      </div>
      <div class="stage-caption">
        <span>设备原生 112 × 112</span>
        <span>·</span>
        <span>预览 ×3</span>
        <div class="native"><img id="native" alt="112px 实际尺寸"></div>
      </div>
    </div>

    <div class="info">
      <div class="state-row">
        <span class="pill"><span class="dot"></span><span id="state">Mac 在屏</span></span>
        <span class="frame-tag" id="frameTag">静息 · f11</span>
      </div>
      <h2>信号搬家，不是开关</h2>
      <p>源芯片压一下，信号球起跳；越过底座上方，落进另一枚芯片；显示器先失步、再点亮。所有节奏都在 <b>12fps 的整数帧</b>上，预览里的每一帧就是设备上真实下发的位图。</p>
      <div class="controls">
        <button class="primary" data-dir="m2p">▶ Mac → PC</button>
        <button class="warm" data-dir="p2m">▶ PC → Mac</button>
        <button class="ghost" id="ambient">静息呼吸</button>
        <span class="kbd">空格重播</span>
      </div>
      <div class="toggle-row">
        <label><input type="checkbox" id="loop"> 循环两个方向</label>
        <span>·</span>
        <span>点击下方任意帧可逐帧检视</span>
      </div>
    </div>
  </section>

  <section class="section">
    <div class="section-head">
      <h3>12 帧时间轴</h3>
      <span id="dirLabel">MAC → PC</span>
    </div>
    <div class="filmstrip" id="filmstrip"></div>
    <div class="note-line" id="noteLine"><b>f00</b> 按压蓄力 · 源芯片 0.93×</div>
  </section>

  <section class="section">
    <div class="section-head">
      <h3>动效规格</h3>
      <span>12 fps · 12 frames · 1.0 s</span>
    </div>
    <div class="spec-grid">
      <div>
        <table>
          <thead><tr><th>帧</th><th>时间</th><th>节拍</th><th>发生什么</th></tr></thead>
          <tbody>
            <tr><td class="f">00</td><td class="t">0 ms</td><td><b>按压</b></td><td>源芯片压到 0.93×，屏幕内容向反方向偏 1px（预备动作）。</td></tr>
            <tr><td class="f">01</td><td class="t">83 ms</td><td><b>起跳</b></td><td>信号球 1.25× 充电，仍停在源点；旧链路开始退亮。</td></tr>
            <tr><td class="f">02–04</td><td class="t">167–333 ms</td><td><b>迁移</b></td><td>沿二次贝塞尔走 0.16 → 0.50 → 0.84，三层拖尾；旧芯片 0.80 → 0.42。</td></tr>
            <tr><td class="f">05</td><td class="t">417 ms</td><td><b>落位 / 失步</b></td><td>1.4px 过冲，冲击环 3.5 → 8；屏幕切黑，只留一条残余扫描线。</td></tr>
            <tr><td class="f">06</td><td class="t">500 ms</td><td><b>点亮</b></td><td>新画面 55% 亮度、1.05× 缩放、源色闪光 0.38；新链路画到 90%。</td></tr>
            <tr><td class="f">07</td><td class="t">583 ms</td><td><b>稳定</b></td><td>画面 100%，LED 完成换色，冲击环收回 0.10。</td></tr>
            <tr><td class="f">08–09</td><td class="t">667–750 ms</td><td><b>扫光</b></td><td>一条 10% → 20% 的白色高光带掠过屏幕，是“点亮完成”的收尾。</td></tr>
            <tr><td class="f">10–11</td><td class="t">833–917 ms</td><td><b>静息</b></td><td>所有元素归位；第 12 帧保持到 1.0 s，随后进入静息呼吸。</td></tr>
          </tbody>
        </table>
        <div class="swatches">
          <span class="swatch"><i style="background:#4da3ff"></i>Mac #4DA3FF</span>
          <span class="swatch"><i style="background:#ffa94d"></i>PC #FFA94D</span>
          <span class="swatch"><i style="background:#04060a;border:1px solid rgba(255,255,255,.16)"></i>底 #04060A</span>
          <span class="swatch"><i style="background:#2a3140"></i>机身 #2A3140</span>
        </div>
      </div>

      <div class="tokens">
        <div class="token"><span>画布 / 安全区</span><b>112 × 112 / 8 px</b></div>
        <div class="token"><span>显示器</span><b>64 × 44 @ (24,20)</b></div>
        <div class="token"><span>源芯片</span><b>26 × 16 · r5</b></div>
        <div class="token"><span>迁移曲线</span><b>cubic(.77,0,.175,1)</b></div>
        <div class="token"><span>点亮曲线</span><b>cubic(.23,1,.32,1)</b></div>
        <div class="token"><span>静息呼吸</span><b>6 fps × 6 帧 / 8 s</b></div>
        <div class="token"><span>JPEG 体积</span><b>≈ 3.9 KB / 帧</b></div>
        <div class="token"><span>设备方向</span><b>预旋转 180°</b></div>
        <div class="token"><span>状态来源</span><b>~/.cache/lg_input</b></div>
        <div class="token"><span>失败回退</span><b>3 s 未确认 → 回退</b></div>
        <div class="note" style="margin-top:16px">
          <b>为什么是 12fps。</b>键面通过 USB HID 逐帧写 JPEG，小屏上的连续 60fps 既无必要也会挤占带宽。12fps 是动画的“一拍二”：关键姿态清晰、拖尾可读，且与真机 0.4–0.6 s 的输入握手时间同量级。<br><br>
          <b>为什么可以动。</b>这不是高频 UI 控件，而是硬件状态显示：动效承担“现在谁在屏”和“刚刚发生了什么”。静息态完全静止，只有每 8 s 一次的极轻信号呼吸；系统开启“减弱动态效果”时，呼吸自动关闭。
        </div>
        <div class="note" style="margin-top:12px">
          生产实现：<b>MonitorInputIcon.swift</b>（渲染）· <b>MonitorInputAnimator.swift</b>（状态机）。<br>
          乐观切换 → 状态文件对账 → 超时回退，三步收敛。
        </div>
      </div>
    </div>
  </section>

  <div class="footer">
    <span>OpenDeck · 槽位 1 · config.animation = "monitorInput"</span>
    <span>帧由生产渲染器直接导出 · 点击帧可逐帧核对</span>
  </div>
</div>

<script>
const DATA = /*__DATA__*/;
const $ = (id) => document.getElementById(id);
const screenEl = $('screen'), nativeEl = $('native');
const filmstrip = $('filmstrip'), noteLine = $('noteLine');
const stateEl = $('state'), frameTag = $('frameTag'), dirLabel = $('dirLabel');
const stage = $('stage');

let dir = 'm2p';
let index = 11;
let mode = 'idle';           // idle | play | ambient | scrub
let raf = 0;
let loopTimer = 0;
let finishTimer = 0;
let currentSource = 'mac';

const FRAME_MS = 1000 / 12;
const AMBIENT_MS = 1000 / 6;

function accent(hex) { document.documentElement.style.setProperty('--accent', hex); }

function sourceForDir(d) { return d === 'm2p' ? 'pc' : 'mac'; }

function idleImage(source) { return DATA.idle[source]; }

function setIdle(source, tag) {
  mode = 'idle';
  currentSource = source;
  index = 11;
  screenEl.src = idleImage(source);
  nativeEl.src = idleImage(source);
  accent(source === 'mac' ? '#4da3ff' : '#ffa94d');
  stateEl.textContent = source === 'mac' ? 'Mac 在屏' : 'PC 在屏';
  frameTag.textContent = tag || '静息 · f11';
  noteLine.innerHTML = '<b>f11</b> 静息 · ' + (source === 'mac' ? 'Mac 在屏' : 'PC 在屏');
  renderFilmstrip(dir);
  setActive(index);
}

function setFrame(src, i, tag) {
  screenEl.src = src;
  nativeEl.src = src;
  index = i;
  frameTag.textContent = tag;
  setActive(i);
  noteLine.innerHTML = '<b>f' + String(i).padStart(2, '0') + '</b> ' + DATA.notes[i];
}

function setActive(i) {
  [...filmstrip.children].forEach((cell, k) => cell.classList.toggle('active', k === i));
}

function renderFilmstrip(d) {
  const frames = DATA[d];
  filmstrip.innerHTML = '';
  frames.forEach((src, i) => {
    const b = document.createElement('button');
    b.className = 'cell';
    b.title = 'f' + String(i).padStart(2, '0') + ' · ' + DATA.notes[i];
    b.innerHTML = '<img src="' + src + '" alt=""><b>' + String(i).padStart(2, '0') + '</b>';
    b.addEventListener('click', () => {
      stop();
      mode = 'scrub';
      dir = d;
      accent(d === 'm2p' ? '#4da3ff' : '#ffa94d');
      stateEl.textContent = d === 'm2p' ? 'Mac → PC' : 'PC → Mac';
      setFrame(src, i, '检视 · f' + String(i).padStart(2, '0'));
    });
    filmstrip.appendChild(b);
  });
  dirLabel.textContent = d === 'm2p' ? 'MAC → PC' : 'PC → MAC';
  setActive(index);
}

function stop() {
  cancelAnimationFrame(raf);
  raf = 0;
  clearTimeout(loopTimer);
  loopTimer = 0;
  clearTimeout(finishTimer);
  finishTimer = 0;
}

function play(d, options = {}) {
  stop();
  dir = d;
  mode = 'play';
  renderFilmstrip(d);
  accent(d === 'm2p' ? '#4da3ff' : '#ffa94d');
  stateEl.textContent = d === 'm2p' ? 'Mac → PC' : 'PC → Mac';
  const frames = DATA[d];
  const start = performance.now();
  let shown = -1;
  // rAF 在隐藏页/极端调度下可能停摆;用绝对时长兜底收尾,保证最终态一定落下
  finishTimer = setTimeout(() => {
    if (mode === 'play') {
      const target = sourceForDir(d);
      setIdle(target, '落定 · ' + (target === 'mac' ? 'Mac 在屏' : 'PC 在屏'));
    }
  }, frames.length * FRAME_MS + 60);

  function tick(now) {
    const elapsed = now - start;
    const step = Math.min(frames.length - 1, Math.floor(elapsed / FRAME_MS));
    if (step !== shown) {
      shown = step;
      setFrame(frames[step], step, '切换 · f' + String(step).padStart(2, '0') + ' / 11');
    }
    if (elapsed >= frames.length * FRAME_MS) {
      raf = 0;
      const target = sourceForDir(d);
      setIdle(target, '落定 · ' + (target === 'mac' ? 'Mac 在屏' : 'PC 在屏'));
      if (options.loop || $('loop').checked) {
        loopTimer = setTimeout(() => play(d === 'm2p' ? 'p2m' : 'm2p', { loop: true }), 700);
      }
      return;
    }
    raf = requestAnimationFrame(tick);
  }
  setFrame(frames[0], 0, '切换 · f00 / 11');
  raf = requestAnimationFrame(tick);
}

function playAmbient() {
  stop();
  mode = 'ambient';
  const frames = DATA.ambient[currentSource];
  accent(currentSource === 'mac' ? '#4da3ff' : '#ffa94d');
  stateEl.textContent = '静息呼吸';
  const start = performance.now();
  let shown = -1;
  function tick(now) {
    const step = Math.min(frames.length - 1, Math.floor((now - start) / AMBIENT_MS));
    if (step !== shown) {
      shown = step;
      screenEl.src = frames[step];
      nativeEl.src = frames[step];
      frameTag.textContent = '呼吸 · ' + (step + 1) + '/6';
    }
    if (step >= frames.length - 1) {
      raf = 0;
      setIdle(currentSource, '静息 · 信号包已到达');
      return;
    }
    raf = requestAnimationFrame(tick);
  }
  raf = requestAnimationFrame(tick);
}

document.querySelectorAll('[data-dir]').forEach((button) => {
  button.addEventListener('click', () => play(button.dataset.dir));
});
$('ambient').addEventListener('click', playAmbient);
$('loop').addEventListener('change', () => {
  if (!$('loop').checked) stop();
});
window.addEventListener('keydown', (e) => {
  if (e.code === 'Space') {
    e.preventDefault();
    play(dir, { loop: $('loop').checked });
  }
  if (e.code === 'ArrowRight' || e.code === 'ArrowLeft') {
    e.preventDefault();
    stop();
    const delta = e.code === 'ArrowRight' ? 1 : -1;
    const next = Math.max(0, Math.min(11, index + delta));
    mode = 'scrub';
    setFrame(DATA[dir][next], next, '检视 · f' + String(next).padStart(2, '0'));
  }
});

// 初始:Mac 在屏(与设备当前状态一致)
setIdle('mac');
</script>
</body>
</html>
"""

html = TEMPLATE.replace("/*__DATA__*/", json.dumps(data, ensure_ascii=False))
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
OUTPUT.write_text(html, encoding="utf-8")
print(f"✓ {OUTPUT} ({OUTPUT.stat().st_size / 1024:.0f} KB)")
