#!/usr/bin/env node
/**
 * 长连接（SSE）回归测试。
 *
 *   node proxy/test-sse.js
 *
 * 背景：dsh 的客户端热更新通道 `/plugins/events` 是一条 **SSE 长连接**。
 * 它的行为是"连上后立刻推一帧，然后一直静默，直到插件图变化"——
 * 也就是说**空闲是它的正常状态**，不是故障。
 *
 * proxy/index.js 给 http-proxy 同时传了 `timeout` 与 `proxyTimeout`。
 * 后者在 http-proxy 里的实现是：
 *
 *     if(options.proxyTimeout) {
 *       proxyReq.setTimeout(options.proxyTimeout, function() {
 *          proxyReq.abort();          // ← 上游 socket 一空闲就掐断
 *       });
 *     }
 *
 * 这个超时是**按 socket 空闲**算的，不区分"请求还没回应"和"响应正在流式输出"。
 * 于是一个正常安静的 SSE 连接会在超时后被杀掉，浏览器侧表现为
 * `/plugins/events` 报 ERR_HTTP2_PROTOCOL_ERROR / ERR_CONNECTION_RESET，
 * 然后不断重连 —— 而**所有普通短请求的用例都照样通过**。
 *
 * 所以这个用例必须真的走"连上 → 静默 → 超过超时时间 → 还活着"这条路。
 */
'use strict';

const http = require('node:http');
const { spawn } = require('node:child_process');
const path = require('node:path');

const UPSTREAM_PORT = 13089;
const PROXY_PORT = 13090;
// 取一个很短的超时，让用例跑得快；被测的是"超时是否会误伤流式响应"，与具体数值无关。
const PROXY_TIMEOUT_MS = 700;

let PASS = 0;
let FAIL = 0;
const ok = (m) => { console.log(`  \x1b[32mPASS\x1b[0m ${m}`); PASS += 1; };
const bad = (m) => { console.log(`  \x1b[31mFAIL\x1b[0m ${m}`); FAIL += 1; };

// 假上游：/events 是 SSE，连上发一帧后静默（和 dsh 的 client-hmr 一模一样）。
let sseClosed = false;
const sseClients = new Set();
const hungSockets = [];
// 模拟"静默一段时间后上游主动推一帧"
function pushToClients(line) {
  for (const res of sseClients) {
    try { res.write(line); } catch { /* 客户端已断，忽略 */ }
  }
}
const upstream = http.createServer((req, res) => {
  if (req.url.split('?')[0] === '/events') {
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      connection: 'keep-alive',
    });
    res.write(': connected\n\n');
    res.write('data: {"type":"graph"}\n\n');
    sseClients.add(res);
    // 之后不再写任何东西 —— 静默是正常状态
    res.on('close', () => { sseClosed = true; sseClients.delete(res); });
    return;
  }
  // 半死不活的上游：TCP 收下了，但永远不回应。
  // 这正是 PROXY_TIMEOUT_MS 存在的理由，用来确认修复没有把这层保护一起关掉。
  if (req.url.split('?')[0] === '/hang') {
    hungSockets.push(res);
    return;
  }
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('ok');
});

// 连到代理的 /events，收集收到的事件；返回一个可控的句柄。
function openSSE(port, p) {
  const req = http.get({ host: '127.0.0.1', port, path: p }, (res) => {});
  const state = { status: 0, body: '', ended: false, error: null, headers: null };
  req.on('response', (res) => {
    state.status = res.statusCode;
    state.headers = res.headers;
    res.on('data', (c) => { state.body += c.toString('utf8'); });
    res.on('end', () => { state.ended = true; });
    res.on('error', (e) => { state.error = e; });
  });
  req.on('error', (e) => { state.error = e; state.ended = true; });
  state.destroy = () => req.destroy();
  return state;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  await new Promise((r) => upstream.listen(UPSTREAM_PORT, '127.0.0.1', r));

  const proxy = spawn(process.execPath, [path.join(__dirname, 'index.js')], {
    env: Object.assign({}, process.env, {
      DSH_HOST: '127.0.0.1',
      DSH_PORT: String(UPSTREAM_PORT),
      PROXY_PORT: String(PROXY_PORT),
      DSH_PROXY_TIMEOUT_MS: String(PROXY_TIMEOUT_MS),
    }),
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let proxyErr = '';
  proxy.stderr.on('data', (c) => { proxyErr += c.toString(); });

  // 等代理起来
  let up = false;
  for (let i = 0; i < 50 && !up; i += 1) {
    try {
      await new Promise((resolve, reject) => {
        const r = http.get({ host: '127.0.0.1', port: PROXY_PORT, path: '/ping' }, (res) => {
          res.resume();
          res.on('end', resolve);
        });
        r.on('error', reject);
      });
      up = true;
    } catch {
      await sleep(100);
    }
  }
  if (!up) {
    bad('代理没能启动');
    console.log(proxyErr);
    process.exit(1);
  }

  // 1. SSE 首帧必须透传（头部 + 已发出的数据）
  const sse = openSSE(PROXY_PORT, '/events');
  await sleep(150);
  if (sse.status === 200) ok('SSE 返回 200');
  else bad(`SSE 状态码不是 200（${sse.status}）`);
  if (/text\/event-stream/i.test(String(sse.headers && sse.headers['content-type']))) {
    ok('content-type 保持 text/event-stream');
  } else {
    bad(`content-type 被改写：${sse.headers && sse.headers['content-type']}`);
  }
  if (sse.body.includes('{"type":"graph"}')) ok('SSE 首帧透传到了客户端');
  else bad(`SSE 首帧没到客户端：${JSON.stringify(sse.body)}`);

  // 2. 核心：静默超过 proxyTimeout 之后，连接必须仍然活着。
  //    修复前 proxyReq.setTimeout 会 abort 上游请求，长连接被掐断。
  const wait = PROXY_TIMEOUT_MS * 3;
  await sleep(wait);
  if (!sse.ended && !sse.error) {
    ok(`静默 ${wait}ms（> 超时 ${PROXY_TIMEOUT_MS}ms）后 SSE 连接仍然存活`);
  } else {
    bad(`静默 ${wait}ms 后 SSE 连接被断开（超时 ${PROXY_TIMEOUT_MS}ms）：${sse.error ? sse.error.code || sse.error.message : '收到 end'}`);
  }
  if (!sseClosed) ok('上游 SSE 连接没有被代理 abort');
  else bad('上游 SSE 连接被代理 abort 了（proxyTimeout 误伤流式响应）');

  // 3. 静默期之后新推的数据仍要能到达（连接不只是"没断"，而是真的还能用）
  const beforePush = sse.body.length;
  pushToClients('data: {"type":"rebuilt"}\n\n');
  await sleep(300);
  if (sse.body.length > beforePush && sse.body.includes('"rebuilt"')) {
    ok('静默期后上游新推的数据仍能到达客户端');
  } else {
    bad('静默期后上游推的数据没到客户端（连接已是死连接）');
  }
  sse.destroy();

  // 4. 短请求不受影响：超时机制该拦的还得拦
  const shortOk = await new Promise((resolve) => {
    const r = http.get({ host: '127.0.0.1', port: PROXY_PORT, path: '/quick' }, (res) => {
      const cs = [];
      res.on('data', (c) => cs.push(c));
      res.on('end', () => resolve(res.statusCode === 200 && Buffer.concat(cs).toString() === 'ok'));
    });
    r.on('error', () => resolve(false));
  });
  if (shortOk) ok('普通短请求仍正常');
  else bad('普通短请求被影响');

  // 5. 反向断言：超时保护本身必须还在。
  //    上面为了让 SSE 活着，把流式响应的空闲计时器置了 0；如果顺手把超时整个删掉，
  //    这条就会红 —— 而"上游半死不活时不再超时"是个比原 bug 更隐蔽的退化。
  //
  //    诚实说明：这条断言只有**两个超时都删掉**时才红（那时 /hang 永远不返回，
  //    整个用例会挂住而不是打 FAIL）。只删 `proxyTimeout` 的话，客户端的
  //    `timeout` 仍然会掐断连接，这条照样 PASS —— 也就是说它证明的是
  //    "至少还有一层超时在"，不能用来分辨是哪一层。要分辨得靠上面第 4 条。
  const hangErr = await new Promise((resolve) => {
    const r = http.get({ host: '127.0.0.1', port: PROXY_PORT, path: '/hang' }, (res) => {
      res.resume();
      res.on('end', () => resolve(null));
    });
    r.on('error', (e) => resolve(e));
  });
  if (hangErr) {
    // 实测是 ECONNRESET：http-proxy 的 proxyTimeout 走 proxyReq.abort()，
    // socket 已被销毁，客户端拿不到状态码。文档里别再写"超时返回 504"。
    ok(`半死不活的上游仍会被超时掐断（客户端收到 ${hangErr.code || hangErr.message}）`);
  } else {
    bad('半死不活的上游没有被超时掐断 —— 超时保护被这次修复一起关掉了');
  }
  if (hungSockets.length > 0) hungSockets.forEach((s) => { try { s.destroy(); } catch {} });

  proxy.kill();
  upstream.close();
  await sleep(100);

  console.log(`\n${FAIL === 0 ? '\x1b[32m全部通过\x1b[0m' : '\x1b[31m有失败\x1b[0m'}  PASS=${PASS} FAIL=${FAIL}`);
  process.exit(FAIL === 0 ? 0 : 1);
})();
