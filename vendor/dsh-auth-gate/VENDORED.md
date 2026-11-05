# vendor/dsh-auth-gate —— 我们改过的登录门禁

这个目录是 **`dsh-auth-gate@0.18.0` 的构建产物**，不是本仓库的原创代码。

- 上游：<https://github.com/TecFancy/dsh-auth-gate>
- 版本：`0.18.0`（对应上游 tag `0.18.0`，release 提交 `4ea6920`）
- 许可证：MIT（见同目录 `LICENSE`）

## 为什么要 vendor

1. **上游还没有适配 dsh 0.2.2**：从 dsh `0.2.2-rc.1` 起，webserver 的路由除了
   `{ handler }` 还允许 `{ resource }`（一个把 Fetch `Request` 映射成 `Response` 的函数）。
   上游 0.18.0 的 `wrapServer` 只认 `route.handler`，遇到 resource 路由时拿到
   `undefined`，`isGuarded(undefined)` 抛：

   ```
   TypeError: Cannot read properties of undefined (reading 'Symbol(dsh-auth.guarded)')
   ```

   结果是插件在 apply 阶段被跳过 —— **登录门禁整体不生效，但 dsh 本体照常启动、
   容器还是 healthy**。这是最危险的一种失败：看起来一切正常，实际谁都能进。

2. **节奏**：上游发版慢，而 dsh 每几天一个 rc。把这一处适配留在本仓库，dsh 升级
   不必再等上游。

## 改了什么

全部改动都在 `lib/host/shared/guard/guard.js`，见 `../dsh-auth-gate.patch`：

| 改动 | 作用 |
|---|---|
| `isGuarded` 容忍非函数 | 不再因为 `undefined` 抛 TypeError 把整个插件搞挂 |
| 新增 `guardResource()` | 把 resource 路由转成守卫版 handler：先过门禁决策，允许后再交给 webserver 的 `serveResource` 输出 |
| `wrapServer` 认识两种形态 | `{handler}` 原样；`{resource}` 转换（并**删掉 `resource` 字段**，否则分发会绕过 handler）；认不出的形态一律 503（fail closed） |
| fallback 同样处理 | SPA 的 fallback 也可能是 `{resource}` |

要点：**拒绝的语义没有改**，仍然复用上游的 `guardHttp` / `denyHttp`（302 登录页、
401、跨站弹回、`no-store`、Referrer 脱敏）。补丁只多了"resource 路由怎么被守卫"。

拿不到 `server.serveResource` 时返回 503 而不是放行 —— 宁可打不开，也不要开了门。

## 验证

- `vendor/dsh-auth-gate/test/resource-guard.test.mjs`：20 条断言，覆盖"拒绝时 resource
  绝不被调用""允许时才 delegate""fallback 是 resource""后注册的 resource 路由"
  "认不出的形状 503""handler 路由行为不变""unwrap 恢复"。
  用上游原版跑这份测试会直接崩（就是线上那个 TypeError）。
- CI 冒烟（`scripts/smoke-test.sh`）在 amd64 和 arm64 上各跑一遍登录闭环。

## 怎么升级

```bash
./scripts/vendor-gate.sh 0.18.1     # 拉新版 + 重新应用补丁
./scripts/vendor-gate.sh --check    # 校验 vendor 与补丁一致（CI 也会跑）
```

补丁打不上就**停下来人工看**：说明上游动了同一段代码，可能已经自己修好了
（那就删掉补丁、改回从 npm 安装）。

升级后同步改：`Dockerfile` 的 `ARG DSH_AUTH_GATE_VERSION`、`docker-compose.yml`、
`.env.example`（构建时会断言 vendor 的版本等于这个 ARG）。

## 边界

- vendor 的是**构建产物**（`lib/*.js`），不是从上游源码重新编译 —— 本机没有可靠的
  构建环境（装 devDependencies 会 OOM）。补丁因此以 diff 形式固化，可审计、可重放。
- 上游一旦发布支持 `{resource}` 路由的版本：删掉 `../dsh-auth-gate.patch`、把
  `vendor-gate.sh` 的 apply 步骤去掉（或直接改回 `dsh plugin add dsh-auth-gate@<ver>`）。
- 我们只补了"认不认识 resource 路由"这一件事，没有改鉴权逻辑本身。
