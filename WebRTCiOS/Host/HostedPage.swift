//
//  HostedPage.swift
//  手机当临时服务器时，发给其他设备浏览器的那个页面
//
//  设计约束：
//   1. 页面从手机自己发出去，所以不能引用任何 CDN（局域网可能没外网），
//      所有 JS/CSS 必须内联。
//   2. 不用 socket.io（手机上跑不了它的服务端），改用裸 WebSocket，
//      事件名见文件底部注释。
//   3. 用来演示 Mesh 通话，最多 4 人：新进来的人主动向已有人发 offer，
//      老人只回 answer，避免双方同时 offer 打架。
//

import Foundation

enum HostedPage {

    static let html = #"""
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>临时服务器 · 通话</title>
<style>
  *{box-sizing:border-box}
  html,body{margin:0;height:100%;background:#0f1420;color:#e8eef7;
    font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}
  #join{height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:24px}
  #join h1{font-size:19px;font-weight:600;margin:0 0 4px}
  #join p{margin:0;font-size:13px;color:#8b98ad;text-align:center;line-height:1.7;max-width:320px}
  #name{width:100%;max-width:300px;padding:12px 14px;border-radius:10px;border:1px solid #2b3648;
    background:#161d2b;color:#e8eef7;font-size:15px;outline:none}
  #name:focus{border-color:#3b82f6}
  #enter{width:100%;max-width:300px;padding:13px;border:none;border-radius:10px;
    background:#2563eb;color:#fff;font-size:15px;font-weight:600}
  #enter:active{background:#1d4ed8}
  .hint{font-size:12px;color:#6b7a90;text-align:center;max-width:320px;line-height:1.7}
  #room{height:100%;display:flex;flex-direction:column}
  #grid{flex:1;display:grid;gap:8px;padding:34px 8px 8px;grid-template-columns:1fr;overflow:auto;align-content:start}
  #grid.two{grid-template-columns:1fr 1fr}
  .tile{position:relative;background:#000;border-radius:10px;overflow:hidden;aspect-ratio:4/3}
  .tile video{width:100%;height:100%;object-fit:cover;display:block}
  .tile .name{position:absolute;left:8px;bottom:8px;font-size:12px;background:rgba(0,0,0,.55);
    padding:3px 8px;border-radius:6px}
  .tile .flags{position:absolute;right:8px;top:8px;font-size:11px;color:#ffb4b4}
  #bar{display:flex;gap:8px;padding:10px 12px calc(10px + env(safe-area-inset-bottom));background:#131a26}
  #bar button{flex:1;padding:12px 0;border:none;border-radius:10px;background:#1e293b;color:#cbd5e1;
    font-size:14px;font-weight:500}
  #bar button.off{background:#3b1d1d;color:#f87171}
  #bar #leave{background:#dc2626;color:#fff}
  #status{position:fixed;left:0;right:0;top:0;padding:6px 12px;font-size:12px;text-align:center;
    color:#9fb0c7;background:rgba(15,20,32,.85);backdrop-filter:blur(6px)}
</style>
</head>
<body>

<div id="join">
  <h1>加入临时服务器</h1>
  <input id="name" placeholder="输入昵称，例如：小明" maxlength="16" autocomplete="off">
  <button id="enter">进入房间</button>
  <p class="hint">这台设备会作为主持人运行在手机上。浏览器可能会提示"证书不受信任"，点「高级 → 继续前往」即可。</p>
</div>

<div id="room" hidden>
  <div id="status">连接中…</div>
  <div id="grid"></div>
  <div id="bar">
    <button id="mic">麦克风</button>
    <button id="cam">摄像头</button>
    <button id="leave">离开</button>
  </div>
</div>

<script>
(function () {
  'use strict';

  var ws = null;
  var myId = '';
  var names = new Map();     // id -> 昵称
  var peers = new Map();     // id -> { pc, tile, video }
  var localStream = null;

  var grid = document.getElementById('grid');
  var statusEl = document.getElementById('status');

  function setStatus(text) { statusEl.textContent = text; }
  function send(obj) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); }

  /* ---------- 画面格子 ---------- */

  function addTile(id, label, muted) {
    var tile = document.createElement('div');
    tile.className = 'tile';
    tile.dataset.id = id;

    var video = document.createElement('video');
    video.autoplay = true;
    video.playsInline = true;
    video.muted = !!muted;

    var nameEl = document.createElement('div');
    nameEl.className = 'name';
    nameEl.textContent = label;

    var flags = document.createElement('div');
    flags.className = 'flags';

    tile.appendChild(video);
    tile.appendChild(nameEl);
    tile.appendChild(flags);
    grid.appendChild(tile);
    layoutGrid();
    return { tile: tile, video: video, nameEl: nameEl, flags: flags };
  }

  function layoutGrid() {
    var n = grid.children.length;
    grid.classList.toggle('two', n > 1);
  }

  function removeTile(id) {
    var el = grid.querySelector('.tile[data-id="' + id + '"]');
    if (el) grid.removeChild(el);
    layoutGrid();
  }

  /* ---------- WebRTC ---------- */

  function newPeer(id) {
    var pc = new RTCPeerConnection({ iceServers: [] });
    var view = addTile(id, names.get(id) || '对方', false);
    peers.set(id, { pc: pc, view: view });

    if (localStream) {
      localStream.getTracks().forEach(function (t) { pc.addTrack(t, localStream); });
    }

    pc.ontrack = function (ev) {
      view.video.srcObject = ev.streams[0];
    };
    pc.onicecandidate = function (ev) {
      if (ev.candidate) {
        send({ t: 'signal', to: id, data: { candidate: ev.candidate.toJSON() } });
      }
    };
    pc.onconnectionstatechange = function () {
      if (pc.connectionState === 'failed') {
        removePeer(id);
        setStatus('与 ' + (names.get(id) || '对方') + ' 的连接失败（可能不在同一网段）');
      }
    };
    return peers.get(id);
  }

  async function offerTo(id) {
    var p = newPeer(id);
    try {
      var offer = await p.pc.createOffer();
      await p.pc.setLocalDescription(offer);
      send({ t: 'signal', to: id, data: { sdp: p.pc.localDescription } });
    } catch (e) {
      setStatus('建立连接失败：' + e.message);
    }
  }

  async function onSignal(from, data) {
    if (!data) return;
    var p = peers.get(from) || newPeer(from);

    try {
      if (data.sdp) {
        await p.pc.setRemoteDescription(data.sdp);
        if (data.sdp.type === 'offer') {
          var answer = await p.pc.createAnswer();
          await p.pc.setLocalDescription(answer);
          send({ t: 'signal', to: from, data: { sdp: p.pc.localDescription } });
        }
      } else if (data.candidate) {
        await p.pc.addIceCandidate(data.candidate);
      }
    } catch (e) {
      // 候选早于 SDP 到达之类的时序问题，忽略即可，后续候选会补上
    }
  }

  function removePeer(id) {
    var p = peers.get(id);
    if (!p) return;
    try { p.pc.close(); } catch (e) {}
    peers.delete(id);
    removeTile(id);
  }

  /* ---------- 信令 ---------- */

  function handle(msg) {
    switch (msg.t) {
      case 'welcome':
        myId = msg.id;
        (msg.peers || []).forEach(function (p) {
          names.set(p.id, p.name);
          offerTo(p.id);            // 新人主动向每个已存在的人发起
        });
        setStatus(msg.peers && msg.peers.length ? '已和 ' + msg.peers.length + ' 人建立连接' : '已进入房间，等待其他人…');
        break;

      case 'peer-join':
        names.set(msg.id, msg.name);
        setStatus(msg.name + ' 加入了房间');
        break;

      case 'peer-leave':
        var who = names.get(msg.id) || '有人';
        names.delete(msg.id);
        removePeer(msg.id);
        setStatus(who + ' 离开了');
        break;

      case 'signal':
        onSignal(msg.from, msg.data);
        break;

      case 'media':
        var p = peers.get(msg.from);
        if (p) {
          p.view.flags.textContent =
            (msg.audio ? '' : '🔇 ') + (msg.video ? '' : '📷');
        }
        break;
    }
  }

  /* ---------- 入口 ---------- */

  document.getElementById('enter').addEventListener('click', async function () {
    var nickname = (document.getElementById('name').value || '').trim() || '访客';

    try {
      localStream = await navigator.mediaDevices.getUserMedia({
        audio: true,
        video: { width: { ideal: 640 }, height: { ideal: 480 }, facingMode: 'user' }
      });
    } catch (e) {
      alert('打不开摄像头或麦克风：' + e.message +
            '\n\n请先确认站点证书已点「继续前往」，并允许浏览器使用摄像头。');
      return;
    }

    document.getElementById('join').hidden = true;
    document.getElementById('room').hidden = false;

    var selfView = addTile('me', nickname + '（我）', true);
    selfView.video.srcObject = localStream;

    ws = new WebSocket('wss://' + location.host + '/signal');
    ws.onopen = function () {
      send({ t: 'hello', name: nickname });
      setStatus('已连接，等待其他人…');
    };
    ws.onmessage = function (ev) {
      try { handle(JSON.parse(ev.data)); } catch (e) {}
    };
    ws.onclose = function () {
      setStatus('与服务器的连接已断开（主机可能切到后台了）');
    };
    ws.onerror = function () {
      setStatus('WebSocket 连接出错');
    };
  });

  document.getElementById('name').addEventListener('keydown', function (e) {
    if (e.key === 'Enter') document.getElementById('enter').click();
  });

  document.getElementById('mic').addEventListener('click', function () {
    var track = localStream && localStream.getAudioTracks()[0];
    if (!track) return;
    track.enabled = !track.enabled;
    this.classList.toggle('off', !track.enabled);
    send({ t: 'media', audio: track.enabled, video: camOn() });
  });

  document.getElementById('cam').addEventListener('click', function () {
    var track = localStream && localStream.getVideoTracks()[0];
    if (!track) return;
    track.enabled = !track.enabled;
    this.classList.toggle('off', !track.enabled);
    send({ t: 'media', audio: micOn(), video: track.enabled });
  });

  document.getElementById('leave').addEventListener('click', function () {
    send({ t: 'bye' });
    peers.forEach(function (p) { try { p.pc.close(); } catch (e) {} });
    if (localStream) localStream.getTracks().forEach(function (t) { t.stop(); });
    if (ws) ws.close();
    location.reload();
  });

  function micOn() {
    var t = localStream && localStream.getAudioTracks()[0];
    return t ? t.enabled : true;
  }
  function camOn() {
    var t = localStream && localStream.getVideoTracks()[0];
    return t ? t.enabled : true;
  }
})();
</script>
</body>
</html>
"""#
}
