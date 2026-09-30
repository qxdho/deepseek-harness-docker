package main

// 管理面板自身的版本号与自更新。
//
// 版本号由 CI 用 -ldflags 注入（见 .github/workflows/build.yml）；未注入时回落到 "dev"。
// 面板与 dshm 的更新渠道不同：
//   * dshm 是仓库里的脚本 → 从 GitHub raw 拉
//   * 面板是编译产物     → 从 GitHub Releases 的 latest 拉二进制（CI 会发布）
// 两者都以 GitHub 仓库为权威来源（与 dsh 本体不同，dsh 看 npm）。
//
// 这里不实现「下载后自动重启自己」：重启依赖部署方式（systemd / pidfile），
// 盲目重启可能把用户的进程结构搞坏。改为原子替换二进制，然后提示重启 ——
// 明确、可预期，且失败时不会让面板处于半死状态。

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

// adminVersion 由构建时 -ldflags "-X main.adminVersion=..." 注入。
var adminVersion = "dev"

const (
	adminRepo = "qxdho/deepseek-harness-docker"
	// 二进制由 CI 交叉编译，只有这两种架构
	adminMaxBinary = 64 << 20
)

func adminReleaseURL(file string) string {
	return "https://github.com/" + adminRepo + "/releases/latest/download/" + file
}

// panelArch 把 runtime.GOARCH 映射成发布产物的架构名。
// 发布里没有 386/arm 等架构，取不到就明确报错，而不是去下一个错的文件。
func panelArch() (string, error) {
	switch runtime.GOARCH {
	case "amd64":
		return "amd64", nil
	case "arm64":
		return "arm64", nil
	default:
		return "", fmt.Errorf("面板自更新只提供 linux/amd64 与 linux/arm64 产物，当前是 %s/%s",
			runtime.GOOS, runtime.GOARCH)
	}
}

var sha256LineRe = regexp.MustCompile(`^([0-9a-fA-F]{64})`)

// parseSha256 从 `sha256sum` 格式的输出里取出哈希。
// 文件内容形如 "<64位hex>  <文件名>"。只取行首的哈希，忽略文件名 ——
// 这样即使发布时文件名写法和我们requested的名字不同也不会误判。
func parseSha256(s string) (string, error) {
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if m := sha256LineRe.FindStringSubmatch(line); m != nil {
			return strings.ToLower(m[1]), nil
		}
	}
	return "", fmt.Errorf("校验文件里没有找到 sha256 哈希")
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// SelfUpdateResult 是 /api/self/update 的响应。
type SelfUpdateResult struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
	Version string `json:"version"` // 面板当前版本（更新后仍是旧值，重启才生效）
	Backup  string `json:"backup"`  // 旧二进制的备份路径
}

func (s *server) handleSelfUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "只支持 POST")
		return
	}
	arch, err := panelArch()
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
	defer cancel()

	client := &http.Client{Timeout: 3 * time.Minute}
	name := "dsh-admin-linux-" + arch

	bin, err := fetchLimited(ctx, client, adminReleaseURL(name), adminMaxBinary)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "下载面板二进制失败："+err.Error())
		return
	}
	if len(bin) == 0 {
		writeErr(w, http.StatusBadGateway, "下载到的二进制是空的")
		return
	}
	// ELF 魔数：确认下到的确实是可执行文件，而不是错误页 / 代理返回的 HTML
	if len(bin) < 4 || bin[0] != 0x7f || bin[1] != 'E' || bin[2] != 'L' || bin[3] != 'F' {
		writeErr(w, http.StatusBadGateway,
			"下载到的内容不是 ELF 可执行文件（可能被代理拦截）。请检查网络或改用 dshm admin install")
		return
	}

	sumFile, err := fetchLimited(ctx, client, adminReleaseURL(name+".sha256"), 1<<16)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "下载校验文件失败："+err.Error())
		return
	}
	want, err := parseSha256(string(sumFile))
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	if got := sha256Hex(bin); got != want {
		writeErr(w, http.StatusBadGateway,
			fmt.Sprintf("校验不一致，已放弃替换（期望 %s…，实际 %s…）", want[:12], got[:12]))
		return
	}

	self, err := os.Executable()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "无法定位当前面板二进制："+err.Error())
		return
	}
	self, _ = filepath.EvalSymlinks(self)

	// 先写临时文件（与目标同目录，保证 rename 是同一文件系统内的原子操作），
	// 再把当前二进制备份走，最后 rename 覆盖。这样任何一步失败都不会留下
	// 一个「半个二进制」在目标位置。
	backup, err := installBinary(self, bin)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	s.audit("self-update 已替换面板二进制 backup=%q ip=%s", backup, s.clientIP(r))
	note := ""
	if backup == "" {
		note = "（未能备份旧二进制，原文件已被覆盖）"
	}
	writeJSON(w, http.StatusOK, SelfUpdateResult{
		OK:      true,
		Message: "已替换面板二进制，需要重启面板才会生效（systemctl restart dsh-admin 或重新执行 dshm admin install）" + note,
		Version: adminVersion,
		Backup:  backup,
	})
}

// installBinary 把 payload 装到 target 位置，并把原文件备份为 target+".bak"。
// 返回备份路径（备份失败时为空串）。
//
// 抽成独立函数是为了能单测：这是整个自更新里唯一会改文件系统的一段，出错代价最大
// （面板可能会没有可执行文件）。步骤顺序刻意设计成「任何一步失败都不破坏 target」：
//  1. 同目录建临时文件（同目录才能保证 rename 不跨文件系统）
//  2. 写内容 → 关文件 → 设可执行位
//  3. 备份现有文件，再把临时文件 rename 到位；rename 失败则把备份放回去
func installBinary(target string, payload []byte) (string, error) {
	dir := filepath.Dir(target)
	tmp, err := os.CreateTemp(dir, ".dsh-admin.new.*")
	if err != nil {
		return "", fmt.Errorf("无法在面板目录写临时文件（需要该目录可写）：%w", err)
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }() // rename 成功后这里已不存在

	if _, err := tmp.Write(payload); err != nil {
		tmp.Close()
		return "", fmt.Errorf("写入临时文件失败：%w", err)
	}
	if err := tmp.Close(); err != nil {
		return "", fmt.Errorf("关闭临时文件失败：%w", err)
	}
	if err := os.Chmod(tmpName, 0o755); err != nil {
		return "", fmt.Errorf("设置可执行位失败：%w", err)
	}

	backup := target + ".bak"
	if err := os.Rename(target, backup); err != nil {
		// 备份失败不致命（例如目标不是普通文件），置空让调用方提示用户
		backup = ""
	}
	if err := os.Rename(tmpName, target); err != nil {
		// 回滚：把备份放回去，避免面板没有可执行文件
		if backup != "" {
			_ = os.Rename(backup, target)
		}
		return "", fmt.Errorf("替换面板二进制失败（已尝试回滚）：%w", err)
	}
	return backup, nil
}

// fetchLimited 下载一个 URL，带大小上限。
func fetchLimited(ctx context.Context, c *http.Client, url string, limit int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d（%s）", resp.StatusCode, url)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, limit))
	if err != nil {
		return nil, err
	}
	return b, nil
}
