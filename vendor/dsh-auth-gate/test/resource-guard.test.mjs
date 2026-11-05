// vendor/dsh-auth-gate 里那处补丁的守卫测试。
//
// 背景：dsh 0.2.2 起 webserver 允许路由用 `{ resource }`（Fetch Request -> Response）
// 而不是 `{ handler }`。上游 0.18.0 的 wrapServer 只认 handler，遇到 resource 路由
// 就拿到 undefined 并在 isGuarded 里抛 TypeError，整个插件 apply 失败 —— 门禁消失、
// 容器却 healthy。补丁把 resource 路由包成守卫版 handler。
//
// 这里用假 server / 假 gate 跑真实的 guard.js，断言四件事：
//   1. 拒绝时 resource 绝不被调用（不是"拒绝了但还是执行了"）；
//   2. 允许时才走 server.serveResource；
//   3. 认不出的路由形状一律拒绝（fail closed），不放行；
//   4. handler 路由的老行为不变（回归保护）。
import assert from "node:assert/strict";
import { wrapServer, isGuarded } from "../lib/host/shared/guard/guard.js";

let pass = 0;
let fail = 0;
const ok = (m) => { console.log(`  \x1b[32mPASS\x1b[0m ${m}`); pass += 1; };
const bad = (m) => { console.log(`  \x1b[31mFAIL\x1b[0m ${m}`); fail += 1; };
const check = (cond, m) => (cond ? ok(m) : bad(m));

// ── 极简 req / res 假件 ────────────────────────────────────────────────────
function fakeRes() {
	const res = {
		status: 0,
		headers: {},
		body: "",
		headersSent: false,
		setHeader(n, v) { this.headers[n.toLowerCase()] = v; },
		writeHead(s, h) { this.status = s; if (h) for (const [k, v] of Object.entries(h)) this.setHeader(k, v); this.headersSent = true; },
		end(b) { if (b !== undefined) this.body += String(b); this.headersSent = true; this.ended = true; },
		on() {}, off() {},
	};
	return res;
}
const fakeReq = (url = "/x", headers = {}) => ({ url, method: "GET", headers });

// ── 假 webserver（只实现 wrapServer 用到的表面）──────────────────────────────
function fakeServer(routes = {}, options = {}) {
	const server = {
		exact: new Map(Object.entries(routes.exact || {})),
		prefixes: new Map(Object.entries(routes.prefixes || {})),
		upgrades: new Map(Object.entries(routes.upgrades || {})),
		fallback: routes.fallback,
		served: [],
		register(route) { server.exact.set(route.path, route); return () => server.exact.delete(route.path); },
		registerUpgrade(route) { server.upgrades.set(route.path, route); return () => server.upgrades.delete(route.path); },
		registerFallback(f) { server.fallback = f; return () => { server.fallback = undefined; }; },
	};
	if (options.withServeResource !== false) {
		server.serveResource = async (req, res, target, resource) => {
			server.served.push({ url: String(target), resource });
			res.writeHead(200);
			res.end("served");
		};
	}
	return server;
}

const allowGate = () => () => ({ decide: () => "allow" });
const denyGate = (decision = "deny") => () => ({ decide: () => decision });

// ── 1. resource 路由：拒绝时不执行 ─────────────────────────────────────────
{
	const resource = async () => { throw new Error("resource 不该被调用"); };
	const server = fakeServer({ exact: { "/static": { kind: "exact", path: "/static", resource } } });
	wrapServer(server, denyGate(), console);
	const route = server.exact.get("/static");
	check(typeof route.handler === "function", "resource 路由被换成 handler");
	check(!("resource" in route), "resource 字段被移除（否则分发会绕过 handler）");
	check(isGuarded(route.handler), "新 handler 带守卫标记");

	const res = fakeRes();
	await route.handler(fakeReq("/static"), res);
	check(res.status === 401, `未登录访问 resource 路由 -> 401（实际 ${res.status}）`);
	check(server.served.length === 0, "拒绝时 server.serveResource 没被调用");
}

// ── 2. resource 路由：允许时交给 webserver 输出 ─────────────────────────────
{
	const resource = async () => new Response("hi");
	const server = fakeServer({ exact: { "/static": { kind: "exact", path: "/static", resource } } });
	wrapServer(server, allowGate(), console);
	const res = fakeRes();
	await server.exact.get("/static").handler(fakeReq("/static"), res);
	check(server.served.length === 1, "允许时调用了 server.serveResource");
	check(server.served[0]?.resource === resource, "传下去的是原来的 resource 函数");
	check(res.status === 200, `响应由 serveResource 写出（实际 ${res.status}）`);
}

// ── 3. 重定向决策（登录跳转）也要作用在 resource 路由上 ─────────────────────
{
	const server = fakeServer({ exact: { "/app": { kind: "exact", path: "/app", resource: async () => new Response("x") } } });
	wrapServer(server, denyGate({ deny: { redirect: "/auth/login" } }), console);
	const res = fakeRes();
	await server.exact.get("/app").handler(fakeReq("/app"), res);
	check(res.status === 302 && res.headers.location === "/auth/login", "resource 路由同样按决策 302");
	check(server.served.length === 0, "302 时没有执行 resource");
}

// ── 4. 认不出的路由形状：fail closed ───────────────────────────────────────
{
	const server = fakeServer({ exact: { "/weird": { kind: "exact", path: "/weird" } } });
	wrapServer(server, allowGate(), console);
	const res = fakeRes();
	await server.exact.get("/weird").handler(fakeReq("/weird"), res);
	check(res.status === 503, `形状不明的路由返回 503（实际 ${res.status}）`);
}

// ── 5. 没有 serveResource 的 server：也不放行 ──────────────────────────────
{
	const server = fakeServer(
		{ exact: { "/static": { kind: "exact", path: "/static", resource: async () => new Response("x") } } },
		{ withServeResource: false },
	);
	wrapServer(server, allowGate(), console);
	const res = fakeRes();
	await server.exact.get("/static").handler(fakeReq("/static"), res);
	check(res.status === 503, `server 没有 serveResource 时拒绝（实际 ${res.status}）`);
}

// ── 6. fallback 是 resource 时同样受守卫 ───────────────────────────────────
{
	const server = fakeServer({ fallback: { resource: async () => new Response("index") } });
	wrapServer(server, denyGate(), console);
	check(typeof server.fallback === "function", "resource fallback 被换成函数");
	const res = fakeRes();
	await server.fallback(fakeReq("/"), res);
	check(res.status === 401, `resource fallback 被拒（实际 ${res.status}）`);
	check(server.served.length === 0, "拒绝时 fallback 的 resource 没执行");
}

// ── 7. 包装之后新注册的 resource 路由也要被守卫（增量保险）──────────────────
{
	const server = fakeServer({});
	wrapServer(server, denyGate(), console);
	server.register({ kind: "exact", path: "/late", resource: async () => new Response("x") });
	const route = server.exact.get("/late");
	check(typeof route.handler === "function" && !("resource" in route), "后注册的 resource 路由也被转换");
	const res = fakeRes();
	await route.handler(fakeReq("/late"), res);
	check(res.status === 401 && server.served.length === 0, "后注册的 resource 路由同样被拒");
}

// ── 8. handler 路由的老行为不变 ────────────────────────────────────────────
{
	let hit = 0;
	const server = fakeServer({ exact: { "/api": { kind: "exact", path: "/api", handler: async (req, res) => { hit += 1; res.writeHead(200); res.end("ok"); } } } });
	const unwrapA = wrapServer(server, denyGate(), console);
	const res1 = fakeRes();
	await server.exact.get("/api").handler(fakeReq("/api"), res1);
	check(res1.status === 401 && hit === 0, "handler 路由：拒绝时不执行");

	// 同一 server 再 wrap 一次是幂等的（上游语义）
	const unwrapB = wrapServer(server, allowGate(), console);
	check(unwrapA === unwrapB, "重复 wrap 返回同一个 unwrap（幂等）");

	// unwrap 之后恢复原路由
	unwrapA();
	const restored = server.exact.get("/api");
	check(restored.handler !== undefined && !isGuarded(restored.handler), "unwrap 后恢复未守卫的原 handler");
}

console.log(`\nPASS=${pass} FAIL=${fail}`);
process.exit(fail === 0 ? 0 : 1);
