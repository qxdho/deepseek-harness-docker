package main

// 内嵌的单页面板。刻意不用框架：静态二进制里塞一个 HTML，零外部资源。
// 注意：这是 Go 的原始字符串，内部**不能出现反引号**，所以 JS 里不用模板字符串。
const indexHTML = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DSH 管理面板</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;
         background:#141416; color:#e8e8ea; }
  .wrap { max-width: 880px; margin: 0 auto; padding: 24px 16px 64px; }
  h1 { font-size: 18px; margin: 0 0 16px; }
  .card { background:#1d1d20; border:1px solid #2c2c31; border-radius:10px; padding:16px; margin-bottom:16px; }
  .row { display:flex; flex-wrap:wrap; gap:12px; }
  .kv { min-width: 160px; }
  .kv .k { color:#9a9aa2; font-size:12px; }
  .kv .v { font-weight:600; }
  .ok { color:#4ade80; } .bad { color:#f87171; } .warn { color:#fbbf24; }
  button { font:inherit; padding:8px 14px; border-radius:8px; border:1px solid #3a3a41;
           background:#26262b; color:#e8e8ea; cursor:pointer; }
  button:hover { background:#303038; }
  button.primary { background:#2b6cb0; border-color:#2b6cb0; }
  button.danger { background:#7f1d1d; border-color:#7f1d1d; }
  button:disabled { opacity:.5; cursor:not-allowed; }
  input { font:inherit; padding:9px 12px; border-radius:8px; border:1px solid #3a3a41;
          background:#101012; color:#e8e8ea; width:100%; }
  pre { background:#101012; border:1px solid #2c2c31; border-radius:8px; padding:12px;
        max-height:360px; overflow:auto; white-space:pre-wrap; word-break:break-all; font-size:12px; }
  table { width:100%; border-collapse:collapse; }
  td,th { text-align:left; padding:6px 8px; border-bottom:1px solid #2c2c31; }
  .muted { color:#9a9aa2; }
  #err { color:#f87171; min-height:20px; }
  #login { max-width:360px; margin:10vh auto; }
</style>
</head>
<body>
<div class="wrap">
  <div id="login" class="card">
    <h1>DSH 管理面板</h1>
    <p class="muted">输入管理密码</p>
    <input id="pw" type="password" placeholder="管理密码" autocomplete="current-password">
    <div id="err"></div>
    <button class="primary" id="loginBtn" style="margin-top:8px;width:100%">登录</button>
  </div>

  <div id="panel" style="display:none">
    <h1>DSH 管理面板 <span class="muted" style="font-weight:400;font-size:12px">容器 <span id="cname"></span></span></h1>
    <div id="err"></div>

    <div class="card">
      <div class="row">
        <div class="kv"><div class="k">状态</div><div class="v" id="status">-</div></div>
        <div class="kv"><div class="k">健康</div><div class="v" id="health">-</div></div>
        <div class="kv"><div class="k">镜像</div><div class="v" id="image">-</div></div>
        <div class="kv"><div class="k">重启次数</div><div class="v" id="restarts">-</div></div>
        <div class="kv"><div class="k">端口</div><div class="v" id="ports">-</div></div>
      </div>
      <div class="row" style="margin-top:16px">
        <button class="primary" id="btnRestart">重启</button>
        <button id="btnStop">停止</button>
        <button id="btnStart">启动</button>
        <button id="btnLogout" style="margin-left:auto">退出登录</button>
      </div>
    </div>

    <div class="card">
      <div class="row" style="align-items:center">
        <strong>磁盘占用</strong>
        <button id="btnDisk" style="margin-left:auto">刷新</button>
        <button class="danger" id="btnPrune">清理缓存</button>
      </div>
      <table><tbody id="disk"></tbody></table>
      <div class="muted" id="diskNote" style="margin-top:8px;font-size:12px"></div>
    </div>

    <div class="card">
      <div class="row" style="align-items:center">
        <strong>日志</strong>
        <button id="btnLogs" style="margin-left:auto">刷新</button>
      </div>
      <pre id="logs">（点「刷新」加载）</pre>
    </div>
  </div>
</div>

<script>
(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  function err(msg) { $('err').textContent = msg || ''; }
  function show(panel) {
    $('login').style.display = panel ? 'none' : 'block';
    $('panel').style.display = panel ? 'block' : 'none';
  }
  function api(path, opts) {
    opts = opts || {};
    var headers = { 'Accept': 'application/json' };
    if (opts.body) { headers['Content-Type'] = 'application/json'; }
    if (opts.post) { headers['X-DSH-Admin'] = '1'; }
    return fetch(path, {
      method: opts.post ? 'POST' : 'GET',
      headers: headers,
      body: opts.body ? JSON.stringify(opts.body) : undefined,
      credentials: 'same-origin',
      cache: 'no-store'
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (!r.ok) { var e = new Error(j.error || ('HTTP ' + r.status)); e.status = r.status; throw e; }
        return j;
      });
    });
  }
  function bytes(n) {
    if (n === undefined || n === null) { return '-'; }
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n : n.toFixed(1)) + ' ' + u[i];
  }

  function refreshStatus() {
    api('/api/status').then(function (s) {
      show(true);
      $('cname').textContent = s.name;
      $('status').textContent = s.status;
      $('status').className = 'v ' + (s.running ? 'ok' : 'bad');
      $('health').textContent = s.health || '-';
      $('health').className = 'v ' + (s.health === 'healthy' ? 'ok' : (s.health === 'unhealthy' ? 'bad' : 'warn'));
      $('image').textContent = s.image || '-';
      $('restarts').textContent = s.restarts;
      $('ports').textContent = (s.ports && s.ports.length) ? s.ports.join(', ') : '-';
    }).catch(function (e) {
      if (e.status === 401) { show(false); return; }
      err(e.message);
    });
  }
  function act(path, label) {
    err('');
    api(path, { post: true }).then(function () {
      $('logs').textContent = '（' + label + ' 已下发，等待恢复…）';
      setTimeout(refreshStatus, 1500);
      setTimeout(refreshStatus, 6000);
    }).catch(function (e) { err(label + ' 失败：' + e.message); });
  }
  function refreshDisk() {
    api('/api/disk').then(function (d) {
      var rows = [
        ['镜像', d.images], ['容器可写层', d.containers],
        ['数据卷', d.volumes], ['构建缓存', d.buildCache], ['合计', d.total]
      ];
      var html = '';
      rows.forEach(function (r) {
        html += '<tr><td>' + r[0] + '</td><td>' + bytes(r[1]) + '</td></tr>';
      });
      $('disk').innerHTML = html;
    }).catch(function (e) { $('diskNote').textContent = e.message; });
  }
  function refreshLogs() {
    api('/api/logs?tail=300').then(function (d) {
      $('logs').textContent = d.logs || '（空）';
      $('logs').scrollTop = $('logs').scrollHeight;
    }).catch(function (e) { $('logs').textContent = '读取日志失败：' + e.message; });
  }

  function login() {
    err('');
    api('/api/login', { post: true, body: { password: $('pw').value } }).then(function () {
      $('pw').value = '';
      show(true);
      refreshStatus(); refreshDisk(); refreshLogs();
    }).catch(function (e) { err(e.message); });
  }

  $('loginBtn').addEventListener('click', login);
  $('pw').addEventListener('keydown', function (e) { if (e.key === 'Enter') { login(); } });
  $('btnRestart').addEventListener('click', function () { act('/api/restart', '重启'); });
  $('btnStop').addEventListener('click', function () {
    if (confirm('确定停止容器？面板会一并停止。')) { act('/api/stop', '停止'); }
  });
  $('btnStart').addEventListener('click', function () { act('/api/start', '启动'); });
  $('btnLogs').addEventListener('click', refreshLogs);
  $('btnDisk').addEventListener('click', refreshDisk);
  $('btnPrune').addEventListener('click', function () {
    if (!confirm('清理 dangling 镜像与构建缓存？不会动数据卷。')) { return; }
    api('/api/prune', { post: true }).then(function (r) {
      $('diskNote').textContent = '清理完成，回收 ' + bytes(r.reclaimed);
      refreshDisk();
    }).catch(function (e) { $('diskNote').textContent = '清理失败：' + e.message; });
  });
  $('btnLogout').addEventListener('click', function () {
    api('/api/logout', { post: true }).then(function () { show(false); });
  });

  refreshStatus();
})();
</script>
</body>
</html>
`
