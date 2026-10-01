// dsh-admin — DSH Docker 部署的宿主/容器管理面板。
//
// 设计约束（见 README「管理面板」）：
//   - 单文件静态二进制，仅标准库，宿主零运行时依赖；
//   - 只走 Docker Engine API 的固定几个接口，不做任意透传；
//   - 独立登录 + 会话 cookie(HttpOnly/SameSite=Strict) + 自定义头防 CSRF；
//   - 默认只监听 127.0.0.1。
//
// 用法：
//
//	dsh-admin -config /etc/dsh-admin/config.json      # 启动面板
//	dsh-admin -hash                                    # 从 stdin 读密码，输出哈希（给 dshm 用）
//	dsh-admin -gen-secret                              # 生成会话密钥
package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	pbkdf2Iter   = 120000
	sessionTTL   = 7 * 24 * time.Hour
	loginMaxFail = 10
	loginWindow  = 5 * time.Minute
)

type Config struct {
	Listen        string `json:"listen"`
	Container     string `json:"container"`
	Socket        string `json:"socket"`
	PasswordHash  string `json:"password_hash"`
	SessionSecret string `json:"session_secret"`
	AuditLog      string `json:"audit_log"`
	// 命令台用：dshm 所在的项目目录，以及 compose 项目名（容器模式下必须显式
	// 指定，否则 compose 会用挂载目录的 basename 当成新项目名，管到别的栈上）。
	ProjectDir     string `json:"project_dir"`
	ComposeProject string `json:"compose_project"`
	AllowExec      bool   `json:"allow_exec"`
}

func defaultConfig() Config {
	return Config{
		Listen:    "127.0.0.1:3090",
		Container: "qxdho-dsh",
		Socket:    "/var/run/docker.sock",
	}
}

// ── 口令哈希：纯标准库的 PBKDF2-HMAC-SHA256，避免引入 x/crypto 依赖 ──────────

func pbkdf2SHA256(password, salt []byte, iter, keyLen int) []byte {
	prf := hmac.New(sha256.New, password)
	hashLen := prf.Size()
	blocks := (keyLen + hashLen - 1) / hashLen
	var out []byte
	buf := make([]byte, 4)
	for block := 1; block <= blocks; block++ {
		prf.Reset()
		prf.Write(salt)
		buf[0] = byte(block >> 24)
		buf[1] = byte(block >> 16)
		buf[2] = byte(block >> 8)
		buf[3] = byte(block)
		prf.Write(buf)
		u := prf.Sum(nil)
		t := make([]byte, len(u))
		copy(t, u)
		for n := 2; n <= iter; n++ {
			prf.Reset()
			prf.Write(u)
			u = prf.Sum(u[:0])
			for i := range t {
				t[i] ^= u[i]
			}
		}
		out = append(out, t...)
	}
	return out[:keyLen]
}

func hashPassword(pw string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	dk := pbkdf2SHA256([]byte(pw), salt, pbkdf2Iter, 32)
	return fmt.Sprintf("pbkdf2-sha256$%d$%s$%s", pbkdf2Iter, hex.EncodeToString(salt), hex.EncodeToString(dk)), nil
}

func verifyPassword(pw, encoded string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 4 || parts[0] != "pbkdf2-sha256" {
		return false
	}
	iter, err := strconv.Atoi(parts[1])
	if err != nil || iter < 1000 || iter > 10_000_000 {
		return false
	}
	salt, err := hex.DecodeString(parts[2])
	if err != nil {
		return false
	}
	want, err := hex.DecodeString(parts[3])
	if err != nil {
		return false
	}
	// 必须挡住空盐/空摘要：hex.DecodeString("") 返回空切片且不报错，
	// 此时 pbkdf2(..., keyLen=0) 也返回空，ConstantTimeCompare 会判等 ——
	// 一个写坏的 password_hash 会变成"任意密码都能登录"。
	if len(salt) == 0 || len(want) < 16 {
		return false
	}
	got := pbkdf2SHA256([]byte(pw), salt, iter, len(want))
	return subtle.ConstantTimeCompare(got, want) == 1
}

// ── 会话：HMAC 签名，重启后仍有效；密钥在配置里 ──────────────────────────────

func signSession(secret string, exp int64) string {
	mac := hmac.New(sha256.New, []byte(secret))
	fmt.Fprintf(mac, "%d", exp)
	return fmt.Sprintf("%d.%s", exp, hex.EncodeToString(mac.Sum(nil)))
}

func verifySession(secret, v string) bool {
	parts := strings.SplitN(v, ".", 2)
	if len(parts) != 2 {
		return false
	}
	exp, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || time.Now().Unix() > exp {
		return false
	}
	want := signSession(secret, exp)
	return subtle.ConstantTimeCompare([]byte(v), []byte(want)) == 1
}

// ── 登录限流（按来源 IP）────────────────────────────────────────────────────

type limiter struct {
	mu    sync.Mutex
	fails map[string][]time.Time
}

func newLimiter() *limiter { return &limiter{fails: map[string][]time.Time{}} }

func (l *limiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	cutoff := time.Now().Add(-loginWindow)
	// 顺带清掉所有过期记录：旧实现只裁当前 IP，空闲 IP 会一直留在 map 里。
	for k, v := range l.fails {
		kept := v[:0]
		for _, t := range v {
			if t.After(cutoff) {
				kept = append(kept, t)
			}
		}
		if len(kept) == 0 {
			delete(l.fails, k)
		} else {
			l.fails[k] = kept
		}
	}
	return len(l.fails[ip]) < loginMaxFail
}

func (l *limiter) fail(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.fails[ip] = append(l.fails[ip], time.Now())
}

func (l *limiter) reset(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.fails, ip)
}

// ── 服务 ────────────────────────────────────────────────────────────────────

type server struct {
	cfg     Config
	docker  *Docker
	limiter *limiter
	execMu  sync.Mutex // 命令台串行化，同一时间只跑一条 dshm
}

func newServer(cfg Config) *server {
	return &server{cfg: cfg, docker: NewDocker(cfg.Socket), limiter: newLimiter()}
}

func (s *server) audit(format string, args ...any) {
	line := fmt.Sprintf("%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, args...))
	if s.cfg.AuditLog != "" {
		// **写失败必须报出来**，不能静默吞掉。
		//
		// 审计日志的价值在于"事后能查"；磁盘满、目录没了、权限不对时它会**静默消失**，
		// 而面板照常工作 —— 用户以为在审计，其实什么都没记。这是安全相关功能，
		// 不能像普通日志那样静默降级。
		if f, err := os.OpenFile(s.cfg.AuditLog, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err != nil {
			log.Printf("审计日志打开失败（本次未记录）：%v", err)
		} else {
			if _, werr := f.WriteString(line); werr != nil {
				log.Printf("审计日志写入失败（本次可能未记录）：%v", werr)
			}
			if cerr := f.Close(); cerr != nil {
				log.Printf("审计日志关闭失败（内容可能未落盘）：%v", cerr)
			}
		}
	}
	log.Print(strings.TrimSpace(line))
}

// clientIP 返回限流用的来源地址。
// 只有直连方是回环时（本机反代/SSH 隧道）才采信 X-Forwarded-For 的最右一项；
// 直连方不是回环时，该头是客户端可伪造的，一律忽略。
func (s *server) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if isLoopbackHost(host) {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if last := strings.TrimSpace(parts[len(parts)-1]); last != "" {
				return last
			}
		}
	}
	return host
}

func isLoopbackHost(host string) bool {
	if host == "::1" {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	return false
}

func (s *server) authenticated(r *http.Request) bool {
	c, err := r.Cookie("dsh_admin")
	if err != nil {
		return false
	}
	return verifySession(s.cfg.SessionSecret, c.Value)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path

	// 安全响应头：**所有**响应都带上（面板是给人用的 HTML + JSON API，两边都受益）。
	//
	// 之前一个都没有。面板监听在本机端口、通常还挂在反代后面，缺这些头意味着：
	//   * 别的站点可以把它 iframe 进去做点击劫持（X-Frame-Options / CSP frame-ancestors）
	//   * 响应被当成别的类型嗅探执行（X-Content-Type-Options）
	//   * 完整 URL（可能含 token）经 Referer 泄漏给外链（Referrer-Policy）
	//
	// ⚠ CSP 里的 script-src 用**内联脚本的 sha256**，不是 'unsafe-inline'。
	//   面板页面里有一个内联 <script>（页面的交互逻辑）；只写 `default-src 'self'`
	//   会把内联脚本一并拒掉 —— **面板会直接不能点**。而放开 'unsafe-inline' 等于
	//   把 CSP 的主要价值丢掉。所以这里在启动时算出那段脚本的哈希并写进 CSP：
	//   既允许了它，又保持"只准执行这一段脚本"。
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Security-Policy", contentSecurityPolicy)

	if path == "/" {

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		io.WriteString(w, indexHTML)
		return
	}
	if !strings.HasPrefix(path, "/api/") {
		http.NotFound(w, r)
		return
	}

	if path == "/api/login" {
		s.handleLogin(w, r)
		return
	}

	if !s.authenticated(r) {
		writeErr(w, http.StatusUnauthorized, "未登录")
		return
	}
	if r.Method == http.MethodPost && r.Header.Get("X-DSH-Admin") != "1" {
		writeErr(w, http.StatusForbidden, "缺少 X-DSH-Admin 头")
		return
	}

	switch path {
	case "/api/logout":
		s.handleLogout(w, r)
	case "/api/status":
		s.handleStatus(w, r)
	case "/api/start", "/api/stop", "/api/restart":
		s.handleAction(w, r, strings.TrimPrefix(path, "/api/"))
	case "/api/logs":
		s.handleLogs(w, r)
	case "/api/disk":
		s.handleDisk(w, r)
	case "/api/prune":
		s.handlePrune(w, r)
	case "/api/commands":
		s.handleCommands(w, r)
	case "/api/exec":
		s.handleExec(w, r)
	case "/api/dsh/versions":
		s.handleDshVersions(w, r)
	case "/api/dsh/update":
		s.handleDshUpdate(w, r)
	case "/api/self/update":
		s.handleSelfUpdate(w, r)
	default:
		writeErr(w, http.StatusNotFound, "未知接口")
	}
}

func (s *server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "只支持 POST")
		return
	}
	ip := s.clientIP(r)
	if !s.limiter.allow(ip) {
		writeErr(w, http.StatusTooManyRequests, "尝试过多，请稍后再试")
		return
	}
	var body struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "请求体不是 JSON")
		return
	}
	if !verifyPassword(body.Password, s.cfg.PasswordHash) {
		s.limiter.fail(ip)
		s.audit("登录失败 ip=%s", ip)
		writeErr(w, http.StatusUnauthorized, "密码错误")
		return
	}
	s.limiter.reset(ip)
	exp := time.Now().Add(sessionTTL).Unix()
	http.SetCookie(w, &http.Cookie{
		Name:     "dsh_admin",
		Value:    signSession(s.cfg.SessionSecret, exp),
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   s.secureRequest(r),
		MaxAge:   int(sessionTTL / time.Second),
	})
	s.audit("登录成功 ip=%s", ip)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// secureRequest：直连是 TLS，或（仅当直连方是回环时）上游反代声明了 https。
// 不信任非回环来源的 X-Forwarded-Proto，否则客户端能自己把 cookie 变成 Secure。
func (s *server) secureRequest(r *http.Request) bool {
	if r.TLS != nil {
		return true
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	return isLoopbackHost(host) && r.Header.Get("X-Forwarded-Proto") == "https"
}

func (s *server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "只支持 POST")
		return
	}
	http.SetCookie(w, &http.Cookie{Name: "dsh_admin", Value: "", Path: "/", MaxAge: -1, HttpOnly: true})
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *server) handleStatus(w http.ResponseWriter, r *http.Request) {
	st, err := s.docker.Status(s.cfg.Container)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// actionDshm 把面板的启停动作映射到等价的 dshm 子命令。
//
// 定位：**dshm 是唯一的操作入口，面板只是它的网页外壳**。面板不自己实现任何会改变
// 系统状态的逻辑。
//
// 这里曾经直接调 Docker API 的 start/stop/restart，那是错的 —— dshm 的 restart 用
// `compose up -d` 并跑启动前预检（改 .env 生效、属主/权限修复、等健康），而
// `docker restart` 只是重启进程：**改了 .env 之后在面板点「重启」看着成功、实际
// 毫无变化**。dshm 里甚至专门写了注释否掉这种做法。
func actionDshm(action string) ([]string, bool) {
	switch action {
	case "start":
		return []string{"service", "up"}, true
	case "stop":
		return []string{"service", "down"}, true
	case "restart":
		return []string{"service", "restart"}, true
	default:
		return nil, false
	}
}

func (s *server) handleAction(w http.ResponseWriter, r *http.Request, action string) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "只支持 POST")
		return
	}
	argv, ok := actionDshm(action)
	if !ok {
		writeErr(w, http.StatusBadRequest, "未知操作："+action)
		return
	}
	if _, err := s.dshmPath(); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}

	// 这些操作都可能是分钟级（重启会重建容器并等健康），超时给足。
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Minute)
	defer cancel()

	// 与命令台共用同一把锁：一个在跑 dshm 时另一个必须排队，
	// 否则并发的 compose 会互相打架。
	if !s.execMu.TryLock() {
		writeErr(w, http.StatusConflict, "已有 dshm 命令正在执行，请等它结束")
		return
	}
	defer s.execMu.Unlock()

	exit, text := s.runDshm(ctx, argv)
	s.audit("%s（dshm %s）exit=%d ip=%s", action, strings.Join(argv, " "), exit, s.clientIP(r))
	if exit != 0 {
		writeErr(w, http.StatusBadGateway,
			fmt.Sprintf("dshm %s 失败（exit %d）：\n%s", strings.Join(argv, " "), exit, text))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": text})
}

func (s *server) handleLogs(w http.ResponseWriter, r *http.Request) {
	tail, _ := strconv.Atoi(r.URL.Query().Get("tail"))
	out, err := s.docker.Logs(s.cfg.Container, tail)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"logs": out})
}

func (s *server) handleDisk(w http.ResponseWriter, r *http.Request) {
	u, err := s.docker.Disk()
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, u)
}

func (s *server) handlePrune(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "只支持 POST")
		return
	}
	// 与其它会改动 docker 状态的操作**同一把锁**。
	//
	// prune 走的虽然是 docker API（不经过 dshm），但它删的就是镜像与构建缓存 ——
	// 可能与 `dshm version update`（正在 pull/build）撞车：prune 把 update 正在用的
	// 层删掉，update 就会以一堆莫名其妙的错误失败。用 TryLock 而不是 Lock：
	// 忙的时候直接告诉用户"有别的操作在跑"，而不是让他排在一分钟以上的命令后面。
	if !s.execMu.TryLock() {
		writeErr(w, http.StatusConflict, "已有命令正在执行（如 dsh 更新），请等它结束再清理")
		return
	}
	defer s.execMu.Unlock()

	n, err := s.docker.Prune()
	if err != nil {
		s.audit("清理失败：%v", err)
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	s.audit("清理完成，回收 %d 字节 ip=%s", n, s.clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "reclaimed": n})
}

// ── 命令台 ──────────────────────────────────────────────────────────────────
// 不是自由 shell：拆成参数数组后直接 exec 项目里的 dshm（不经过 sh -c），
// 命令路径必须命中白名单。详见 commands.go。

func (s *server) handleCommands(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"allowExec": s.cfg.AllowExec,
		"commands":  commandCatalog,
	})
}

// dshmPath 返回项目目录里的 dshm 脚本绝对路径，并确认它确实是个可执行文件。
func (s *server) dshmPath() (string, error) {
	if s.cfg.ProjectDir == "" {
		return "", errors.New("面板未配置项目目录 project_dir")
	}
	p := filepath.Join(s.cfg.ProjectDir, "dshm")
	st, err := os.Stat(p)
	if err != nil || st.IsDir() {
		return "", fmt.Errorf("项目目录里找不到 dshm：%s", p)
	}
	return p, nil
}

// runDshm 执行一条 dshm 命令，返回退出码与合并输出。
//
// 调用方必须已经持有 s.execMu（或者确认不需要串行化）。把这段单独抽出来是因为
// 「跑 dshm」现在有两个入口：命令台，以及版本管理。两边都要同一套超时、环境变量
// 与输出截断策略，抄一份迟早会漂移。
func (s *server) runDshm(ctx context.Context, argv []string) (int, string) {
	dshm, err := s.dshmPath()
	if err != nil {
		return -1, err.Error()
	}
	cmd := exec.CommandContext(ctx, dshm, argv...)
	cmd.Dir = s.cfg.ProjectDir
	env := os.Environ()
	if s.cfg.ComposeProject != "" {
		env = append(env, "COMPOSE_PROJECT_NAME="+s.cfg.ComposeProject)
	}
	cmd.Env = env
	out := &capWriter{limit: 256 * 1024}
	cmd.Stdout = out
	cmd.Stderr = out
	runErr := cmd.Run()

	exit := 0
	text := out.String()
	if runErr != nil {
		var ee *exec.ExitError
		if errors.As(runErr, &ee) {
			exit = ee.ExitCode()
		} else {
			exit = -1
			text += "\n" + runErr.Error()
		}
	}
	return exit, text
}

func (s *server) handleExec(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "只支持 POST")
		return
	}
	if !s.cfg.AllowExec {
		writeErr(w, http.StatusForbidden, "面板未开启命令台（重新运行 dshm admin install 可开启）")
		return
	}
	if _, err := s.dshmPath(); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}

	var body struct {
		Line string `json:"line"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "请求体不是 JSON")
		return
	}
	tokens, err := tokenize(strings.TrimSpace(body.Line))
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	argv, err := validateCommand(tokens)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Minute)
	defer cancel()

	// 同一时间只允许一条 dshm 命令：双击/多标签并发跑 compose 会互相打架。
	if !s.execMu.TryLock() {
		writeErr(w, http.StatusConflict, "已有命令正在执行，请等它结束")
		return
	}
	defer s.execMu.Unlock()

	exit, text := s.runDshm(ctx, argv)
	s.audit("exec %q exit=%d ip=%s", strings.Join(argv, " "), exit, s.clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{
		"exit":   exit,
		"output": text,
		"argv":   argv,
	})
}

// capWriter 只保留末尾 limit 字节。命令输出可能很大，直接 CombinedOutput
// 会把整段缓存在内存里，长时间运行的命令足以把面板进程撑爆。
type capWriter struct {
	buf   []byte
	limit int
	trunc bool
}

func (c *capWriter) Write(p []byte) (int, error) {
	c.buf = append(c.buf, p...)
	// 超过两倍才裁剪一次，避免每个 chunk 都重新分配
	if len(c.buf) > 2*c.limit {
		c.buf = append([]byte(nil), c.buf[len(c.buf)-c.limit:]...)
		c.trunc = true
	}
	return len(p), nil
}

func (c *capWriter) String() string {
	if len(c.buf) > c.limit {
		c.buf = c.buf[len(c.buf)-c.limit:]
		c.trunc = true
	}
	s := string(c.buf)
	if c.trunc {
		s = "…（输出过长，仅保留末尾）\n" + s
	}
	return s
}

// ── 入口 ────────────────────────────────────────────────────────────────────

func main() {
	var (
		configPath = flag.String("config", os.Getenv("DSH_ADMIN_CONFIG"), "配置文件路径（JSON）")
		listen     = flag.String("listen", "", "监听地址，覆盖配置，如 127.0.0.1:3090")
		container  = flag.String("container", "", "要管理的容器名，覆盖配置")
		hashMode   = flag.Bool("hash", false, "从 stdin 读密码并输出哈希")
		genSecret  = flag.Bool("gen-secret", false, "生成会话密钥并退出")
		showVer    = flag.Bool("version", false, "打印面板版本并退出")
	)
	flag.Parse()

	if *showVer {
		fmt.Println(adminVersion)
		return
	}

	if *genSecret {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			log.Fatalf("生成密钥失败：%v", err)
		}
		fmt.Println(hex.EncodeToString(b))
		return
	}
	if *hashMode {
		pw, err := io.ReadAll(io.LimitReader(os.Stdin, 4096))
		if err != nil {
			log.Fatalf("读取密码失败：%v", err)
		}
		h, err := hashPassword(strings.TrimRight(string(pw), "\r\n"))
		if err != nil {
			log.Fatalf("计算哈希失败：%v", err)
		}
		fmt.Println(h)
		return
	}

	cfg := defaultConfig()
	if *configPath != "" {
		b, err := os.ReadFile(*configPath)
		if err != nil {
			log.Fatalf("读取配置失败：%v", err)
		}
		if err := json.Unmarshal(b, &cfg); err != nil {
			log.Fatalf("解析配置失败：%v", err)
		}
	}
	if *listen != "" {
		cfg.Listen = *listen
	}
	if *container != "" {
		cfg.Container = *container
	}
	// JSON 里显式写成空串会把默认值抹掉：socket 空 = 连不上 docker，
	// listen 空 = ListenAndServe("") 绑到所有网卡（面板直接暴露）。这里补回默认值。
	def := defaultConfig()
	if cfg.Listen == "" {
		cfg.Listen = def.Listen
	}
	if cfg.Socket == "" {
		cfg.Socket = def.Socket
	}
	if cfg.Container == "" {
		cfg.Container = def.Container
	}
	if cfg.SessionSecret == "" || cfg.PasswordHash == "" {
		log.Fatalf("配置缺少 session_secret 或 password_hash（先用 dshm admin 生成）")
	}
	if !strings.HasPrefix(cfg.Listen, "127.0.0.1") && !strings.HasPrefix(cfg.Listen, "localhost") {
		log.Printf("警告：监听地址为 %s，面板持 docker.sock，请勿暴露到公网", cfg.Listen)
	}
	if cfg.ProjectDir != "" {
		abs, err := filepath.Abs(cfg.ProjectDir)
		if err != nil {
			log.Fatalf("project_dir 解析失败：%v", err)
		}
		cfg.ProjectDir = abs
	}

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           newServer(cfg),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	log.Printf("dsh-admin 监听 %s，管理容器 %s，socket %s", cfg.Listen, cfg.Container, cfg.Socket)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("启动失败：%v", err)
	}
}
