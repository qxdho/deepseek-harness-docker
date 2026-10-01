package main

// dsh 版本管理：向 npm registry 查询 dsh 的可用版本。
//
// 为什么直连 npm 而不是读 dshm 的输出：
//   - npm 是 dsh 的**权威发布渠道**（GitHub 只是源码镜像，不是它的发布渠道）。
//     面板只要读 npm，就永远是最新信息，不依赖仓库/GitHub 的状态。
//   - 也避免去解析 dshm 的中文表格输出 —— 那种解析一改格式就坏。
//
// Go 标准库自带 JSON，不需要任何依赖。

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	dshNpmName     = "@deepseek-ai/dsh"
	dshNpmRegistry = "https://registry.npmjs.org"
	// registry 文档可能很大（本仓库实测响应 ~190KB），但必须有上限，
	// 免得对端返回无穷流把面板撑爆。
	dshMaxRegistryBody = 4 << 20
)

// DshVersions 是面板 /api/dsh/versions 的响应，也是前端直接消费的结构。
type DshVersions struct {
	Current  string            `json:"current"`  // 当前容器内跑的版本（探测失败时为空）
	Latest   string            `json:"latest"`   // npm dist-tags.latest
	Total    int               `json:"total"`    // 版本总数
	DistTags map[string]string `json:"distTags"` // 各发布标签，如 latest/next/alpha
	Versions []string          `json:"versions"` // 全部版本，按 semver 升序
	Panel    string            `json:"panel"`    // 管理面板自身的版本（-ldflags 注入）
}

// npmDoc 只解出我们需要的两个字段。用 json.RawMessage 接 dist-tags，
// 这样某个 tag 的值不是字符串时不会让整个响应解析失败。
type npmDoc struct {
	DistTags map[string]json.RawMessage `json:"dist-tags"`
	Versions map[string]json.RawMessage `json:"versions"`
}

type dshVersionClient struct {
	http *http.Client
	url  string
}

func newDshVersionClient() *dshVersionClient {
	return &dshVersionClient{
		http: &http.Client{Timeout: 20 * time.Second},
		url:  dshNpmRegistry + "/" + dshNpmName,
	}
}


// all 返回全部版本（semver 升序）与发布标签。
func (c *dshVersionClient) all(ctx context.Context) ([]string, map[string]string, error) {
	doc, err := c.fetch(ctx)
	if err != nil {
		return nil, nil, err
	}
	versions := make([]string, 0, len(doc.Versions))
	for v := range doc.Versions {
		versions = append(versions, v)
	}
	if len(versions) == 0 {
		return nil, nil, fmt.Errorf("registry 响应里没有版本列表")
	}
	sort.Slice(versions, func(i, j int) bool { return compareSemver(versions[i], versions[j]) < 0 })

	tags := make(map[string]string, len(doc.DistTags))
	for k, raw := range doc.DistTags {
		var v string
		if err := json.Unmarshal(raw, &v); err == nil && v != "" {
			tags[k] = v
		}
	}
	return versions, tags, nil
}

func (c *dshVersionClient) fetch(ctx context.Context) (*npmDoc, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("访问 npm registry 失败：%w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("npm registry 返回 HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, dshMaxRegistryBody))
	if err != nil {
		return nil, fmt.Errorf("读取 registry 响应失败：%w", err)
	}
	var doc npmDoc
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("registry 响应不是合法 JSON：%w", err)
	}
	return &doc, nil
}

// compareSemver 比较两个版本号。只处理数字段与常见的预发布后缀，够用即可 ——
// 这里是给人看的排序（列表里最新的在最后），不是严格的 semver 实现。
// 预发布版本（带 -）视为**小于**同号的正式版，但我们的版本号全是预发布，
// 所以实际比较的是「数字段 + 预发布数字」。
func compareSemver(a, b string) int {
	anum, apre := splitSemver(a)
	bnum, bpre := splitSemver(b)
	for i := 0; i < len(anum) || i < len(bnum); i++ {
		var x, y int
		if i < len(anum) {
			x = anum[i]
		}
		if i < len(bnum) {
			y = bnum[i]
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return comparePrerelease(apre, bpre)
}

// comparePrerelease 比较预发布段，如 rc.2 与 rc.10（数字要按数值比，不能按字典序）。
func comparePrerelease(a, b string) int {
	if a == b {
		return 0
	}
	if a == "" {
		return 1 // 无预发布后缀 > 有后缀
	}
	if b == "" {
		return -1
	}
	as := strings.Split(a, ".")
	bs := strings.Split(b, ".")
	for i := 0; i < len(as) || i < len(bs); i++ {
		if i >= len(as) {
			return -1
		}
		if i >= len(bs) {
			return 1
		}
		x, y := as[i], bs[i]
		xn, xerr := strconv.Atoi(x)
		yn, yerr := strconv.Atoi(y)
		if xerr == nil && yerr == nil {
			if xn != yn {
				if xn < yn {
					return -1
				}
				return 1
			}
			continue
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

func splitSemver(v string) ([]int, string) {
	pre := ""
	if i := strings.IndexByte(v, '-'); i >= 0 {
		pre = v[i+1:]
		v = v[:i]
	}
	// 去掉构建元数据
	if i := strings.IndexByte(v, '+'); i >= 0 {
		v = v[:i]
	}
	parts := strings.Split(v, ".")
	nums := make([]int, 0, len(parts))
	for _, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil {
			n = 0
		}
		nums = append(nums, n)
	}
	return nums, pre
}

// ── HTTP 接口 ───────────────────────────────────────────────────────────────

// versionRe 限定版本号允许的字符。面板允许用它去触发一次 `docker compose build`，
// 而该值会写进 .env 并被 compose 当作构建参数使用 —— 必须严格限制，避免通过版本号
// 注入别的 compose 变量（例如传入 "x\nDSH_UID=0"）。
var versionRe = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$`)

// currentContainerVersion 问运行中的容器它自己的 dsh 版本。
// 容器没起 / 探测失败时返回空串与错误（调用方自行决定是否当作致命）。
func (s *server) currentContainerVersion(ctx context.Context) (string, error) {
	d, err := s.docker.execInContainer(ctx, s.cfg.Container, []string{"dsh", "--version"})
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(d), nil
}

// handleDshVersions 返回当前版本、npm 最新版与全部可选版本。
func (s *server) handleDshVersions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeErr(w, http.StatusMethodNotAllowed, "只支持 GET")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	out := DshVersions{Versions: []string{}, DistTags: map[string]string{}, Panel: adminVersion}

	// 当前版本探测失败不算错：容器可能正停着，面板仍应能列出可选版本。
	if cur, err := s.currentContainerVersion(ctx); err == nil {
		out.Current = cur
	} else {
		log.Printf("探测容器内 dsh 版本失败：%v", err)
	}

	versions, tags, err := newDshVersionClient().all(ctx)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	out.Versions = versions
	out.Total = len(versions)
	out.DistTags = tags
	out.Latest = tags["latest"]
	if out.Latest == "" {
		out.Latest = versions[len(versions)-1]
	}
	writeJSON(w, http.StatusOK, out)
}

// DshUpdateResult 是切换版本的结果。
type DshUpdateResult struct {
	Exit   int    `json:"exit"`
	Output string `json:"output"`
	Target string `json:"target"`
}

// handleDshUpdate 把 dsh 切到指定版本（或最新版）并重建镜像。
//
// 走的还是 dshm：`service update <版本> --build`。不在面板里自己拼 docker compose，
// 否则版本写入 .env、预检、属主修复、等待健康这些逻辑就会有两份实现。
func (s *server) handleDshUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "只支持 POST")
		return
	}
	if _, err := s.dshmPath(); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}

	var body struct {
		Version string `json:"version"` // 留空表示「npm 上的最新版」
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "请求体不是 JSON")
		return
	}
	target := strings.TrimSpace(body.Version)

	// 注意：这里的参数必须与 dshm 的实际命令面保持一致。
	// dshm 的命令在重构后是 `version update --build [--dsh <版本>]`：
	//   * `service update` 已不存在（service 只管容器生命周期）
	//   * `--latest` 已移除（--build 本身就表示要本地构建，默认取 npm 最新版）
	//   * 版本号要用 `--dsh` 传，位置参数会被拒绝
	// 这几条一旦漂移，面板这个按钮就整条路径失效，而 test-admin.sh 用的是 stub，
	// 掩盖了问题 —— 所以测试里必须有真实 dshm 参与的用例。
	argv := []string{"version", "update", "--build"}
	if target != "" {
		if !versionRe.MatchString(target) {
			writeErr(w, http.StatusBadRequest, "版本号格式不合法")
			return
		}
		argv = append(argv, "--dsh", target)
	}

	// 构建会重装 dsh 并现场编译 node-pty，实测数分钟，超时给足。
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Minute)
	defer cancel()

	if !s.execMu.TryLock() {
		writeErr(w, http.StatusConflict, "已有 dshm 命令正在执行，请等它结束")
		return
	}
	defer s.execMu.Unlock()

	s.audit("dsh update target=%q ip=%s", target, s.clientIP(r))
	exit, text := s.runDshm(ctx, argv)
	writeJSON(w, http.StatusOK, DshUpdateResult{Exit: exit, Output: text, Target: target})
}
