// FakePlugin —— OpenDeck 插件宿主闭环验证夹具(零依赖:自实现 RFC6455 最小 WebSocket 客户端)。
//
// 验证点:
//   1. argv 位置协议(port/uuid/registerEvent/info)与 info JSON 合法性(缺 application.language 即崩,与 OBS 插件同款)
//   2. 注册包 {uuid, event:"registerPlugin"} 被宿主接受
//   3. 宿主注册后下发 willAppear/deviceDidConnect
//   4. setImage(自定义 data URL)→ 宿主解码/旋转/上屏
//   5. getGlobalSettings → 宿主必答 didReceiveGlobalSettings(OBS 插件硬需求)
//   6. keyDown → 插件 setState 切换 manifest 两态 → 宿主渲染对应默认图
//
// 与官方 app 宿主的差异容忍:本夹具不依赖 npm 包;官方 OBS 插件自带 webpack 打包的 ws,行为等价。

'use strict';
const net = require('net');
const crypto = require('crypto');
const RED_DATA_URL = require('./generated.js');

// argv 位置协议:argv[3]=port argv[5]=pluginUUID argv[7]=registerEvent argv[9]=info JSON
const port = Number(process.argv[3]);
const pluginUUID = process.argv[5];
const info = JSON.parse(process.argv[9]); // 类初始化即解析,非法直接崩——宿主必须给合法 JSON
if (!info.application || !info.application.language) {
  console.error('[fake] info JSON 缺 application.language,按 OBS 插件约定退出');
  process.exit(1);
}
console.log('[fake] boot: port=%d uuid=%s language=%s devices=%d',
  port, pluginUUID, info.application.language,
  (info.devices || []).length);

let state = 0;

function log(...args) { console.log('[fake]', ...args); }

const socket = net.connect(port, '127.0.0.1');
let buffer = Buffer.alloc(0);
let handshaken = false;

socket.on('connect', () => {
  const key = crypto.randomBytes(16).toString('base64');
  socket.write(
    `GET /plugin HTTP/1.1\r\n` +
    `Host: 127.0.0.1:${port}\r\n` +
    `Upgrade: websocket\r\n` +
    `Connection: Upgrade\r\n` +
    `Sec-WebSocket-Key: ${key}\r\n` +
    `Sec-WebSocket-Version: 13\r\n\r\n`);
});
socket.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  pump();
});
socket.on('error', (err) => {
  console.error('[fake] socket error:', err.message);
  process.exit(1);
});
socket.on('close', () => {
  log('宿主断开连接,进程退出(与 OBS 插件 ws.on(close, exit) 同款)');
  process.exit(0);
});

function pump() {
  if (!handshaken) {
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd < 0) return;
    const head = buffer.slice(0, headerEnd).toString();
    if (!/HTTP\/1\.1 101/.test(head)) {
      console.error('[fake] 握手被拒:', head.split('\r\n')[0]);
      process.exit(1);
    }
    buffer = buffer.slice(headerEnd + 4);
    handshaken = true;
    sendText(JSON.stringify({ uuid: pluginUUID, event: 'registerPlugin' }));
    log('已注册');
  }
  for (;;) {
    const frame = readFrame();
    if (!frame) return;
    if (frame.opcode === 0x1) {
      handle(JSON.parse(frame.payload.toString('utf8')));
    } else if (frame.opcode === 0x8) {
      log('收到 close 帧');
      process.exit(0);
    } else if (frame.opcode === 0x9) {
      sendFrame(0xA, frame.payload); // ping → pong
    }
  }
}

// 服务端帧不掩码;仅处理 text/close/ping/pong,分片帧假设不出现
function readFrame() {
  if (buffer.length < 2) return null;
  const opcode = buffer[0] & 0x0f;
  const masked = (buffer[1] & 0x80) !== 0;
  let length = buffer[1] & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2);
    offset = 4;
  } else if (length === 127) {
    if (buffer.length < 10) return null;
    length = Number(buffer.readBigUInt64BE(2));
    offset = 10;
  }
  let maskKey = null;
  if (masked) {
    maskKey = buffer.slice(offset, offset + 4);
    offset += 4;
  }
  if (buffer.length < offset + length) return null;
  const payload = Buffer.from(buffer.slice(offset, offset + length));
  if (maskKey) {
    for (let i = 0; i < payload.length; i++) payload[i] ^= maskKey[i % 4];
  }
  buffer = buffer.slice(offset + length);
  return { opcode, payload };
}

// 客户端帧必须掩码(RFC6455)
function sendFrame(opcode, payload) {
  const mask = crypto.randomBytes(4);
  const length = payload.length;
  let header;
  if (length < 126) {
    header = Buffer.from([0x80 | opcode, 0x80 | length]);
  } else if (length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  const masked = Buffer.from(payload);
  for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4];
  socket.write(Buffer.concat([header, mask, masked]));
}

function sendText(text) { sendFrame(0x1, Buffer.from(text, 'utf8')); }

function handle(msg) {
  log('<<', JSON.stringify(msg).slice(0, 180));
  switch (msg.event) {
    case 'willAppear':
      // 自定义图路径:宿主解码 data URL → 预旋转 → 上屏
      sendText(JSON.stringify({
        event: 'setImage', context: msg.context,
        payload: { image: RED_DATA_URL, target: 0 },
      }));
      sendText(JSON.stringify({
        event: 'setTitle', context: msg.context,
        payload: { title: '待命', target: 0 },
      }));
      break;
    case 'keyDown':
      state = 1 - state;
      // manifest 默认图路径:宿主按 state 渲染 States[state].Image
      sendText(JSON.stringify({
        event: 'setState', context: msg.context,
        payload: { state },
      }));
      sendText(JSON.stringify({
        event: 'setTitle', context: msg.context,
        payload: { title: state ? '运行' : '待命', target: 0 },
      }));
      break;
    case 'didReceiveGlobalSettings':
      log('全局设置应答收到 ✓(宿主必答验证通过)');
      break;
    case 'didReceiveSettings':
      log('settings 应答收到 ✓');
      break;
  }
}
