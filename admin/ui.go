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
  .cmdbtn { font-size:12px; padding:4px 10px; }
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
    <div id="panelErr"></div>

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
        <strong>dsh 版本</strong>
        <button id="btnDshVer" style="margin-left:auto">查询版本</button>
      </div>
      <div class="row" style="margin-top:10px">
        <div class="kv"><div class="k">当前版本</div><div class="v" id="dshCurrent">-</div></div>
        <div class="kv"><div class="k">最新版本</div><div class="v" id="dshLatest">-</div></div>
      </div>
      <div class="row" style="margin-top:12px">
        <select id="dshVersionSelect" style="flex:1;min-width:220px" disabled>
          <option>（点「查询版本」加载）</option>
        </select>
        <button class="primary" id="btnDshUpdate" disabled>切换并重建</button>
        <button id="btnDshUpdateLatest" disabled>切到最新版</button>
      </div>
      <div class="muted" style="margin-top:8px;font-size:12px">
        版本列表来自 npm（dsh 的权威发布渠道），与 GitHub 仓库是否同步无关。
        <b>切换需要重建镜像</b>（dsh 在构建期装入），通常要几分钟；期间请勿关闭本页。
      </div>
      <div class="row" style="margin-top:10px;align-items:center">
        <span class="muted" style="font-size:12px">管理面板自身版本：<span id="panelVer">-</span></span>
        <button id="btnSelfUpdate" style="margin-left:auto">更新面板自身</button>
      </div>
      <div class="muted" style="font-size:12px">
        面板是宿主上的独立二进制，从 GitHub Releases 更新（与 dsh 的 npm 渠道无关）。
        更新后<b>需要重启面板</b>才生效。
      </div>
      <pre id="dshOut" style="margin-top:12px">（操作输出会显示在这里）</pre>
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

    <div class="card">
      <div class="row" style="align-items:center">
        <strong>命令台</strong>
        <span class="muted" style="font-size:12px">等于在服务器上运行 dshm（白名单，非自由 shell）</span>
      </div>
      <div id="cmdButtons" class="row" style="margin:10px 0"></div>
      <div class="row">
        <input id="cmdLine" placeholder="例如：service status / auth user list / service update 0.1.8" style="flex:1;min-width:220px">
        <button class="primary" id="btnRun">运行</button>
      </div>
      <pre id="cmdOut" style="margin-top:12px">（输出会显示在这里）</pre>
    </div>
  </div>
</div>

<script>
(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  function err(msg) {
    // 登录页和面板各有一个错误位，写到当前可见的那个（原来是两个同 id 的 div，
    // 登录后消息会写进已隐藏的那个，看起来像什么都没发生）。
    var loginErr = document.getElementById('err');
    var panelErr = document.getElementById('panelErr');
    if (loginErr) { loginErr.textContent = ''; }
    if (panelErr) { panelErr.textContent = ''; }
    var target = (panelErr && $('panel').style.display !== 'none') ? panelErr : loginErr;
    if (target) { target.textContent = msg || ''; }
  }
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
      if (!commandsLoaded) { loadCommands(); }
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
  // 启停类操作现在一律走 dshm（面板只是外壳），所以是分钟级：重启会重建容器并
  // 等健康。这里给出「进行中」的状态，并把 dshm 的输出显示出来 —— 否则用户面对
  // 一个卡住的按钮，不知道是在跑还是已经挂了。
  function act(path, label) {
    err('');
    $('logs').textContent = '（' + label + ' 进行中… 该操作由 dshm 执行，可能需要几分钟）';
    ['btnStart', 'btnStop', 'btnRestart'].forEach(function (id) { $(id).disabled = true; });
    api(path, { post: true }).then(function (r) {
      $('logs').textContent = '（' + label + ' 完成）\n\n' + (r.output || '（无输出）');
      $('logs').scrollTop = $('logs').scrollHeight;
      refreshStatus(); refreshDisk();
    }).catch(function (e) {
      // 失败时把 dshm 的输出一并显示：里面通常就是真正的原因（预检提示、日志尾部）
      err(label + ' 失败：' + e.message);
      $('logs').textContent = e.message;
    }).then(function () {
      ['btnStart', 'btnStop', 'btnRestart'].forEach(function (id) { $(id).disabled = false; });
    });
  }
  function refreshDisk() {
    api('/api/disk').then(function (d) {
      var rows = [
        ['镜像', d.images], ['容器可写层', d.containers],
        ['数据卷', d.volumes], ['构建缓存', d.buildCache], ['合计（近似，镜像层有共享）', d.total]
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

  var commandsLoaded = false;
  function loadCommands() {
    api('/api/commands').then(function (d) {
      commandsLoaded = true;
      if (!d.allowExec) { $('cmdOut').textContent = '命令台未开启（重新运行 dshm admin install 可开启）。'; return; }
      var html = '';
      (d.commands || []).forEach(function (c) {
        var line = 'dshm ' + c.path.join(' ');
        html += '<button class="cmdbtn" data-line="' + line + '" title="' + c.desc + '">' + c.path.join(' ') + '</button>';
      });
      $('cmdButtons').innerHTML = html;
      Array.prototype.forEach.call(document.querySelectorAll('.cmdbtn'), function (b) {
        b.addEventListener('click', function () { $('cmdLine').value = b.getAttribute('data-line'); runCmd(); });
      });
    }).catch(function (e) { $('cmdOut').textContent = e.message; });
  }
  function runCmd() {
    var line = $('cmdLine').value;
    if (!line) { return; }
    $('cmdOut').textContent = '运行中…';
    $('btnRun').disabled = true;
    api('/api/exec', { post: true, body: { line: line } }).then(function (r) {
      $('cmdOut').textContent = (r.exit === 0 ? '' : '[exit ' + r.exit + ']\n') + (r.output || '（无输出）');
      $('cmdOut').scrollTop = $('cmdOut').scrollHeight;
    }).catch(function (e) {
      $('cmdOut').textContent = '失败：' + e.message;
    }).then(function () { $('btnRun').disabled = false; });
  }

  // ── dsh 版本管理 ─────────────────────────────────────────────────────────
  // 版本列表来自后端直查 npm（权威渠道），不依赖 GitHub 仓库状态。
  var dshLoaded = false;
  function refreshDshVersions() {
    $('dshOut').textContent = '查询中…';
    $('btnDshVer').disabled = true;
    api('/api/dsh/versions').then(function (d) {
      dshLoaded = true;
      $('dshCurrent').textContent = d.current || '（未运行或无法探测）';
      $('dshLatest').textContent = d.latest || '-';
      $('panelVer').textContent = d.panel || 'dev';
      var sel = $('dshVersionSelect');
      sel.innerHTML = '';
      // 倒序：最新版排在最前面，省得在一长串里找
      (d.versions || []).slice().reverse().forEach(function (v) {
        var o = document.createElement('option');
        o.value = v;
        o.textContent = v + (v === d.latest ? '（最新）' : '') + (v === d.current ? '  ← 当前' : '');
        if (v === d.latest) { o.selected = true; }
        sel.appendChild(o);
      });
      sel.disabled = false;
      $('btnDshUpdate').disabled = false;
      $('btnDshUpdateLatest').disabled = (d.current === d.latest);
      var tags = Object.keys(d.distTags || {}).map(function (k) {
        return k + '=' + d.distTags[k];
      }).join('  ');
      $('dshOut').textContent = '共 ' + d.total + ' 个版本；发布标签：' + (tags || '（无）');
    }).catch(function (e) {
      $('dshOut').textContent = '查询失败：' + e.message;
    }).then(function () { $('btnDshVer').disabled = false; });
  }

  // 切换版本会重建镜像（实测数分钟），期间后端是串行执行的，所以这里要把按钮锁住，
  // 免得用户重复点。成功后刷新状态与日志，让用户看到新容器。
  function dshUpdate(version, label) {
    if (!confirm('将把 dsh 切换到 ' + (label || version) + ' 并重建镜像。\n' +
                 '这会重装 dsh 并现场编译原生依赖，通常需要几分钟，期间面板不可用。\n\n继续？')) {
      return;
    }
    $('dshOut').textContent = '正在切换到 ' + (label || version) + ' 并重建镜像…（几分钟，请勿关闭页面）';
    $('btnDshUpdate').disabled = true;
    $('btnDshUpdateLatest').disabled = true;
    $('btnDshVer').disabled = true;
    api('/api/dsh/update', { post: true, body: { version: version } }).then(function (r) {
      $('dshOut').textContent = (r.exit === 0 ? '✓ 完成\n\n' : '[exit ' + r.exit + ']\n\n') + (r.output || '（无输出）');
      $('dshOut').scrollTop = $('dshOut').scrollHeight;
      refreshStatus(); refreshLogs(); refreshDshVersions();
    }).catch(function (e) {
      $('dshOut').textContent = '失败：' + e.message;
      $('btnDshUpdate').disabled = false;
      $('btnDshUpdateLatest').disabled = false;
      $('btnDshVer').disabled = false;
    });
  }

  // 面板自身更新。面板是宿主机上的独立二进制，从 GitHub Releases 拉取。
  // 后端只做「下载 → 校验 sha256 → 原子替换」，不自动重启（重启方式依赖部署方式）。
  function selfUpdate() {
    if (!confirm('将从 GitHub Releases 下载最新面板二进制并替换当前文件。\n' +
                 '替换后需要重启面板才生效。\n\n继续？')) {
      return;
    }
    $('dshOut').textContent = '正在下载并校验…';
    $('btnSelfUpdate').disabled = true;
    api('/api/self/update', { post: true }).then(function (r) {
      $('dshOut').textContent = (r.ok ? '✓ ' : '') + (r.message || '完成') +
        (r.backup ? '\n\n旧二进制已备份到：' + r.backup : '');
    }).catch(function (e) {
      $('dshOut').textContent = '失败：' + e.message;
    }).then(function () { $('btnSelfUpdate').disabled = false; });
  }

  function login() {
    err('');
    api('/api/login', { post: true, body: { password: $('pw').value } }).then(function () {
      $('pw').value = '';
      show(true);
      refreshStatus(); refreshDisk(); refreshLogs(); refreshDshVersions();
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
  $('btnRun').addEventListener('click', runCmd);
  $('cmdLine').addEventListener('keydown', function (e) { if (e.key === 'Enter') { runCmd(); } });
  $('btnDisk').addEventListener('click', refreshDisk);
  $('btnDshVer').addEventListener('click', refreshDshVersions);
  $('btnDshUpdate').addEventListener('click', function () {
    dshUpdate($('dshVersionSelect').value, $('dshVersionSelect').value);
  });
  $('btnDshUpdateLatest').addEventListener('click', function () {
    // 传空版本 → 后端走 service update --latest（向 npm 查最新版）
    dshUpdate('', 'npm 上的最新版');
  });
  $('btnSelfUpdate').addEventListener('click', selfUpdate);
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
