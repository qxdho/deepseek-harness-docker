#!/usr/bin/env node
/**
 * dsh 对外代理（薄转发层）。
 *
 * 它只做三件事，**不做鉴权**（鉴权由 dsh 进程内的 dsh-auth-gate 插件完成）：
 *
 *   1. 监听 0.0.0.0:PROXY_PORT，转发到 dsh 的 127.0.0.1:DSH_PORT（HTTP + WebSocket）。
 *   2. 把 Host 和 Origin 一致地改写成回环 authority。
 *      - 为什么必须一致：dsh 的 /api 信任栅栏要求 Host 是回环或受信 authority，
 *        且 Origin（若有）必须等于 Host。
 *      - 为什么改写 Host 不会破坏会话 Cookie：dsh 的会话 Cookie 不带 Domain，
 *        浏览器按"它访问的网址"存放；Cookie 名由 dsh 按收到的 Host 计算，
 *        只要代理每次都用同一个 Host 转发，名字就对得上，Cookie 一直有效。
 *      - 好处：不需要为每个访问域名配置 --trusted-host。
 *   3. 往 HTML 的 <head> 注入一小段脚本：
 *      - crypto.randomUUID 补丁（局域网 IP 是浏览器非安全上下文，原 API 不存在，
 *        否则实时通道会一直 pending）；
 *      - globalThis.__DSH_TRANSPORT__.ownsHost = true（dsh 官方预留的注入口），
 *        让浏览器认为"页面是本机"，从而在域名/局域网访问下也能编辑设置页。
 */
'use strict';

const http = require('node:http');
const zlib = require('node:zlib');
const httpProxy = require('http-proxy');

const DSH_HOST = process.env.DSH_HOST || '127.0.0.1';
const DSH_PORT = Number(process.env.DSH_PORT) || 3079;
const LISTEN_PORT = Number(process.env.PROXY_PORT) || 3080;
const TARGET = `http://${DSH_HOST}:${DSH_PORT}`;
const UPSTREAM_AUTHORITY = `${DSH_HOST}:${DSH_PORT}`;

// 前面还有一层宿主反代时置 1：这样限流用的是真实客户端 IP，而不是反代的 IP。
// 默认关闭 —— 直连时 X-Forwarded-For 是客户端可伪造的，采信它就能绕过登录限流。
const TRUST_XFF = process.env.DSH_TRUST_XFF === '1';

// 注入前最多缓冲多少 HTML；超过就放弃注入、原样转发，避免把大响应全存内存。
const MAX_INJECT_BYTES = 4 * 1024 * 1024;

const INJECT = `<script id="dsh-forward-inject">(function(){try{
var c=globalThis.crypto;
if(c&&typeof c.randomUUID!=="function"){
  c.randomUUID=function(){
    var b=c.getRandomValues(new Uint8Array(16));
    b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;
    var h=[];for(var i=0;i<16;i++)h.push((b[i]+0x100).toString(16).slice(1));
    return h.slice(0,4).join("")+"-"+h.slice(4,6).join("")+"-"+h.slice(6,8).join("")+"-"+h.slice(8,10).join("")+"-"+h.slice(10,16).join("");
  };
}
globalThis.__DSH_TRANSPORT__=Object.assign({},globalThis.__DSH_TRANSPORT__||{},{ownsHost:true});
}catch(e){}})();</script>`;

// 找一个标签的结束位置，跳过属性引号里的 '>'（`<head data-x="a>b">`）。
function findTagEnd(html, start) {
  let quote = 0;
  for (let i = start; i < html.length; i += 1) {
    const ch = html[i];
    if (quote) {
      if (ch === quote) quote = 0;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === '>') return i;
  }
  return -1;
}

function injectHead(html) {
  const lower = html.toLowerCase();
  const i = lower.indexOf('<head');
  if (i !== -1) {
    // `<head` 必须正好是 head 标签（后跟 `>` 或空白），否则 `<header>` /
    // `<headless-…>` 这类元素也会被当成插入点，把脚本注进文档正文。
    const next = lower[i + 5];
    if (next === '>' || next === undefined || /\s/.test(next)) {
      const e = findTagEnd(html, i);
      if (e !== -1) return html.slice(0, e + 1) + INJECT + html.slice(e + 1);
    }
  }
  // 没有可用的 <head>：插在 doctype 之后。直接前置 `INJECT + html` 会把
  // `<!doctype html>` 挤到第二行，浏览器按 quirks 模式解析。
  const dt = lower.indexOf('<!doctype');
  if (dt !== -1) {
    const e = findTagEnd(html, dt);
    if (e !== -1) return html.slice(0, e + 1) + INJECT + html.slice(e + 1);
  }
  return INJECT + html;
}

// 客户端真实地址。默认只认 TCP 对端；设置了 DSH_TRUST_XFF=1 时取 XFF 最右一项
// （最靠近本代理、由可信反代写入的那个），与 dsh-auth-gate 的 rightmostUntrusted 一致。
function clientAddress(req) {
  const peer = peerAddress(req);
  if (TRUST_XFF) {
    const xff = req.headers['x-forwarded-for'];
    if (typeof xff === 'string' && xff.trim() !== '') {
      const parts = xff.split(',');
      const last = parts[parts.length - 1].trim();
      if (last !== '') return last;
    }
  }
  return peer;
}

// 客户端真实地址：TCP 连接的对端。Unix socket 等没有对端地址时为 undefined。
function peerAddress(req) {
  const addr = req && req.socket && req.socket.remoteAddress;
  return typeof addr === 'string' && addr.length > 0 ? addr : undefined;
}

// 统一改写 Host/Origin。客户端自带的 X-Forwarded-* 一律丢掉：
//   - X-Forwarded-For 由我们重算（dsh-auth-gate 的限流键取自它）；
//   - X-Forwarded-Host/-Port/-Proto 不往上带，避免客户端伪造成任意值。
//
// **为什么直接改 req.headers，而不是用 proxyReq 钩子**：
//   http-proxy 只在 `!proxyReq.getHeader('expect')` 时才 emit `proxyReq`
//   （见 node_modules/http-proxy/lib/http-proxy/passes/web-incoming.js:131-134），
//   而 setupOutgoing 是 `extend({}, req.headers)` —— 于是带 `Expect: 100-continue`
//   的请求会**完整跳过**头改写，客户端伪造的 Host/Origin/XFF 原样到达上游。
//   dsh-auth-gate 默认信任来自 127.0.0.1 的 X-Forwarded-For，所以这就等于把登录限流
//   的 IP 键交给客户端，可以随意换 IP 绕过限流。
//   在调用 proxy.web 之前改 req.headers 则与那条分支无关，一定生效。
const HOP_BY_HOP = [
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
];

function rewriteIncomingHeaders(req) {
  const h = req.headers;
  h.host = UPSTREAM_AUTHORITY;
  h.origin = `http://${UPSTREAM_AUTHORITY}`;
  // 注意：必须先算 clientAddress 再改写 XFF —— 它会读原值（TRUST_XFF 模式取最后一段）。
  // 而我们算出来的就是"可信链的最后一跳"。
  const client = clientAddress(req);
  if (client !== undefined) {
    h['x-forwarded-for'] = client;
  } else {
    delete h['x-forwarded-for'];
  }
  delete h['x-forwarded-host'];
  delete h['x-forwarded-port'];
  delete h['x-forwarded-proto'];
  // 其它常被用来冒充客户端 IP 的头一并删掉：`.env.example` 允许用
  // DSH_CLIENT_IP_HEADER 指定取值头，若那个头没被清理，改配置就等于把限流键交给客户端。
  for (const name of Object.keys(h)) {
    const lower = name.toLowerCase();
    if (
      lower === 'x-real-ip' ||
      lower === 'cf-connecting-ip' ||
      lower === 'x-client-ip' ||
      lower === 'true-client-ip' ||
      lower === 'forwarded' ||
      lower === 'x-forwarded'
    ) {
      delete h[name];
    }
  }
  // 删掉 Expect：否则 http-proxy 走的是"等上游 100"的分支，而我们已经把
  // Content-Length 之类都定好了；同时避免上游 100-continue 与我们的改写竞争。
  delete h.expect;
  for (const name of HOP_BY_HOP) delete h[name];
  // accept-encoding 固定为 identity：注入逻辑不做压缩，这样上游直接给明文
  h['accept-encoding'] = 'identity';
}

// 兼容旧调用点（proxyReq 钩子仍保留，覆盖没有 Expect 的常规请求；
// 两条路径写的是同一组头，幂等）。
function setForwardHeaders(proxyReq, req) {
  proxyReq.setHeader('host', UPSTREAM_AUTHORITY);
  proxyReq.setHeader('origin', `http://${UPSTREAM_AUTHORITY}`);
  const client = clientAddress(req);
  if (client !== undefined) {
    proxyReq.setHeader('x-forwarded-for', client);
  } else {
    proxyReq.removeHeader('x-forwarded-for');
  }
  proxyReq.removeHeader('x-forwarded-host');
  proxyReq.removeHeader('x-forwarded-port');
  proxyReq.removeHeader('x-forwarded-proto');
}

const keepAliveAgent = new http.Agent({ keepAlive: true, maxSockets: 64 });

// 上游响应超时（毫秒）。没有它的话：dsh 卡住或半死不活（接了 TCP 但不回包）时，
// 客户端会一直挂着 —— 浏览器的转圈永远不停，nginx 那边的 60s 也只能回 504，
// 而代理自己一直占着连接与 socket。给一个明确上限，超时就回 504。
const PROXY_TIMEOUT_MS = Number(process.env.DSH_PROXY_TIMEOUT_MS || 120000);

const proxy = httpProxy.createProxyServer({
  target: TARGET,
  ws: true,
  agent: keepAliveAgent,
  selfHandleResponse: true,
  proxyTimeout: PROXY_TIMEOUT_MS,
  timeout: PROXY_TIMEOUT_MS,
});

proxy.on('proxyReq', (proxyReq, req) => {
  setForwardHeaders(proxyReq, req);
  proxyReq.setHeader('accept-encoding', 'identity');
});
proxy.on('proxyReqWs', (proxyReq, req) => {
  setForwardHeaders(proxyReq, req);
});

function passthrough(proxyRes, res) {
  res.writeHead(proxyRes.statusCode, proxyRes.headers);
  proxyRes.pipe(res);
}

// 上游没理会 accept-encoding: identity 时，先解压再注入；解压失败就原样转发，
// 绝不能把压缩字节当字符串注入 —— 那样客户端拿到的是损坏的内容。
function decodeBody(buffer, encoding, cb) {
  const enc = String(encoding || '').toLowerCase();
  if (enc === '' || enc === 'identity') return cb(null, buffer);
  const done = (err, out) => cb(err, out);
  if (enc === 'gzip' || enc === 'x-gzip') return zlib.gunzip(buffer, done);
  if (enc === 'deflate') return zlib.inflate(buffer, done);
  if (enc === 'br') return zlib.brotliDecompress(buffer, done);
  return cb(new Error(`unsupported content-encoding: ${enc}`));
}

proxy.on('proxyRes', (proxyRes, req, res) => {
  const type = String(proxyRes.headers['content-type'] || '');
  const isHtml = /text\/html/i.test(type);
  // 206/带 Content-Range 的是分片响应，改写正文会让 Content-Range 对不上。
  const noBody = req.method === 'HEAD' ||
    proxyRes.statusCode === 204 || proxyRes.statusCode === 304 ||
    proxyRes.statusCode === 206 ||
    proxyRes.headers['content-range'] !== undefined;

  if (!isHtml || noBody) {
    passthrough(proxyRes, res);
    return;
  }

  let chunks = [];
  let size = 0;
  let finished = false;
  let streaming = false;

  const finish = (err) => {
    if (finished) return;
    finished = true;
    if (err) {
      // 上游中途断了：不能把半个页面当成功响应发出去
      if (!res.headersSent) {
        res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
      }
      res.end();
      return;
    }
    const raw = Buffer.concat(chunks, size);
    chunks = [];
    decodeBody(raw, proxyRes.headers['content-encoding'], (decErr, decoded) => {
      if (decErr) {
        // 解压不了就原样转发（含原来的 content-encoding），只失去注入
        res.writeHead(proxyRes.statusCode, proxyRes.headers);
        res.end(raw);
        return;
      }
      // **只在 charset 是 UTF-8（或没声明）时才注入**。
      //
      // 原来的写法是 `decoded.toString('utf8')` 再 `Buffer.from(..., 'utf8')` ——
      // 对 iso-8859-1 / gbk 这类页面，非 ASCII 字节会被替换成 U+FFFD 再编码回去，
      // 整页内容被改坏（实测 `é` 变成 EF BF BD），长度一变还会带偏 content-length。
      // 注入只是「加一段脚本」，不值得为它破坏正文 —— 认不出编码就原样转发。
      const ctype = String(proxyRes.headers['content-type'] || '');
      const csMatch = /charset\s*=\s*"?([A-Za-z0-9_-]+)"?/i.exec(ctype);
      const charset = csMatch ? csMatch[1].toLowerCase() : '';
      if (!(charset === '' || charset === 'utf-8' || charset === 'utf8')) {
        const asIs = Object.assign({}, proxyRes.headers);
        delete asIs['content-encoding'];
        delete asIs['transfer-encoding'];
        asIs['content-length'] = String(decoded.length);
        res.writeHead(proxyRes.statusCode, asIs);
        res.end(decoded);
        return;
      }
      const body = Buffer.from(injectHead(decoded.toString('utf8')), 'utf8');
      const headers = Object.assign({}, proxyRes.headers);
      // 重新计算长度后，必须同时删掉上游的 content-encoding 和 transfer-encoding，
      // 否则响应会同时带 Content-Length 与 Transfer-Encoding: chunked，
      // 严格的中间代理（Nginx 等）会直接判 502。
      delete headers['content-encoding'];
      delete headers['transfer-encoding'];
      headers['content-length'] = String(body.length);
      res.writeHead(proxyRes.statusCode, headers);
      res.end(body);
    });
  };

  proxyRes.on('data', (c) => {
    if (streaming) return;
    chunks.push(c);
    size += c.length;
    if (size > MAX_INJECT_BYTES) {
      // 太大，放弃注入，改成边收边转发
      streaming = true;
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      for (const b of chunks) res.write(b);
      chunks = [];
      size = 0;
      proxyRes.pipe(res);
    }
  });
  proxyRes.on('end', () => {
    if (!streaming) finish(null);
  });
  proxyRes.on('error', (err) => {
    console.error(`[proxy] upstream response error: ${err.message}`);
    finish(err);
  });
  proxyRes.on('aborted', () => finish(new Error('upstream aborted')));
  res.on('close', () => {
    if (!res.writableEnded) proxyRes.destroy();
  });
});

proxy.on('error', (err, req, res) => {
  const message = `dsh proxy error: ${err.message}\n`;
  console.error(`[proxy] ${message.trim()}`);
  if (res instanceof http.ServerResponse) {
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    }
    res.end(message);
  } else if (res && typeof res.destroy === 'function') {
    // WebSocket 失败时 res 是裸 socket
    res.destroy();
  }
});

const server = http.createServer((req, res) => {
  // 先改写头再交给 http-proxy —— 不能依赖 proxyReq 钩子（带 Expect 时它不触发）
  rewriteIncomingHeaders(req);
  proxy.web(req, res);
});
server.on('upgrade', (req, socket, head) => {
  rewriteIncomingHeaders(req);
  proxy.ws(req, socket, head);
});

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  console.log(`[proxy] 0.0.0.0:${LISTEN_PORT} -> ${TARGET}（Host/Origin 改写为 ${UPSTREAM_AUTHORITY}${TRUST_XFF ? '，信任 X-Forwarded-For' : ''}）`);
});
