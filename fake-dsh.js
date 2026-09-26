#!/usr/bin/env node
/**
 * 模拟 dsh 的认证行为，用于验证代理。
 * 复刻官方 authorizeIndex 的核心语义：
 *   - cookie 名 = sha256(authority)，authority 来自 Host 头
 *   - /?token=xxx -> 303 Location: / + Set-Cookie
 *   - / 带正确 cookie -> 200 HTML
 *   - 否则 401
 */
const http = require('node:http');
const crypto = require('node:crypto');

const PORT = Number(process.env.FAKE_PORT) || 3181;
const TOKEN = 'qNA39sMcQL5JCmuzv6JunOJEDVqUwg9vAkaHctCvbQQ';

function cookieName(authority) {
  return 'dsh_' + crypto.createHash('sha256').update(authority).digest('base64url');
}

http
  .createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    const authority = req.headers.host;
    const name = cookieName(authority);
    const cookie = req.headers.cookie || '';

    // 带 token -> 签发 cookie 并 303 到 /
    if (url.searchParams.get('token')) {
      if (url.searchParams.get('token') !== TOKEN) {
        res.writeHead(401, { 'content-type': 'text/plain' });
        res.end('bad token');
        return;
      }
      res.writeHead(303, {
        'cache-control': 'no-store',
        location: '/',
        'set-cookie': `${name}=v1.signed; Max-Age=604800; Path=/; HttpOnly; SameSite=Strict`,
      });
      res.end();
      return;
    }

    // 带正确 cookie -> 200
    if (cookie.includes(`${name}=`)) {
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end('<html><head><title>dsh ok</title></head><body>AUTHENTICATED host=' + authority + '</body></html>');
      return;
    }

    // 否则 401
    res.writeHead(401, { 'content-type': 'text/plain' });
    res.end('401');
  })
  .listen(PORT, '127.0.0.1', () => {
    console.log('fake dsh on ' + PORT);
    // 打印带 token 的启动行，供代理打捞
    console.log('dsh web: http://127.0.0.1:' + PORT + '/?token=' + TOKEN);
  });
