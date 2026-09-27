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

// 统一改写 Host/Origin，并请求不压缩的响应，便于安全地注入 HTML。
proxy.on('proxyReq', (proxyReq) => {
  proxyReq.setHeader('host', UPSTREAM_AUTHORITY);
  proxyReq.setHeader('origin', `http://${UPSTREAM_AUTHORITY}`);
  proxyReq.setHeader('accept-encoding', 'identity');
});
proxy.on('proxyReqWs', (proxyReq) => {
  proxyReq.setHeader('host', UPSTREAM_AUTHORITY);
  proxyReq.setHeader('origin', `http://${UPSTREAM_AUTHORITY}`);
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

const server = http.createServer((req, res) => proxy.web(req, res));
server.on('upgrade', (req, socket, head) => proxy.ws(req, socket, head));

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  console.log(`[proxy] 0.0.0.0:${LISTEN_PORT} -> ${TARGET}（Host/Origin 改写为 ${UPSTREAM_AUTHORITY}）`);
});
