#!/usr/bin/env node
/**
 * dsh 反向代理：把容器内回环监听的 dsh 暴露到局域网。
 *
 * 为什么需要它（而不是直接 `dsh web --host 0.0.0.0`）：
 *   1. dsh 官方明确拒绝 --host 0.0.0.0，只允许回环。
 *   2. dsh 前端用 crypto.randomUUID()，该 API 只在安全上下文
 *      (https / localhost) 可用。局域网 IP 访问时是非安全上下文，
 *      实时通道会一直 pending，所以必须注入 polyfill。
 *   3. dsh 的浏览器会话 cookie 与请求 authority(Host) 强绑定：
 *        cookie 名 = sha256(authority)，签名负载里也含 authority。
 *      因此代理【绝不能】改写 Host。一旦改写，Set-Cookie 带回的 cookie
 *      名与浏览器当前站点不符，会被浏览器直接丢弃，根路径永远 401，
 *      陷入 401 -> 换 token -> 303 -> 401 的无限重定向
 *      （这正是 smanx 的 changeOrigin:true 导致的 ERR_TOO_MANY_REDIRECTS）。
 *
 * 本实现与 smanx 的核心差异：全程保留原始 Host，包括内部换 token 的那次
 * 请求。这样 dsh 会用浏览器的 authority 签发 cookie，浏览器才会接受。
 */
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const crypto = require('node:crypto');
const httpProxy = require('http-proxy');

// ── 配置 ────────────────────────────────────────────────────────────────────
const DSH_HOST = process.env.DSH_HOST || '127.0.0.1';
const DSH_PORT = Number(process.env.DSH_PORT) || 3079;
const LISTEN_PORT = Number(process.env.PROXY_PORT) || 3080;
const TARGET = `http://${DSH_HOST}:${DSH_PORT}`;
const WEB_LOG = process.env.DSH_WEB_LOG || '/tmp/dsh-web.log';

const AUTH_USER = process.env.PROXY_USERNAME || '';
const AUTH_PASS = process.env.PROXY_PASSWORD || '';
const AUTH_ENABLED = Boolean(AUTH_USER && AUTH_PASS);
const AUTH_REALM = 'dsh';

/** 不参与 Basic Auth 的静态资源：浏览器抓 manifest 时不带凭据。 */
const PUBLIC_PATHS = new Set(['/manifest.webmanifest', '/favicon.svg', '/favicon.ico']);

// ── Basic Auth ──────────────────────────────────────────────────────────────
/** 恒定时间比较，避免通过响应时间逐字节猜密码。 */
function safeEqual(a, b) {
  const ba = Buffer.from(String(a), 'utf8');
  const bb = Buffer.from(String(b), 'utf8');
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

function checkAuth(req) {
  if (!AUTH_ENABLED) return true;
  const m = /^Basic\s+(.+)$/i.exec(req.headers.authorization || '');
  if (!m) return false;
  let decoded;
  try {
    decoded = Buffer.from(m[1], 'base64').toString('utf8');
  } catch {
    return false;
  }
  const i = decoded.indexOf(':');
  if (i === -1) return false;
  return safeEqual(decoded.slice(0, i), AUTH_USER) && safeEqual(decoded.slice(i + 1), AUTH_PASS);
}

function rejectHttp(res) {
  res.writeHead(401, {
    'WWW-Authenticate': `Basic realm="${AUTH_REALM}", charset="UTF-8"`,
    'Content-Type': 'text/plain; charset=utf-8',
  });
  res.end('401 Unauthorized\n');
}

function rejectUpgrade(socket) {
  socket.end(
    `HTTP/1.1 401 Unauthorized\r\n` +
      `WWW-Authenticate: Basic realm="${AUTH_REALM}", charset="UTF-8"\r\n` +
      `Connection: close\r\n\r\n`,
  );
}

// ── 前端 polyfill ───────────────────────────────────────────────────────────
const POLYFILL = `<script>(function(){
if(typeof crypto!=="undefined"&&!crypto.randomUUID){
  crypto.randomUUID=function(){
    var b=crypto.getRandomValues(new Uint8Array(16));
    b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;
    var h=[];for(var i=0;i<16;i++)h.push((b[i]+0x100).toString(16).slice(1));
    return h.slice(0,4).join("")+"-"+h.slice(4,6).join("")+"-"+h.slice(6,8).join("")
      +"-"+h.slice(8,10).join("")+"-"+h.slice(10,16).join("");
  };
}
})();</script>`;

function injectIntoHead(html) {
  const i = html.toLowerCase().indexOf('<head');
  if (i !== -1) {
    const e = html.indexOf('>', i);
    if (e !== -1) return html.slice(0, e + 1) + POLYFILL + html.slice(e + 1);
  }
  return POLYFILL + html;
}

// ── launch token 打捞与自动换会话 ───────────────────────────────────────────
// dsh 启动时会打印 http://127.0.0.1:3079/?token=xxxx。浏览器首次访问根路径
// 会拿到 401，必须带这个 token 访问一次，dsh 才会签发会话 cookie 并 303 到 /。
// 代理自动完成这一步，用户直接访问 / 即可。
const TOKEN_RE = /[?&]token=([A-Za-z0-9._~-]{16,})/;
let cachedToken = null;
let tokenScanned = false;

function scrapeToken() {
  if (cachedToken) return cachedToken;
  try {
    const text = fs.readFileSync(WEB_LOG, 'utf8');
    const m = TOKEN_RE.exec(text); // 取第一个即可
    if (m) {
      cachedToken = m[1];
      console.log(`[token] 已从日志捕获 launch token（长度 ${cachedToken.length}）`);
    }
  } catch {
    /* 文件还不存在 */
  }
  tokenScanned = true;
  return cachedToken;
}

/**
 * 用 node:http 直接请求上游，显式设置 Host。
 * 这是与 smanx 最关键的区别：换 token 的这次请求也必须带上浏览器的 Host，
 * 否则 dsh 会用 127.0.0.1:3079 作为 authority 签 cookie，浏览器会丢弃它。
 */
function requestUpstream(pathWithQuery, originalHost, cookieHeader) {
  return new Promise((resolve, reject) => {
    const headers = { host: originalHost, accept: 'text/html,application/xhtml+xml' };
    if (cookieHeader) headers.cookie = cookieHeader;
    const req = http.request(
      { host: DSH_HOST, port: DSH_PORT, path: pathWithQuery, method: 'GET', headers },
      (up) => {
        const chunks = [];
        up.on('data', (c) => chunks.push(c));
        up.on('end', () =>
          resolve({
            status: up.statusCode || 500,
            headers: up.headers,
            body: Buffer.concat(chunks),
          }),
        );
      },
    );
    req.on('error', reject);
    req.end();
  });
}

// ── 代理 ────────────────────────────────────────────────────────────────────
// selfHandleResponse: true —— 由我们自己写响应，否则 http-proxy 会先写一次
// 响应头，我们再写就会抛 ERR_HTTP_HEADERS_SENT。
const proxy = httpProxy.createProxyServer({
  target: TARGET,
  ws: true,
  changeOrigin: false, // 关键：保留浏览器原始 Host
  xfwd: true,
  selfHandleResponse: true,
});

proxy.on('error', (err, req, res) => {
  console.error(`[proxy] 上游 ${TARGET} 出错：${err.code || err.message}`);
  if (res && typeof res.writeHead === 'function') {
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('502 Bad Gateway: dsh 不可达或已退出\n');
    } else {
      res.end();
    }
  } else if (res && typeof res.destroy === 'function') {
    res.destroy();
  }
});

/** 原样透传上游响应（含 3xx 的 location/set-cookie，SSE 等）。 */
function passthrough(proxyRes, res) {
  const headers = { ...proxyRes.headers };
  res.writeHead(proxyRes.statusCode || 200, headers);
  proxyRes.pipe(res);
}

proxy.on('proxyRes', (proxyRes, req, res) => {
  const ct = String(proxyRes.headers['content-type'] || '');
  if (!ct.includes('text/html')) {
    passthrough(proxyRes, res);
    return;
  }
  const chunks = [];
  proxyRes.on('data', (c) => chunks.push(c));
  proxyRes.on('end', () => {
    const body = injectIntoHead(Buffer.concat(chunks).toString('utf8'));
    const headers = { ...proxyRes.headers };
    delete headers['content-length'];
    delete headers['content-encoding'];
    delete headers['transfer-encoding'];
    res.writeHead(proxyRes.statusCode || 200, headers);
    res.end(body);
  });
});

/** 根路径 401 时自动用 launch token 换会话 cookie，并透传 303 + Set-Cookie。 */
async function handleIndexWithToken(req, res) {
  const host = req.headers.host || `${DSH_HOST}:${DSH_PORT}`;
  const token = scrapeToken();
  if (!token) return false;

  const sep = (req.url || '/').includes('?') ? '&' : '?';
  const authPath = `${req.url || '/'}${sep}token=${encodeURIComponent(token)}`;
  // 换会话必须剥离浏览器旧 cookie，否则上游可能因无效 cookie 直接 401
  const up = await requestUpstream(authPath, host, null);

  const headers = { ...up.headers };
  if (up.headers['set-cookie']) headers['set-cookie'] = up.headers['set-cookie'];
  console.log(
    `[token] 根路径 401 → 携带 token 重发（Host: ${host}）→ 上游 ${up.status}` +
      (up.headers['set-cookie'] ? `，下发 cookie` : ''),
  );
  res.writeHead(up.status, headers);
  res.end(up.body);
  return true;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url || '/', 'http://proxy.invalid');

  if (!PUBLIC_PATHS.has(url.pathname) && !checkAuth(req)) {
    rejectHttp(res);
    return;
  }

  // 根路径无 cookie 时，先尝试自动换会话
  if (req.method === 'GET' && url.pathname === '/' && !req.headers.cookie) {
    handleIndexWithToken(req, res).catch((err) => {
      console.error('[token] 自动换会话失败，回退普通代理：', err.message);
      proxy.web(req, res);
    });
    return;
  }

  proxy.web(req, res);
});

server.on('upgrade', (req, socket, head) => {
  if (!checkAuth(req)) {
    rejectUpgrade(socket);
    return;
  }
  proxy.ws(req, socket, head);
});

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  console.log(
    `[proxy] 监听 0.0.0.0:${LISTEN_PORT} -> ${TARGET}` +
      (AUTH_ENABLED ? '（Basic Auth 已启用）' : '（未启用认证！）'),
  );
  console.log('[proxy] 保留原始 Host，保证会话 cookie 的 authority 一致');
});
