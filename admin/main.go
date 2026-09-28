// dsh-admin — DSH Docker 部署的宿主/容器管理面板。
//
// 设计约束（见 README「管理面板」）：
//   - 单文件静态二进制，仅标准库，宿主零运行时依赖；
//   - 只走 Docker Engine API 的固定几个接口，不做任意透传；
//   - 独立登录 + 会话 cookie(HttpOnly/SameSite=Strict) + 自定义头防 CSRF；
//   - 默认只监听 127.0.0.1。
//
// 用法：
//   dsh-admin -config /etc/dsh-admin/config.json      # 启动面板
//   dsh-admin -hash                                    # 从 stdin 读密码，输出哈希（给 dshm 用）
//   dsh-admin -gen-secret                              # 生成会话密钥
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
	if err != nil || iter <= 0 {
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
	kept := l.fails[ip][:0]
	for _, t := range l.fails[ip] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	l.fails[ip] = kept
	return len(kept) < loginMaxFail
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
}

func newServer(cfg Config) *server {
	return &server{cfg: cfg, docker: NewDocker(cfg.Socket), limiter: newLimiter()}
}

func (s *server) audit(format string, args ...any) {
	line := fmt.Sprintf("%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, args...))
	if s.cfg.AuditLog != "" {
		if f, err := os.OpenFile(s.cfg.AuditLog, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
			f.WriteString(line)
			f.Close()
		}
	}
	log.Print(strings.TrimSpace(line))
}

func (s *server) clientIP(r *http.Request) string {
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
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
		writeErr(w, http.StatusBadRequest, "缺少 X-DSH-Admin 头")
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
		Secure:   r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https",
		MaxAge:   int(sessionTTL / time.Second),
	})
	s.audit("登录成功 ip=%s", ip)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *server) handleLogout(w http.ResponseWriter, r *http.Request) {
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

func (s *server) handleAction(w http.ResponseWriter, r *http.Request, action string) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "只支持 POST")
		return
	}
	if err := s.docker.Action(s.cfg.Container, action); err != nil {
		s.audit("%s 失败：%v", action, err)
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	s.audit("%s 成功 ip=%s", action, s.clientIP(r))
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
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

func (s *server) handleExec(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "只支持 POST")
		return
	}
	if !s.cfg.AllowExec {
		writeErr(w, http.StatusForbidden, "面板未开启命令台（重新运行 dshm admin install 可开启）")
		return
	}
	if s.cfg.ProjectDir == "" {
		writeErr(w, http.StatusBadRequest, "面板未配置项目目录 project_dir")
		return
	}
	dshm := filepath.Join(s.cfg.ProjectDir, "dshm")
	if st, err := os.Stat(dshm); err != nil || st.IsDir() {
		writeErr(w, http.StatusBadRequest, "项目目录里找不到 dshm："+dshm)
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
	cmd := exec.CommandContext(ctx, dshm, argv...)
	cmd.Dir = s.cfg.ProjectDir
	env := os.Environ()
	if s.cfg.ComposeProject != "" {
		env = append(env, "COMPOSE_PROJECT_NAME="+s.cfg.ComposeProject)
	}
	cmd.Env = env
	out, runErr := cmd.CombinedOutput()
	if len(out) > 256*1024 {
		out = append([]byte("…（输出过长，仅保留末尾）\n"), out[len(out)-256*1024:]...)
	}
	exit := 0
	if runErr != nil {
		var ee *exec.ExitError
		if errors.As(runErr, &ee) {
			exit = ee.ExitCode()
		} else {
			exit = -1
			out = append(out, []byte("\n"+runErr.Error())...)
		}
	}
	s.audit("exec %q exit=%d ip=%s", strings.Join(argv, " "), exit, s.clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{
		"exit":   exit,
		"output": string(out),
		"argv":   argv,
	})
}

// ── 入口 ────────────────────────────────────────────────────────────────────

func main() {
	var (
		configPath = flag.String("config", os.Getenv("DSH_ADMIN_CONFIG"), "配置文件路径（JSON）")
		listen     = flag.String("listen", "", "监听地址，覆盖配置，如 127.0.0.1:3090")
		container  = flag.String("container", "", "要管理的容器名，覆盖配置")
		hashMode   = flag.Bool("hash", false, "从 stdin 读密码并输出哈希")
		genSecret  = flag.Bool("gen-secret", false, "生成会话密钥并退出")
	)
	flag.Parse()

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
	if cfg.SessionSecret == "" || cfg.PasswordHash == "" {
		log.Fatalf("配置缺少 session_secret 或 password_hash（先用 dshm admin 生成）")
	}

	log.Printf("dsh-admin 监听 %s，管理容器 %s，socket %s", cfg.Listen, cfg.Container, cfg.Socket)
	if err := http.ListenAndServe(cfg.Listen, newServer(cfg)); err != nil {
		log.Fatalf("启动失败：%v", err)
	}
}
