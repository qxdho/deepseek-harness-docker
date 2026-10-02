#!/usr/bin/env node
/**
 * proxy/index.js 的离线单元测试。
 *
 *   node proxy/test-inject.js      （需要先 npm install）
 *
 * 重点回归：HTML 注入的插入点判定。
 * 修复前用 `html.indexOf('<head')` 找插入点，于是 `<header>`、`<headless-…>`
 * 这类元素也会被当成 `<head>`，脚本被注进文档正文 —— 补丁没进 <head> 就等于没生效，
 * 而且是静默失败。
 */
'use strict';

const http = require('node:http');
const zlib = require('node:zlib');
const { spawn } = require('node:child_process');
const path = require('node:path');

const UPSTREAM_PORT = 13079;
const PROXY_PORT = 13080;

let PASS = 0;
let FAIL = 0;
const ok = (m) => { console.log(`  \x1b[32mPASS\x1b[0m ${m}`); PASS += 1; };
const bad = (m) => { console.log(`  \x1b[31mFAIL\x1b[0m ${m}`); FAIL += 1; };

// 假上游：按路径返回不同的 HTML
const upstream = http.createServer((req, res) => {
  const body = {
    '/normal': '<!doctype html><html><head><title>t</title></head><body>hi</body></html>',
    '/header-first': '<!doctype html><html><header><h1>t</h1></header><body>hi</body></html>',
    '/headless': '<html><headless-thing data-x="1"></headless-thing><body>hi</body></html>',
    '/no-head': '<html><body>hi</body></html>',
    '/plain': 'just text',
    // 既有真 <head> 又有 <header>：必须注进 <head>，而不是被 <header> 抢先
    '/both': '<!doctype html><html><head><meta charset="utf-8"></head><body><header>h</header></body></html>',
  }[req.url.split('?')[0]];
  if (req.url.startsWith('/echo-xff')) {
    // 回显代理实际转发的 X-Forwarded-For，用于验证客户端伪造的头不会抵达上游。
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ xff: req.headers['x-forwarded-for'] ?? null }));
    return;
  }
  if (req.url.startsWith('/latin1')) {
    // 非 UTF-8 页面：iso-8859-1 里的 "é" 是单字节 0xE9。
    // 代理若按 UTF-8 解码再编码，会变成 EF BF BD（U+FFFD）—— 整页内容被改坏。
    const buf = Buffer.from('<html><head><title>caf\xe9</title></head><body>caf\xe9</body></html>', 'latin1');
    res.writeHead(200, {
      'content-type': 'text/html; charset=iso-8859-1',
      'content-length': String(buf.length),
    });
    res.end(buf);
    return;
  }
  if (req.url.startsWith('/gzip')) {
    // 上游无视 accept-encoding: identity，坚持返回 gzip 的 HTML
    const html = '<!doctype html><html><head><title>t</title></head><body>gz</body></html>';
    const buf = zlib.gzipSync(html);
    res.writeHead(200, {
      'content-type': 'text/html; charset=utf-8',
      'content-encoding': 'gzip',
      'content-length': String(buf.length),
    });
    res.end(buf);
    return;
  }
  if (req.url.startsWith('/partial')) {
    res.writeHead(206, {
      'content-type': 'text/html; charset=utf-8',
      'content-range': 'bytes 0-9/100',
    });
    res.end('<!doctype html><html><head></head><body>part</body></html>');
    return;
  }
  if (req.url.startsWith('/plain')) {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('plain body');
    return;
  }
  if (body === undefined) {
    res.writeHead(404, { 'content-type': 'text/html' });
    res.end('<html><body>not found</body></html>');
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(body);
});

// WebSocket 升级：记录上游是否收到**真正的**升级请求。
// 关键点：Node 的 http.request 只在 `connection` 含 `upgrade`（或 `upgrade` 头存在）
// 时才发升级请求；代理若把这两个头当 hop-by-hop 删掉，上游收到的是普通 GET、
// 升级被降级 —— 实时通道直接不可用，而普通 HTTP 用例全都照样通过（所以必须有这条）。
let sawUpgrade = 0;
let upgradeHeaders = null;
upstream.on('upgrade', (req, socket) => {
  sawUpgrade += 1;
  upgradeHeaders = { upgrade: req.headers.upgrade, connection: req.headers.connection };
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n'
  );
  socket.destroy();
});

function get(port, p, extraHeaders) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port, path: p, headers: extraHeaders || {} }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks);
        // raw 保留原始字节：非 UTF-8 的页面只有按字节比对才能发现编码被破坏
        resolve({ status: res.statusCode, headers: res.headers, body: raw.toString('utf8'), raw });
      });
    });
    req.on('error', reject);
  });
}


// 用裸 socket 发一个 WebSocket 升级请求，返回 { status, headers, raw }。
// 不走 http.get —— 它不会发升级请求。
function rawUpgrade(port, p) {
  return new Promise((resolve) => {
    const net = require('node:net');
    const sock = net.connect(port, '127.0.0.1');
    let buf = '';
    let settled = false;
    const done = (r) => {
      if (settled) return;
      settled = true;
      try {
        sock.destroy();
      } catch {}
      resolve(r);
    };
    sock.setTimeout(4000, () => done({ status: 0, raw: buf }));
    sock.on('connect', () => {
      sock.write(
        `GET ${p} HTTP/1.1\r\n` +
          `Host: 127.0.0.1:${port}\r\n` +
          'Upgrade: websocket\r\n' +
          'Connection: Upgrade\r\n' +
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n' +
          'Sec-WebSocket-Version: 13\r\n' +
          '\r\n'
      );
    });
    sock.on('data', (c) => {
      buf += c.toString('latin1');
      const m = /^HTTP\/1\.1 (\d{3})/.exec(buf);
      if (m) done({ status: Number(m[1]), raw: buf });
    });
    sock.on('error', () => done({ status: 0, raw: buf }));
    sock.on('close', () => done({ status: 0, raw: buf }));
  });
}
const INJECT_ID = 'dsh-forward-inject';

(async () => {
  await new Promise((r) => upstream.listen(UPSTREAM_PORT, '127.0.0.1', r));

  const proxy = spawn(process.execPath, [path.join(__dirname, 'index.js')], {
    env: Object.assign({}, process.env, {
      DSH_HOST: '127.0.0.1',
      DSH_PORT: String(UPSTREAM_PORT),
      PROXY_PORT: String(PROXY_PORT),
    }),
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  // 等代理起来
  for (let i = 0; i < 50; i += 1) {
    try {
      await get(PROXY_PORT, '/normal');
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }

  // 1. 正常 <head> 必须注入，且插在 <head> 之后、<title> 之前
  const normal = await get(PROXY_PORT, '/normal');
  if (normal.body.includes(INJECT_ID)) ok('普通页面注入了脚本');
  else bad('普通页面没有注入脚本');
  const headAt = normal.body.indexOf('<head>');
  const injectAt = normal.body.indexOf(INJECT_ID);
  const titleAt = normal.body.indexOf('<title>');
  if (headAt >= 0 && injectAt > headAt && injectAt < titleAt) ok('注入点在 <head> 与 <title> 之间');
  else bad(`注入点位置不对（head=${headAt} inject=${injectAt} title=${titleAt}）`);

  // 2. <header> 不能被误认为 <head>（本次修复的核心）
  const headerFirst = await get(PROXY_PORT, '/header-first');
  if (headerFirst.body.includes(INJECT_ID)) ok('<header> 页面仍注入（回退到文档开头）');
  else bad('<header> 页面没有注入');
  if (headerFirst.body.indexOf(INJECT_ID) < headerFirst.body.indexOf('<header>')) {
    ok('脚本落在 <header> 之前，而不是钻进正文里');
  } else {
    bad('脚本被错误地插到了 <header> 内部/之后');
  }

  // 3. <headless-thing> 不是 <head>：应回退到文档开头，而不是插进该元素里
  const headless = await get(PROXY_PORT, '/headless');
  const hlInject = headless.body.indexOf(INJECT_ID);
  const hlTag = headless.body.indexOf('<headless-thing');
  const hlClose = headless.body.indexOf('>', hlTag);
  if (hlInject >= 0 && hlInject < hlTag) {
    ok('<headless-…> 不再被当作 <head>，回退到文档开头');
  } else {
    bad(`脚本被误插进 <headless-…>（inject=${hlInject} tag=${hlTag} close=${hlClose}）`);
  }

  // 4. <head> 与 <header> 同时存在时，必须注进真正的 <head>
  const both = await get(PROXY_PORT, '/both');
  const bHead = both.body.indexOf('<head>');
  const bInject = both.body.indexOf(INJECT_ID);
  const bHeader = both.body.indexOf('<header>');
  const bHeadClose = both.body.indexOf('</head>');
  if (bInject > bHead && bInject < bHeadClose) ok('有真 <head> 时注入点选它，未被 <header> 干扰');
  else bad(`注入点不在 <head> 内（head=${bHead} inject=${bInject} </head>=${bHeadClose} <header>=${bHeader}）`);

  // 5. 没有 <head> 时回退到文档开头
  const noHead = await get(PROXY_PORT, '/no-head');
  if (noHead.body.indexOf(INJECT_ID) < noHead.body.indexOf('<body>')) {
    ok('无 <head> 时回退到文档开头');
  } else {
    bad('无 <head> 时回退位置不对');
  }

  // 6. 非 HTML 不能被注入或改动
  const plain = await get(PROXY_PORT, '/plain');
  if (plain.body === 'plain body' && !plain.body.includes(INJECT_ID)) ok('非 HTML 响应不被改动');
  else bad('非 HTML 响应被改动了');

  // 7. 注入后不能同时带 content-length 与 transfer-encoding（Nginx 会 502）
  const cl = normal.headers['content-length'];
  const te = normal.headers['transfer-encoding'];
  if (cl !== undefined && te === undefined) ok('只带 content-length，没有 transfer-encoding');
  else bad(`响应头不合法（content-length=${cl} transfer-encoding=${te}）`);
  if (Number(cl) === Buffer.byteLength(normal.body, 'utf8')) ok('content-length 与实际长度一致');
  else bad(`content-length 不一致（${cl} != ${Buffer.byteLength(normal.body, 'utf8')}）`);

  // 8. XFF 伪造防护：dsh-auth-gate 按「从右往左第一个非受信地址」定限流桶，
  //    而它信任 peer=127.0.0.1（trustedProxyCidrs 只含回环）。代理若把客户端
  //    自带的 X-Forwarded-For 原样转发，上游最右侧就是攻击者可伪造的值 →
  //    每次换一个假 IP 就能绕过登录限流。代理必须自己重算该头。
  const spoof = await get(PROXY_PORT, '/echo-xff', { 'x-forwarded-for': '9.9.9.9' });
  let spoofed = null;
  try {
    spoofed = JSON.parse(spoof.body).xff;
  } catch {
    spoofed = null;
  }
  if (spoofed === null) {
    bad('上游没有收到 X-Forwarded-For，无法判断客户端 IP');
  } else if (spoofed.includes('9.9.9.9')) {
    bad(`客户端伪造的 X-Forwarded-For 被转发到上游：${spoofed}（限流可被绕过）`);
  } else if (/127\.0\.0\.1|::1|::ffff:127\.0\.0\.1/.test(spoofed)) {
    ok(`XFF 被代理重算为真实 peer（${spoofed}）`);
  } else {
    bad(`XFF 既不是真实 peer 也不含伪造值，语义不明：${spoofed}`);
  }

  // 同一条请求再确认：没有客户端 XFF 时，代理也应写入真实 peer
  const noSpoof = await get(PROXY_PORT, '/echo-xff');
  let plainXff = null;
  try {
    plainXff = JSON.parse(noSpoof.body).xff;
  } catch {
    plainXff = null;
  }
  if (plainXff && /127\.0\.0\.1|::1|::ffff:127\.0\.0\.1/.test(plainXff)) {
    ok(`未伪造时 XFF 也是真实 peer（${plainXff}）`);
  } else {
    bad(`未伪造时 XFF 不正常：${plainXff}`);
  }


  // 8b. `Expect: 100-continue` 不能绕过头改写
  //
  // 这里曾是真漏洞：http-proxy 只在 `!proxyReq.getHeader('expect')` 时才 emit
  // `proxyReq` 事件（web-incoming.js:131-134），而它是 `extend({}, req.headers)`
  // 把头带过去的。于是带 Expect 的请求**完整跳过**我们的 Host/Origin/XFF 改写，
  // 客户端伪造的 X-Forwarded-For 原样抵达上游 —— 而 dsh-auth-gate 默认信任来自
  // 127.0.0.1 的该头，等于把登录限流的 IP 键交给客户端，换个假 IP 就能绕过限流。
  //
  // 修法是直接改 req.headers（在 proxy.web 之前），与那条分支无关。
  const expSpoof = await get(PROXY_PORT, '/echo-xff', {
    'x-forwarded-for': '9.9.9.9',
    expect: '100-continue',
  });
  let expXff = null;
  try {
    expXff = JSON.parse(expSpoof.body).xff;
  } catch {
    expXff = null;
  }
  if (expXff === null) {
    bad('带 Expect 时上游没收到 XFF（无法判断客户端 IP）');
  } else if (expXff.includes('9.9.9.9')) {
    bad(`带 Expect 时伪造的 XFF 被转发到上游：${expXff}（限流可被绕过）`);
  } else if (/127\.0\.0\.1|::1|::ffff:127\.0\.0\.1/.test(expXff)) {
    ok(`带 Expect: 100-continue 时 XFF 仍被重算为真实 peer（${expXff}）`);
  } else {
    bad(`带 Expect 时 XFF 不可识别：${expXff}`);
  }

  // 17. 非 UTF-8 页面必须原样转发（不能按 UTF-8 解码再编码）
  //
  // 原来对**所有** HTML 都做 `decoded.toString('utf8')` → 注入 → `Buffer.from(…, 'utf8')`。
  // 对 iso-8859-1 / gbk 这类页面，非 ASCII 字节会被替换成 U+FFFD，整页内容被改坏。
  const latin = await get(PROXY_PORT, '/latin1');
  // "café" 在 iso-8859-1 里是 63 61 66 E9。必须比**原始字节**：
  // 若按 UTF-8 解码再编码，E9 会变成 EF BF BD（三字节），页面内容就坏了。
  const latinBuf = latin.raw;
  if (latinBuf.includes(Buffer.from([0xef, 0xbf, 0xbd]))) {
    bad('非 UTF-8 页面出现了 U+FFFD 替换字符（UTF-8 解码破坏了编码）');
  } else if (!latinBuf.includes(Buffer.from([0x63, 0x61, 0x66, 0xe9]))) {
    bad('非 UTF-8 页面的字节被改坏了：' + latinBuf.toString('hex'));
  } else {
    ok('非 UTF-8 页面按原字节转发（没有被 UTF-8 解码破坏）');
  }
  // 9. 注入里不应再有「重启 DSH」按钮 / 重启接口（已移除，重启改走管理面板命令台）
  if (!normal.body.includes('/__dsh_restart') && !normal.body.includes('dsh-restart-button')) {
    ok('不再注入重启按钮与重启接口');
  } else {
    bad('页面里仍有重启入口');
  }

  // 10. 没有 <head> 时，脚本要插在 doctype 之后（插在它前面会把页面推进 quirks 模式）
  const dtAt = headerFirst.body.toLowerCase().indexOf('<!doctype');
  if (dtAt >= 0 && headerFirst.body.indexOf(INJECT_ID) > dtAt) {
    ok('回退注入点在 doctype 之后');
  } else {
    bad(`回退注入点位置不对（doctype=${dtAt} inject=${headerFirst.body.indexOf(INJECT_ID)}）`);
  }

  // 11. 上游无视 identity 返回 gzip：必须先解压再注入，且不能留下 content-encoding
  const gz = await get(PROXY_PORT, '/gzip');
  if (gz.body.includes(INJECT_ID) && gz.body.includes('gz')) {
    ok('gzip HTML 被解压后注入');
  } else {
    bad('gzip HTML 处理错误（内容未还原或未注入）');
  }
  if (gz.headers['content-encoding'] === undefined) {
    ok('gzip 响应去掉了 content-encoding');
  } else {
    bad(`仍带 content-encoding：${gz.headers['content-encoding']}`);
  }

  // 12. 206 分片响应必须原样透传（改写正文会让 Content-Range 对不上）
  const partial = await get(PROXY_PORT, '/partial');
  if (!partial.body.includes(INJECT_ID) && partial.headers['content-range'] === 'bytes 0-9/100') {
    ok('206 分片响应原样透传');
  } else {
    bad(`206 被改写了（inject=${partial.body.includes(INJECT_ID)} range=${partial.headers['content-range']}）`);
  }

  // 13. DSH_TRUST_XFF=1：跑在宿主反代后面时，取 XFF 最右一项作为真实客户端
  const trusted = spawn(process.execPath, [path.join(__dirname, 'index.js')], {
    env: Object.assign({}, process.env, {
      DSH_HOST: '127.0.0.1',
      DSH_PORT: String(UPSTREAM_PORT),
      PROXY_PORT: String(PROXY_PORT + 1),
      DSH_TRUST_XFF: '1',
    }),
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  for (let i = 0; i < 50; i += 1) {
    try {
      await get(PROXY_PORT + 1, '/normal');
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  const trustedRes = await get(PROXY_PORT + 1, '/echo-xff', { 'x-forwarded-for': '9.9.9.9, 203.0.113.7' });
  let trustedXff = null;
  try {
    trustedXff = JSON.parse(trustedRes.body).xff;
  } catch {
    trustedXff = null;
  }
  if (trustedXff === '203.0.113.7') {
    ok('DSH_TRUST_XFF=1 时取最右一项作为真实客户端');
  } else {
    bad(`受信模式的 XFF 不对：${trustedXff}`);
  }
  trusted.kill('SIGTERM');


  // 18. WebSocket 升级必须真的被转发（实时通道 /api/remote.mux 依赖它）
  //
  // 这里曾有真回归：`rewriteIncomingHeaders` 把 `connection` 与 `upgrade` 当
  // hop-by-hop 头一起删了，而它同时被 `server.on('upgrade')` 调用 —— Node 的
  // http.request 只在 `connection` 含 `upgrade` 时才发真正的升级请求，于是上游收到
  // 普通 GET、升级被降级，实时通道彻底不可用。**普通 HTTP 用例全都照样通过**，
  // 所以这条用例是唯一能挡住它的东西。
  const wsResult = await rawUpgrade(PROXY_PORT, '/api/remote.mux');
  if (wsResult.status === 101) {
    ok('WebSocket 升级被转发（上游回了 101）');
  } else {
    bad(`WebSocket 升级没有被转发：客户端收到 ${wsResult.status || '（连接被关）'}`);
  }
  if (sawUpgrade > 0) {
    ok(`上游收到了真正的升级请求（升级头 upgrade=${upgradeHeaders && upgradeHeaders.upgrade}）`);
  } else {
    bad('上游从未收到升级请求（被降级成普通 GET）');
  }
  if (upgradeHeaders && /websocket/i.test(upgradeHeaders.upgrade || '')) {
    ok('转发时保留了 upgrade: websocket');
  } else {
    bad(`转发时丢了 upgrade 头：${JSON.stringify(upgradeHeaders)}`);
  }

  // 19. 升级探针端点：`dshm service doctor` 靠它区分「反代剥掉了升级头」与「链路正常、
  //     只是没登录」—— 后者拿 /api/remote.mux 是分不出来的（没 Cookie 必然 302）。
  //     普通 GET 回 426，升级请求回 101，且两者都不能打到上游。
  const sawUpgradeBefore = sawUpgrade;
  const probePlain = await get(PROXY_PORT, '/__dsh_probe_upgrade');
  if (probePlain.status === 426) {
    ok('探针收到普通 GET → 426（升级头没到）');
  } else {
    bad(`探针普通 GET 期望 426，实际 ${probePlain.status}`);
  }
  const probeUpgrade = await rawUpgrade(PROXY_PORT, '/__dsh_probe_upgrade');
  if (probeUpgrade.status === 101) {
    ok('探针收到升级请求 → 101（升级头到了本代理）');
  } else {
    bad(`探针升级期望 101，实际 ${probeUpgrade.status || '（连接被关）'}`);
  }
  if (sawUpgrade === sawUpgradeBefore) {
    ok('探针请求不转发给 dsh（上游计数未变）');
  } else {
    bad('探针请求被转发到了上游');
  }

  proxy.kill('SIGTERM');
  upstream.close();
  console.log(`\nPASS=${PASS} FAIL=${FAIL}`);
  process.exit(FAIL === 0 ? 0 : 1);
})().catch((err) => {
  console.error(err);
  proxyFatal(err);
});

function proxyFatal(err) {
  console.error('测试异常：', err && err.message);
  process.exit(1);
}
