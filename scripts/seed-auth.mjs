#!/usr/bin/env node
/**
 * 在 dsh 启动前预置 dsh-web-startup-auth 的管理员账号。
 *
 * 为什么要预置：插件默认允许“第一个访问的人注册管理员”。如果容器直接对
 * 外监听 0.0.0.0，谁先打开页面谁就能成为管理员。这里在服务启动前把
 * $DSH_HOME/web-auth.json 写好，彻底消除这个窗口。
 *
 * 只在文件不存在时创建；已存在就跳过（改密码请用 dsh auth-reset）。
 */
import { existsSync } from "node:fs";

const DSH_HOME = process.env.DSH_HOME || "/dsh";
const username = (process.env.DSH_AUTH_USER || "admin").replace(/[\u0000-\u001F\u007F]/g, "").trim();
const password = process.env.DSH_AUTH_PASSWORD || "";

if (existsSync(`${DSH_HOME}/web-auth.json`)) {
	console.log("[entrypoint] 已存在 web-auth.json，跳过管理员预置");
	process.exit(0);
}
if (!username) {
	console.error("[entrypoint] DSH_AUTH_USER 不能为空");
	process.exit(1);
}
if ([...password].length < 14) {
	console.error("[entrypoint] 首次启动必须设置 DSH_AUTH_PASSWORD（至少 14 位）");
	process.exit(1);
}

const store = `${DSH_HOME}/profiles/web/node_modules/dsh-web-startup-auth/lib/credential-store.js`;
const { registerCredentials } = await import(store);
registerCredentials(username, password);
console.log(`[entrypoint] 已预置管理员 '${username}' -> ${DSH_HOME}/web-auth.json`);
