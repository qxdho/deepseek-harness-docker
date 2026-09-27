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
 *      - 一个"重启 DSH"悬浮按钮，配合 /__dsh_restart 接口：装/更新插件后点一下就
 *        重启（鉴权复用 dsh-auth-gate，见下）。
 */
'use strict';

const http = require('node:http');
const httpProxy = require('http-proxy');

const DSH_HOST = process.env.DSH_HOST || '127.0.0.1';
const DSH_PORT = Number(process.env.DSH_PORT) || 3079;
const LISTEN_PORT = Number(process.env.PROXY_PORT) || 3080;
const TARGET = `http://${DSH_HOST}:${DSH_PORT}`;
const UPSTREAM_AUTHORITY = `${DSH_HOST}:${DSH_PORT}`;

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
}catch(e){}})();</script><script id="dsh-restart-button">(function(){try{
if(globalThis.__dshRestartButtonReady) return; globalThis.__dshRestartButtonReady=true;
function boot(){
  if(document.getElementById("dsh-restart-button-ui")) return;
  var b=document.createElement("button");
  b.id="dsh-restart-button-ui"; b.type="button";
  b.title="安装/更新插件后点这里重启，使其生效（等价于 ./dshm restart）";
  b.textContent="重启 DSH";
  b.style.cssText="position:fixed;right:16px;bottom:16px;z-index:2147483647;padding:8px 14px;border-radius:999px;border:1px solid rgba(255,255,255,.25);background:rgba(28,28,30,.86);color:#fff;font:13px/1.2 system-ui,-apple-system,sans-serif;cursor:pointer;box-shadow:0 2px 10px rgba(0,0,0,.35);opacity:.8";
  b.addEventListener("mouseenter",function(){b.style.opacity="1";});
  b.addEventListener("mouseleave",function(){b.style.opacity=".8";});
  b.addEventListener("click",function(){
    if(!confirm("重启 DSH？页面会短暂断开，约十几秒后自动恢复。")) return;
    b.disabled=true; b.textContent="正在重启…";
    fetch("/__dsh_restart",{method:"POST",headers:{"X-DSH-Restart":"1"},credentials:"same-origin",cache:"no-store"})
      .then(function(r){
        if(!r.ok) throw new Error("HTTP "+r.status);
        var n=0;
        var t=setInterval(function(){
          n++;
          fetch("/",{method:"GET",credentials:"same-origin",cache:"no-store"}).then(function(rr){
            if(rr.ok){clearInterval(t);location.reload();}
          }).catch(function(){});
          if(n>90){clearInterval(t);b.disabled=false;b.textContent="重启 DSH";}
        },1000);
      })
      .catch(function(e){b.disabled=false;b.textContent="重启 DSH";alert("重启请求失败："+e.message);});
  });
  (document.body||document.documentElement).appendChild(b);
}
if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",boot); else boot();
}catch(e){}})();</script>`;

function injectHead(html) {
  const lower = html.toLowerCase();
  const i = lower.indexOf('<head');
  if (i === -1) return INJECT + html;
  // `<head` 必须正好是 head 标签（后跟 `>` 或空白），否则 `<header>` /
  // `<headless-…>` 这类元素也会被当成插入点，把脚本注进文档正文。
  const next = lower[i + 5];
  if (next !== '>' && next !== undefined && !/\s/.test(next)) {
    return INJECT + html;
  }
  const e = html.indexOf('>', i);
  if (e === -1) return INJECT + html;
  return html.slice(0, e + 1) + INJECT + html.slice(e + 1);
}

const proxy = httpProxy.createProxyServer({
  target: TARGET,
  changeOrigin: true,
  ws: true,
  xfwd: true,
  selfHandleResponse: true,
});

// 客户端真实地址：TCP 连接的对端。Unix socket 等没有对端地址时为 undefined。
function peerAddress(req) {
  const addr = req && req.socket && req.socket.remoteAddress;
  return typeof addr === 'string' && addr.length > 0 ? addr : undefined;
}

// 统一改写 Host/Origin，并请求不压缩的响应，便于安全地注入 HTML。
//
// X-Forwarded-For 必须由代理**重算**，不能让客户端自带的值漏到上游：
// dsh-auth-gate 的限流键就取自这个头（rightmostUntrusted：从右往左第一个非受信地址），
// 而它信任的 peer 只有回环。http-proxy 的 `xfwd: true` 只是在客户端自带值后面**追加**
// 真实地址，所以最右侧仍是攻击者可控的伪造值 —— 每次换一个假 IP 就能绕过登录限流。
// 这里显式覆盖，只写真实 peer。
function setForwardHeaders(proxyReq, req) {
  proxyReq.setHeader('host', UPSTREAM_AUTHORITY);
  proxyReq.setHeader('origin', `http://${UPSTREAM_AUTHORITY}`);
  const peer = peerAddress(req);
  if (peer !== undefined) proxyReq.setHeader('x-forwarded-for', peer);
}

proxy.on('proxyReq', (proxyReq, req) => {
  setForwardHeaders(proxyReq, req);
  proxyReq.setHeader('accept-encoding', 'identity');
});
proxy.on('proxyReqWs', (proxyReq, req) => {
  setForwardHeaders(proxyReq, req);
});

proxy.on('proxyRes', (proxyRes, req, res) => {
  const type = String(proxyRes.headers['content-type'] || '');
  const isHtml = /text\/html/i.test(type);
  const noBody = req.method === 'HEAD' || proxyRes.statusCode === 204 || proxyRes.statusCode === 304;

  if (!isHtml || noBody) {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
    return;
  }

  const chunks = [];
  proxyRes.on('data', (c) => chunks.push(c));
  proxyRes.on('end', () => {
    const body = Buffer.from(injectHead(Buffer.concat(chunks).toString('utf8')), 'utf8');
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
});

proxy.on('error', (err, req, res) => {
  const message = `dsh proxy error: ${err.message}\n`;
  if (res && !res.headersSent && typeof res.writeHead === 'function') {
    res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(message);
  } else if (res && typeof res.end === 'function') {
    res.end();
  }
  console.error(`[proxy] ${message.trim()}`);
});

// ── 界面重启入口 ────────────────────────────────────────────────────────────
// 装/更新插件后需要重启 dsh 才会生效。与其让用户回命令行敲 ./dshm restart，
// 不如在注入的页面上放一个按钮，POST /__dsh_restart 即可。
//
// 鉴权不自己做，而是复用 dsh-auth-gate：把这个请求的 Cookie 原样拿去问 dsh 的 `/`，
// 已登录才会是 200（未登录是 302/401）。代理因此不需要理解会话 cookie。
const RESTART_PATH = '/__dsh_restart';
let restarting = false;

function isAuthenticated(req) {
  return new Promise((resolve) => {
    const probe = http.request(
      {
        host: DSH_HOST,
        port: DSH_PORT,
        path: '/',
        method: 'GET',
        headers: {
          host: UPSTREAM_AUTHORITY,
          cookie: req.headers.cookie || '',
          accept: 'text/html',
        },
      },
      (res) => {
        res.resume();
        resolve(res.statusCode === 200);
      },
    );
    probe.on('error', () => resolve(false));
    probe.end();
  });
}

function handleRestart(req, res) {
  if (req.method !== 'POST') {
    res.writeHead(405, { 'content-type': 'text/plain; charset=utf-8', allow: 'POST' });
    res.end('method not allowed\n');
    return;
  }
  // 自定义头是 CSRF 防线：跨站的表单/fetch 带不了它，浏览器会先发 CORS 预检，
  // 而我们不回任何 CORS 头，跨站请求就到此为止。
  if (req.headers['x-dsh-restart'] !== '1') {
    res.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('missing X-DSH-Restart header\n');
    return;
  }
  if (restarting) {
    res.writeHead(429, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('restart already requested\n');
    return;
  }
  isAuthenticated(req).then((authenticated) => {
    if (!authenticated) {
      res.writeHead(401, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('unauthorized\n');
      return;
    }
    restarting = true;
    res.writeHead(202, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
    res.end('{"ok":true}\n');
    console.log('[proxy] 收到界面重启请求，退出容器由 restart 策略重新拉起');
    // 留一点时间让 202 发出去，然后退出：entrypoint 监督到代理退出 → 容器退出 →
    // restart: unless-stopped 重新拉起，等于完整执行一次 ./dshm restart
    //（重跑 entrypoint：清缓存、补 peer 软链、重新加载插件）。
    setTimeout(() => process.exit(0), 400);
  });
}

const server = http.createServer((req, res) => {
  if (req.url && req.url.split('?')[0] === RESTART_PATH) {
    handleRestart(req, res);
    return;
  }
  proxy.web(req, res);
});
server.on('upgrade', (req, socket, head) => proxy.ws(req, socket, head));

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  console.log(`[proxy] 0.0.0.0:${LISTEN_PORT} -> ${TARGET}（Host/Origin 改写为 ${UPSTREAM_AUTHORITY}）`);
});
