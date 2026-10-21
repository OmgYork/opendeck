/* 原创 Q 版鲸鱼娘状态灯渲染器（112×112 设计坐标，透明底）。
   入口：drawWhale(ctx, state, frame, size)，调用方负责 clearRect。 */
(function (global) {
  'use strict';

  var COLORS = {
    idle: '#6E7681',
    working: '#2F81F7',
    permission: '#D29922',
    asking: '#D29922',
    error: '#F85149',
    ready: '#3FB950',
    done: '#3FB950'
  };

  function hexA(hex, a) {
    var r = parseInt(hex.slice(1, 3), 16), g = parseInt(hex.slice(3, 5), 16), b = parseInt(hex.slice(5, 7), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',' + a + ')';
  }

  function ell(c, x, y, rx, ry, rot, fill, stroke, lw) {
    c.save();
    c.translate(x, y);
    if (rot) c.rotate(rot);
    c.beginPath();
    c.ellipse(0, 0, rx, ry, 0, 0, Math.PI * 2);
    if (fill) { c.fillStyle = fill; c.fill(); }
    if (stroke) { c.strokeStyle = stroke; c.lineWidth = lw || 1.8; c.stroke(); }
    c.restore();
  }

  function star(c, x, y, r, color, a) {
    c.save();
    c.translate(x, y);
    c.fillStyle = color;
    c.globalAlpha = a == null ? 1 : a;
    c.beginPath();
    c.moveTo(0, -r);
    c.quadraticCurveTo(0, 0, r, 0);
    c.quadraticCurveTo(0, 0, 0, r);
    c.quadraticCurveTo(0, 0, -r, 0);
    c.quadraticCurveTo(0, 0, 0, -r);
    c.fill();
    c.restore();
  }

  function drop(c, x, y, r, color) {
    c.save();
    c.translate(x, y);
    c.fillStyle = color;
    c.beginPath();
    c.moveTo(0, -r * 1.5);
    c.bezierCurveTo(r * 0.9, -r * 0.3, r * 0.8, r * 0.8, 0, r * 0.9);
    c.bezierCurveTo(-r * 0.8, r * 0.8, -r * 0.9, -r * 0.3, 0, -r * 1.5);
    c.fill();
    c.restore();
  }

  function bubble(c, x, y, r, a) {
    c.save();
    c.strokeStyle = 'rgba(255,255,255,' + a + ')';
    c.lineWidth = 1.2;
    c.beginPath();
    c.arc(x, y, r, 0, Math.PI * 2);
    c.stroke();
    c.restore();
  }

  function arm(c, sx, sy, angle, len) {
    c.save();
    c.translate(sx, sy);
    c.rotate(angle);
    ell(c, 0, len * 0.55, 4.4, len * 0.55, 0, '#2E5A88', '#1B3A5C', 1.8);
    ell(c, 0, len * 0.98, 3.6, 3.2, 0, '#EAF6FF');
    c.restore();
  }

  function eyeOpen(c, x, y, happy) {
    if (happy) {
      c.save();
      c.strokeStyle = '#243447';
      c.lineWidth = 2;
      c.lineCap = 'round';
      c.beginPath();
      c.arc(x, y + 1.2, 3.6, Math.PI * 1.08, Math.PI * 1.92);
      c.stroke();
      c.restore();
      return;
    }
    ell(c, x, y, 3.7, 4.7, 0, '#243447');
    c.save();
    c.fillStyle = '#FFFFFF';
    c.beginPath(); c.arc(x - 1.2, y - 1.6, 1.35, 0, Math.PI * 2); c.fill();
    c.globalAlpha = 0.7;
    c.beginPath(); c.arc(x + 1.4, y + 1.5, 0.75, 0, Math.PI * 2); c.fill();
    c.restore();
  }

  function eyeClosed(c, x, y) {
    c.save();
    c.strokeStyle = '#243447';
    c.lineWidth = 2;
    c.lineCap = 'round';
    c.beginPath();
    c.arc(x, y - 0.5, 3.6, Math.PI * 0.08, Math.PI * 0.92);
    c.stroke();
    c.restore();
  }

  function eyeX(c, x, y) {
    c.save();
    c.strokeStyle = '#243447';
    c.lineWidth = 2;
    c.lineCap = 'round';
    c.beginPath();
    c.moveTo(x - 3, y - 3); c.lineTo(x + 3, y + 3);
    c.moveTo(x + 3, y - 3); c.lineTo(x - 3, y + 3);
    c.stroke();
    c.restore();
  }

  function mouthSmile(c, x, y) {
    c.save();
    c.strokeStyle = '#8A4A4A';
    c.lineWidth = 1.7;
    c.lineCap = 'round';
    c.beginPath();
    c.moveTo(x - 4, y - 1);
    c.quadraticCurveTo(x, y + 4, x + 4, y - 1);
    c.stroke();
    c.restore();
  }

  function mouthOpen(c, x, y, big) {
    ell(c, x, y + 0.6, big ? 3.6 : 2.6, big ? 3 : 2.2, 0, '#A34A56');
    ell(c, x, y + 1.8, big ? 2.2 : 1.6, 1.1, 0, '#E8808C');
  }

  function mouthWavy(c, x, y) {
    c.save();
    c.strokeStyle = '#8A4A4A';
    c.lineWidth = 1.6;
    c.lineCap = 'round';
    c.beginPath();
    c.moveTo(x - 4, y);
    c.quadraticCurveTo(x - 2, y + 2.5, x, y);
    c.quadraticCurveTo(x + 2, y - 2.5, x + 4, y);
    c.stroke();
    c.restore();
  }

  function drawWhale(c, state, frame, size) {
    state = COLORS[state] ? state : 'idle';
    var color = COLORS[state];
    var k = size / 112;
    var t = frame || 0;
    var asking = state === 'asking' || state === 'permission';
    var bob = Math.sin(t * Math.PI / 2) * 1.2;
    var bounce = state === 'done' ? -Math.abs(Math.sin(t * Math.PI / 2)) * 3.5 : 0;
    var shake = state === 'error' ? Math.sin(t * Math.PI * 1.5) * 1.5 : 0;
    var tilt = asking ? Math.sin(t * Math.PI / 2) * 0.05 : 0;
    var pulse = 0.16 + 0.16 * (0.5 + 0.5 * Math.sin(t * Math.PI / 2));

    c.save();
    c.scale(k, k);

    // 状态光晕：透明底，宿主会把它合成到键面底色（黑）上
    var g = c.createRadialGradient(56, 58, 6, 56, 58, 55);
    g.addColorStop(0, hexA(color, asking ? pulse : 0.24));
    g.addColorStop(0.65, hexA(color, asking ? pulse * 0.55 : 0.12));
    g.addColorStop(1, hexA(color, 0));
    c.fillStyle = g;
    c.beginPath(); c.arc(56, 58, 55, 0, Math.PI * 2); c.fill();

    c.translate(shake, bob + bounce);
    c.translate(56, 80); c.rotate(tilt); c.translate(-56, -80);

    var ink = '#1B3A5C';
    var hood = '#2E5A88';
    var hoodLight = '#3B6FA8';
    var belly = '#EAF6FF';
    var skin = '#FFE0CC';
    var hair = '#7FD8EE';

    // 尾巴（身后）
    c.save();
    c.translate(79, 95); c.rotate(-0.42);
    ell(c, -5.5, -4, 7.2, 3.4, 0.55, hood, ink, 1.6);
    ell(c, 5.5, -4, 7.2, 3.4, -0.55, hood, ink, 1.6);
    c.restore();

    // 身体（鲸鱼连体衣）
    ell(c, 56, 89, 19.5, 15, 0, hood, ink, 2.1);
    ell(c, 56, 91, 10.5, 8.5, 0, belly);

    // 兜帽
    ell(c, 56, 53, 30.5, 29.5, 0, hood, ink, 2.2);
    // 兜帽顶部鲸尾
    ell(c, 50.5, 25, 8.2, 3.5, -0.35, hood, ink, 1.7);
    ell(c, 61.5, 25, 8.2, 3.5, 0.35, hood, ink, 1.7);
    // 侧鳍
    ell(c, 26.5, 56, 5.6, 10.5, -0.45, hood, ink, 1.8);
    ell(c, 85.5, 56, 5.6, 10.5, 0.45, hood, ink, 1.8);
    // 兜帽高光
    c.save();
    c.strokeStyle = 'rgba(255,255,255,0.22)';
    c.lineWidth = 2.2;
    c.lineCap = 'round';
    c.beginPath();
    c.arc(56, 53, 25, Math.PI * 1.08, Math.PI * 1.42);
    c.stroke();
    c.restore();
    // 兜帽浅色内圈（脸洞）
    ell(c, 56, 58, 18.5, 17.5, 0, belly);
    ell(c, 56, 61, 15.6, 15.4, 0, skin);

    // 刘海
    c.save();
    c.fillStyle = hair;
    c.beginPath();
    c.moveTo(41.5, 56);
    c.quadraticCurveTo(41, 44, 56, 44);
    c.quadraticCurveTo(71, 44, 70.5, 56);
    c.quadraticCurveTo(66, 49.5, 56, 51.5);
    c.quadraticCurveTo(46, 49.5, 41.5, 56);
    c.fill();
    // 两侧发束
    ell(c, 40.5, 62, 4.2, 8.5, 0.18, hair, null, 0);
    ell(c, 71.5, 62, 4.2, 8.5, -0.18, hair, null, 0);
    c.restore();

    // 腮红
    ell(c, 41.8, 68.5, 4.6, 2.3, 0, 'rgba(255,140,160,0.55)');
    ell(c, 70.2, 68.5, 4.6, 2.3, 0, 'rgba(255,140,160,0.55)');

    // 眼睛 / 嘴：按状态
    var ex1 = 49, ex2 = 63, ey = 61.5;
    if (state === 'idle') {
      eyeClosed(c, ex1, ey); eyeClosed(c, ex2, ey);
      mouthSmile(c, 56, 70.5);
    } else if (state === 'done' || state === 'ready') {
      eyeOpen(c, ex1, ey, true); eyeOpen(c, ex2, ey, true);
      mouthOpen(c, 56, 70, true);
    } else if (state === 'error') {
      eyeX(c, ex1, ey); eyeX(c, ex2, ey);
      mouthWavy(c, 56, 70.5);
    } else if (state === 'working') {
      eyeOpen(c, ex1, ey, false); eyeOpen(c, ex2, ey, false);
      mouthOpen(c, 56, 70, false);
    } else {
      eyeOpen(c, ex1, ey, false); eyeOpen(c, ex2, ey, false);
      mouthSmile(c, 56, 70.5);
    }

    // 手臂
    if (state === 'asking') {
      var wave = -2.3 + Math.sin(t * Math.PI / 2) * 0.32;
      arm(c, 72, 82, wave, 19);
      arm(c, 40, 84, 0.22, 16);
      // 挥手动态线
      c.save();
      c.strokeStyle = 'rgba(255,209,102,0.85)';
      c.lineWidth = 1.8;
      c.lineCap = 'round';
      for (var i = 0; i < 2; i++) {
        var a = -0.9 + i * 0.55 + Math.sin(t * Math.PI / 2) * 0.1;
        c.beginPath();
        c.arc(84, 62, 7 + i * 3.5, a, a + 0.55);
        c.stroke();
      }
      c.restore();
    } else if (state === 'permission') {
      arm(c, 72, 82, -2.0, 18);
      arm(c, 40, 84, 0.22, 16);
    } else if (state === 'working') {
      var tw = Math.sin(t * Math.PI) * 1.6;
      arm(c, 50, 93 + tw, 0.12, 9);
      arm(c, 62, 93 - tw, -0.12, 9);
    } else if (state === 'error') {
      arm(c, 37, 80, 1.35, 15);
      arm(c, 75, 80, -1.35, 15);
    } else if (state === 'done' || state === 'ready') {
      arm(c, 37, 80, 2.45, 16);
      arm(c, 75, 80, -2.45, 16);
    } else {
      arm(c, 39, 84, 0.22, 16);
      arm(c, 73, 84, -0.22, 16);
    }

    // 状态特效
    if (state === 'idle') {
      c.save();
      c.fillStyle = 'rgba(200,222,238,0.85)';
      c.font = 'bold 10px -apple-system, sans-serif';
      var zy = -((t % 4) * 2.2);
      c.globalAlpha = 0.85;
      c.fillText('z', 78, 36 + zy);
      c.globalAlpha = 0.5;
      c.font = 'bold 7px -apple-system, sans-serif';
      c.fillText('z', 84, 30 + zy);
      c.restore();
    } else if (state === 'working') {
      var ba = [(t % 3), ((t + 1) % 3), ((t + 2) % 3)];
      for (var b = 0; b < 3; b++) {
        var rise = (ba[b] * 7) % 22;
        bubble(c, 82 - b * 4, 74 - rise, 2.2 + b * 0.7, 0.35 - b * 0.06);
      }
    } else if (state === 'permission') {
      c.save();
      c.fillStyle = '#FFD166';
      c.font = 'bold 17px -apple-system, sans-serif';
      c.textAlign = 'center';
      c.fillText('?', 85, 34 + Math.sin(t * Math.PI / 2) * 1.5);
      c.restore();
    } else if (state === 'error') {
      drop(c, 80, 42 + Math.sin(t * Math.PI) * 1.2, 2.6, '#7FD8EE');
    } else if (state === 'done' || state === 'ready') {
      var sp = [[28, 33, 5], [84, 39, 4], [77, 91, 3.5], [30, 78, 3]];
      for (var s = 0; s < sp.length; s++) {
        var ph = (t + s) % 4;
        star(c, sp[s][0], sp[s][1], sp[s][2], '#FFF3B0', 0.35 + 0.2 * ph);
      }
    }

    c.restore();
    c.restore();
  }

  global.drawWhale = drawWhale;
})(typeof window !== 'undefined' ? window : this);
