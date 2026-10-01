package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// 回归：写坏的 password_hash 不能让任意密码通过。
// 空摘要时 hex.DecodeString("") 返回空切片且不报错，pbkdf2(..., keyLen=0)
// 也返回空，ConstantTimeCompare 会判等 —— 必须被长度检查挡住。
func TestVerifyPasswordRejectsMalformedHash(t *testing.T) {
	malformed := []string{
		"",
		"pbkdf2-sha256$120000$ab$",            // 空摘要
		"pbkdf2-sha256$120000$$00112233",      // 空盐
		"pbkdf2-sha256$120000$ab$0011",        // 摘要过短
		"pbkdf2-sha256$0$ab$0011223344556677", // 迭代次数为 0
		"pbkdf2-sha256$999999999$ab$00112233445566778899aabbccddeeff", // 迭代次数过大
		"scrypt$1$ab$0011223344556677",                                // 算法不对
		"pbkdf2-sha256$120000$zz$0011223344556677",                    // 非法 hex
	}
	for _, h := range malformed {
		for _, pw := range []string{"", "anything", "admin"} {
			if verifyPassword(pw, h) {
				t.Fatalf("verifyPassword(%q, %q) 应为 false", pw, h)
			}
		}
	}
}

func TestPasswordRoundTrip(t *testing.T) {
	const pw = "PanelPassw0rd!"
	h, err := hashPassword(pw)
	if err != nil {
		t.Fatalf("hashPassword: %v", err)
	}
	if !verifyPassword(pw, h) {
		t.Fatal("正确密码未通过")
	}
	if verifyPassword(pw+"x", h) {
		t.Fatal("错误密码通过了")
	}
	if verifyPassword("", h) {
		t.Fatal("空密码通过了")
	}
}

func TestSessionRoundTrip(t *testing.T) {
	const secret = "0123456789abcdef"
	tok := signSession(secret, int64(1<<62))
	if !verifySession(secret, tok) {
		t.Fatal("有效会话未通过")
	}
	if verifySession(secret, tok+"x") {
		t.Fatal("被改动的会话通过了")
	}
	if verifySession("another-secret", tok) {
		t.Fatal("换密钥后仍通过")
	}
	expired := signSession(secret, 1)
	if verifySession(secret, expired) {
		t.Fatal("过期会话通过了")
	}
}

// 安全响应头 + CSP 的 script-src 哈希必须与内联脚本**逐字一致**。
//
// 这一条很关键：CSP 靠 sha256 白名单放行页面的内联脚本。脚本一改、哈希没跟着变，
// 浏览器就会**静默拒绝执行**那段脚本 —— 面板打开是白板/点了没反应，而且服务端日志
// 里什么都看不到（拒绝发生在浏览器侧）。所以必须钉住这个对应关系。
func TestSecurityHeadersAndCSPHash(t *testing.T) {
	// ① CSP 里必须真的带一个 sha256- 的 script-src
	if !strings.Contains(contentSecurityPolicy, "script-src 'sha256-") {
		t.Fatalf("CSP 缺少内联脚本的 sha256 白名单：%s", contentSecurityPolicy)
	}
	// ② 把 CSP 里那个哈希抠出来，和 indexHTML 里的内联脚本现算一遍对比
	m := regexp.MustCompile(`script-src 'sha256-([A-Za-z0-9+/=]+)'`).FindStringSubmatch(contentSecurityPolicy)
	if m == nil {
		t.Fatalf("CSP 里的 sha256 格式不对：%s", contentSecurityPolicy)
	}
	start := strings.Index(indexHTML, "<script>")
	if start < 0 {
		t.Fatal("页面里没有内联 <script>，这个测试的前提不成立")
	}
	start += len("<script>")
	end := strings.Index(indexHTML[start:], "</script>")
	if end < 0 {
		t.Fatal("内联 <script> 没有闭合标签")
	}
	sum := sha256.Sum256([]byte(indexHTML[start : start+end]))
	want := base64.StdEncoding.EncodeToString(sum[:])
	if m[1] != want {
		t.Errorf("CSP 里的脚本哈希与页面实际内容不符：\n  CSP  = %s\n  实际 = %s\n"+
			"（改了内联脚本就必须让 contentSecurityPolicy 重新计算 —— 它是 init 里算的，\n"+
			"  如果这里失败说明有人把哈希写死成了常量）", m[1], want)
	}
	// ③ 关键指令必须在
	for _, must := range []string{"frame-ancestors 'none'", "default-src 'self'"} {
		if !strings.Contains(contentSecurityPolicy, must) {
			t.Errorf("CSP 缺少 %q：%s", must, contentSecurityPolicy)
		}
	}
}

// /api/prune 必须在别的命令正在跑时**明确拒绝**，而不是排队或并发执行。
//
// prune 删的是镜像与构建缓存，可能与 `dshm version update`（正在 pull/build）撞车，
// 把 update 正在用的层删掉。修之前它完全不取锁。
func TestPruneRefusesWhenBusy(t *testing.T) {
	s := newServer(Config{}) // 不提供 socket：真实的 docker 调用只会失败，我们只验"先被锁挡住"

	// 把锁拿在手里，模拟"已有命令在执行"
	s.execMu.Lock()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/prune", nil)
	s.handlePrune(rr, req)
	s.execMu.Unlock()

	if rr.Code != http.StatusConflict {
		t.Errorf("忙时应返回 409，实际 %d（body=%s）", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), "请等它结束") {
		t.Errorf("应提示等待正在执行的命令，实际：%s", rr.Body.String())
	}
}

// 非 POST 必须 405（这条是原有行为，一起钉住，免得重构时丢掉）
func TestPruneRejectsNonPOST(t *testing.T) {
	s := newServer(Config{})
	rr := httptest.NewRecorder()
	s.handlePrune(rr, httptest.NewRequest(http.MethodGet, "/api/prune", nil))
	if rr.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET 应返回 405，实际 %d", rr.Code)
	}
}

// 审计日志写不进去时必须**留下痕迹**（写到进程日志），而不是静默消失。
//
// 原来 `if f, err := os.OpenFile(...); err == nil { ... }` —— 打开失败就什么都不做，
// 面板照常工作，用户以为在审计其实一条都没记。这是安全相关功能，不能静默降级。
func TestAuditReportsWriteFailure(t *testing.T) {
	// 指向一个不可能创建成功的路径：父目录是「文件」而不是目录
	f := filepath.Join(t.TempDir(), "not-a-dir")
	if err := os.WriteFile(f, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := newServer(Config{AuditLog: filepath.Join(f, "audit.log")})

	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)
	s.audit("测试条目")

	if !strings.Contains(buf.String(), "审计日志打开失败") {
		t.Errorf("审计写失败时应打到进程日志，实际日志：%q", buf.String())
	}
	// 无论写文件成功与否，"条目本身"都要出现在进程日志里（这是最后一道可追溯性）
	if !strings.Contains(buf.String(), "测试条目") {
		t.Errorf("条目本身应出现在进程日志里，实际：%q", buf.String())
	}
}

// 审计日志正常时：文件里要真的有那一行（不能因为加了错误处理反而写不进去）
func TestAuditWritesToFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "audit.log")
	s := newServer(Config{AuditLog: path})
	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)
	s.audit("写入测试 %d", 42)

	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("审计文件应存在：%v", err)
	}
	if !strings.Contains(string(b), "写入测试 42") {
		t.Errorf("审计文件内容不对：%q", string(b))
	}
}
