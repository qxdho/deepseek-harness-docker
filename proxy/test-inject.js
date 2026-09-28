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

function get(port, p, extraHeaders) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port, path: p, headers: extraHeaders || {} }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
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

  // 9. 注入里不应再有「重启 DSH」按钮 / 重启接口（已移除，重启改走管理面板命令台）
  if (!normal.body.includes('/__dsh_restart') && !normal.body.includes('dsh-restart-button')) {
    ok('不再注入重启按钮与重启接口');
  } else {
    bad('页面里仍有重启入口');
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
