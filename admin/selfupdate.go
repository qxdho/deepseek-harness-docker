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
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
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

	// 校验通过后，还要确认这个二进制**真能跑**、且不是比当前更旧的版本。
	// sha256 只证明"与同源校验文件一致"，证明不了"是个能用的、不比现在旧的产物"。
	candVer, err := verifyDownloadedBinary(bin, adminVersion)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "已放弃替换："+err.Error())
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
		Version: candVer,
		Backup:  backup,
	})
}

// compareVersions 比较两个版本号，返回 -1 / 0 / 1。
//
// 只做本项目用得到的比较：版本形如 v2026.10.01-3（日期 + 可选序号），
// dev 视为"最旧"（开发构建不该被当成比发布版新）。
// 逐段比较，数字段按数值比（这样 9 < 30，而字符串比较会得出 "9" > "30"），
// 非数字段退化为字符串比较。
func compareVersions(a, b string) int {
	na := strings.TrimPrefix(strings.TrimSpace(a), "v")
	nb := strings.TrimPrefix(strings.TrimSpace(b), "v")
	if na == nb {
		return 0
	}
	// dev / 空 视为最旧
	if na == "" || na == "dev" {
		if nb == "" || nb == "dev" {
			return 0
		}
		return -1
	}
	if nb == "" || nb == "dev" {
		return 1
	}
	pa := strings.FieldsFunc(na, func(r rune) bool { return r == '.' || r == '-' || r == '+' })
	pb := strings.FieldsFunc(nb, func(r rune) bool { return r == '.' || r == '-' || r == '+' })
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var sa, sb string
		if i < len(pa) {
			sa = pa[i]
		}
		if i < len(pb) {
			sb = pb[i]
		}
		if sa == sb {
			continue
		}
		// 两边都是纯数字时按数值比较
		da, ea := strconv.Atoi(sa)
		db, eb := strconv.Atoi(sb)
		switch {
		case ea == nil && eb == nil:
			if da < db {
				return -1
			}
			return 1
		case ea == nil:
			// 数字段 vs 非数字段：数字在前（1.2-3 里的 3 与 rc 相比，序号更新）
			return 1
		case eb == nil:
			return -1
		default:
			if sa < sb {
				return -1
			}
			return 1
		}
	}
	return 0
}

// verifyDownloadedBinary 把下载物写成临时文件跑一次 `-version`：
//   - 确认它**真的能执行**（架构不对、动态链接缺失、产物损坏都跑不起来）；
//   - 读出它自报的版本，拒绝对**当前版本**的降级。
//
// 为什么需要这层：sha256 只能证明"下载物与同源的校验文件一致"，证明不了"这是个能用
// 的、不比现在旧的二进制"。CI 发错架构、发了个坏产物、或 latest 别名指向了旧 release
// 时，光靠 sha256 会"成功地"装上一个跑不起来或更旧的版本，重启后才暴露。
func verifyDownloadedBinary(bin []byte, current string) (string, error) {
	dir, err := os.MkdirTemp("", "dsh-admin-verify-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)
	cand := filepath.Join(dir, "candidate")
	if err := os.WriteFile(cand, bin, 0o755); err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, cand, "-version").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("下载到的二进制无法执行（%v）：%s", err, strings.TrimSpace(string(out)))
	}
	// 只取第一行、去掉可能的散文（-version 只打印版本号，但别假定太死）
	candVer := ""
	for _, line := range strings.Split(string(out), "\n") {
		if s := strings.TrimSpace(line); s != "" {
			candVer = s
			break
		}
	}
	if candVer == "" {
		return "", fmt.Errorf("下载到的二进制没有报告版本号（输出为空）")
	}
	if strings.ContainsAny(candVer, " \t") {
		return "", fmt.Errorf("下载到的二进制报告的版本号不合常理：%q", candVer)
	}
	if compareVersions(candVer, current) < 0 {
		return "", fmt.Errorf("拒绝降级：下载到的是 %s，当前是 %s", candVer, current)
	}
	return candVer, nil
}

// hook 在「备份已完成、准备 rename 到位」之间被调用（测试用它检查 target 是否仍在位）。
// 生产路径下恒为 nil —— 这是为了能对一个**亚步骤级**的性质做断言：
// 「替换过程中 target 从不消失」。没有这个钩子就只能靠读代码相信它。
var hook func()

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
	// 落盘再改名：rename 只保证"目录项替换"是原子的，不保证数据已经写到磁盘。
	// 掉电时可能出现"名字换了、内容是空的"，所以先 Sync 再 rename。
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return "", fmt.Errorf("临时文件落盘失败：%w", err)
	}
	if err := tmp.Close(); err != nil {
		return "", fmt.Errorf("关闭临时文件失败：%w", err)
	}
	if err := os.Chmod(tmpName, 0o755); err != nil {
		return "", fmt.Errorf("设置可执行位失败：%w", err)
	}

	// 备份现有文件。**必须是"复制"而不是"改名"**：
	// 早先写的是 `os.Rename(target, backup)` —— 那让 target 在这一刻**不存在**，
	// 若此时被 kill / 断电，面板就没有可执行文件了，systemd 的 Restart=on-failure
	// 也拉不起来（找不到二进制）。改成先复制出备份，target 全程在位，
	// 再用一次 rename 原子替换。复制失败不致命（例如 target 不是普通文件）。
	backup := target + ".bak"
	if old, err := os.ReadFile(target); err == nil {
		if err := os.WriteFile(backup, old, 0o755); err != nil {
			backup = ""
		}
	} else {
		backup = ""
	}
	if hook != nil {
		hook()
	}
	if err := os.Rename(tmpName, target); err != nil {
		// 单次 rename 失败时 target 仍是旧文件（rename 语义保证），无需回滚。
		return "", fmt.Errorf("替换面板二进制失败（原文件未改动）：%w", err)
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
