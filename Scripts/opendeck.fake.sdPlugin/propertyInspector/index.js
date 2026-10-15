// FakePlugin PI —— OpenDeck Property Inspector 全链路验证夹具。
// 契约与 OBS 插件 propertyInspector/utils/action.js 一致:
//   1. 宿主注入调用 connectElgatoStreamDeckSocket(port, uuid, registerEvent, app, info)
//      (第 2 参 = action 实例 contextID;setSettings/getGlobalSettings 的 context 都填它)
//   2. 自行回连 ws://127.0.0.1:port,注册包 {event, uuid}
//   3. 收到首条下行消息才发 getGlobalSettings;收到 didReceiveSettings 才算初始化完成
//   4. 输入变更 → setSettings(去抖),宿主须落盘并推 didReceiveSettings 给插件进程
'use strict';

let $websocket, $uuid;

window.connectElgatoStreamDeckSocket = function (port, uuid, registerEvent, app, info) {
  $uuid = uuid;
  JSON.parse(app); JSON.parse(info); // 形参契约自证:两参必须是合法 JSON 文本
  $websocket = new WebSocket('ws://127.0.0.1:' + port);
  $websocket.onopen = () => $websocket.send(JSON.stringify({ event: registerEvent, uuid }));
  let gotFirstDownlink = false;
  $websocket.onmessage = (e) => {
    const data = JSON.parse(e.data);
    if (!gotFirstDownlink) {
      gotFirstDownlink = true;
      $websocket.send(JSON.stringify({ event: 'getGlobalSettings', context: $uuid }));
    }
    if (data.event === 'didReceiveSettings') {
      document.getElementById('titleText').value = data.payload.settings.titleText || '';
      document.getElementById('status').textContent = '已连接,settings 已同步 ✓';
    }
    if (data.event === 'didReceiveGlobalSettings') {
      document.getElementById('status').textContent = '全局设置已应答 ✓';
    }
  };
  $websocket.onclose = () => {
    document.getElementById('status').textContent = '连接已断开';
  };
};

// 输入即存(300ms 去抖;与 OBS saveData 同款 setSettings 契约)
let saveTimer = null;
document.getElementById('titleText').addEventListener('input', (e) => {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    $websocket.send(JSON.stringify({
      event: 'setSettings',
      context: $uuid,
      payload: { titleText: e.target.value },
    }));
  }, 300);
});
