package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Docker 是最小化的 Docker Engine API 客户端：只走 Unix socket，只用本面板
// 真正需要的几个接口。**不做任意透传** —— 面板被攻破也拿不到「执行任意
// docker 命令」的能力。
type Docker struct {
	http   *http.Client
	socket string
}

func NewDocker(socket string) *Docker {
	tr := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", socket)
		},
	}
	return &Docker{
		http:   &http.Client{Transport: tr, Timeout: 60 * time.Second},
		socket: socket,
	}
}

func (d *Docker) do(method, path string) (*http.Response, error) {
	req, err := http.NewRequest(method, "http://docker"+path, nil)
	if err != nil {
		return nil, err
	}
	return d.http.Do(req)
}

func (d *Docker) decode(method, path string, out any) error {
	resp, err := d.do(method, path)
	if err != nil {
		return fmt.Errorf("连接 Docker socket 失败（%s）：%w", d.socket, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("docker %s %s: %s: %s", method, path, resp.Status, strings.TrimSpace(string(b)))
	}
	if out == nil {
		io.Copy(io.Discard, resp.Body)
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// ── 状态 ────────────────────────────────────────────────────────────────────

type ContainerStatus struct {
	Name      string   `json:"name"`
	Image     string   `json:"image"`
	Status    string   `json:"status"`
	Running   bool     `json:"running"`
	Health    string   `json:"health"`
	Restarts  int      `json:"restarts"`
	StartedAt string   `json:"startedAt"`
	Ports     []string `json:"ports"`
}

func (d *Docker) Status(name string) (*ContainerStatus, error) {
	var raw struct {
		Name  string `json:"Name"`
		State struct {
			Status       string `json:"Status"`
			Running      bool   `json:"Running"`
			RestartCount int    `json:"RestartCount"`
			StartedAt    string `json:"StartedAt"`
			Health       *struct {
				Status string `json:"Status"`
			} `json:"Health"`
		} `json:"State"`
		Config struct {
			Image string `json:"Image"`
		} `json:"Config"`
		NetworkSettings struct {
			Ports map[string][]struct {
				HostIP   string `json:"HostIp"`
				HostPort string `json:"HostPort"`
			} `json:"Ports"`
		} `json:"NetworkSettings"`
	}
	if err := d.decode(http.MethodGet, "/containers/"+url.PathEscape(name)+"/json", &raw); err != nil {
		return nil, err
	}
	st := &ContainerStatus{
		Name:      strings.TrimPrefix(raw.Name, "/"),
		Image:     raw.Config.Image,
		Status:    raw.State.Status,
		Running:   raw.State.Running,
		Restarts:  raw.State.RestartCount,
		StartedAt: raw.State.StartedAt,
	}
	if raw.State.Health != nil {
		st.Health = raw.State.Health.Status
	} else {
		st.Health = "-"
	}
	for cport, binds := range raw.NetworkSettings.Ports {
		if len(binds) == 0 {
			st.Ports = append(st.Ports, cport)
			continue
		}
		for _, b := range binds {
			st.Ports = append(st.Ports, fmt.Sprintf("%s:%s -> %s", b.HostIP, b.HostPort, cport))
		}
	}
	sort.Strings(st.Ports)
	return st, nil
}

func (d *Docker) Action(name, action string) error {
	switch action {
	case "start", "stop", "restart":
	default:
		return fmt.Errorf("不支持的动作：%s", action)
	}
	return d.decode(http.MethodPost, "/containers/"+url.PathEscape(name)+"/"+action+"?t=20", nil)
}

// ── 日志 ────────────────────────────────────────────────────────────────────

func (d *Docker) Logs(name string, tail int) (string, error) {
	if tail <= 0 || tail > 5000 {
		tail = 300
	}
	q := url.Values{}
	q.Set("stdout", "1")
	q.Set("stderr", "1")
	q.Set("tail", strconv.Itoa(tail))
	resp, err := d.do(http.MethodGet, "/containers/"+url.PathEscape(name)+"/logs?"+q.Encode())
	if err != nil {
		return "", fmt.Errorf("连接 Docker socket 失败：%w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("docker logs: %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	return demuxLogs(resp.Body), nil
}

// Docker 的非 TTY 日志是「8 字节头 + 负载」的复用流：头里第 1 字节是流号
// （0/1/2），第 5-8 字节是大端长度。TTY 容器的日志则是原始流，没有帧头——
// 直接按帧解析会把正文当成长度，输出乱码甚至截断，所以先判断再拆。
func demuxLogs(r io.Reader) string {
	data, err := io.ReadAll(io.LimitReader(r, 8<<20))
	if err != nil && len(data) == 0 {
		return ""
	}
	framed := len(data) >= 8 && data[0] <= 2 && data[1] == 0 && data[2] == 0 && data[3] == 0
	if !framed {
		return string(data)
	}
	var sb strings.Builder
	for off := 0; off+8 <= len(data); {
		n := int(binary.BigEndian.Uint32(data[off+4 : off+8]))
		off += 8
		if n < 0 || off+n > len(data) {
			sb.Write(data[off:])
			break
		}
		sb.Write(data[off : off+n])
		off += n
	}
	return sb.String()
}

// ── 磁盘 ────────────────────────────────────────────────────────────────────

type DiskUsage struct {
	Images     int64 `json:"images"`
	Containers int64 `json:"containers"`
	Volumes    int64 `json:"volumes"`
	BuildCache int64 `json:"buildCache"`
	Total      int64 `json:"total"`
}

func (d *Docker) Disk() (*DiskUsage, error) {
	var raw struct {
		Images []struct {
			Size int64 `json:"Size"`
		} `json:"Images"`
		Containers []struct {
			SizeRw int64 `json:"SizeRw"`
		} `json:"Containers"`
		Volumes []struct {
			UsageData struct {
				Size int64 `json:"Size"`
			} `json:"UsageData"`
		} `json:"Volumes"`
		BuildCache []struct {
			Size int64 `json:"Size"`
		} `json:"BuildCache"`
	}
	if err := d.decode(http.MethodGet, "/system/df", &raw); err != nil {
		return nil, err
	}
	u := &DiskUsage{}
	for _, i := range raw.Images {
		u.Images += i.Size
	}
	for _, c := range raw.Containers {
		u.Containers += c.SizeRw
	}
	for _, v := range raw.Volumes {
		u.Volumes += v.UsageData.Size
	}
	for _, b := range raw.BuildCache {
		u.BuildCache += b.Size
	}
	u.Total = u.Images + u.Containers + u.Volumes + u.BuildCache
	return u, nil
}

// Prune 只清 dangling 镜像与构建缓存，**默认不动数据卷**。
func (d *Docker) Prune() (int64, error) {
	var reclaimed int64
	var img struct {
		SpaceReclaimed int64 `json:"SpaceReclaimed"`
	}
	filter := url.QueryEscape(`{"dangling":{"true":true}}`)
	if err := d.decode(http.MethodPost, "/images/prune?filters="+filter, &img); err != nil {
		return 0, err
	}
	reclaimed += img.SpaceReclaimed

	var bc struct {
		SpaceReclaimed int64 `json:"SpaceReclaimed"`
	}
	if err := d.decode(http.MethodPost, "/build/prune", &bc); err != nil {
		// 构建缓存清理失败不影响镜像清理的结果
		return reclaimed, nil
	}
	reclaimed += bc.SpaceReclaimed
	return reclaimed, nil
}

// ── 在容器内执行命令 ────────────────────────────────────────────────────────

// execInContainer 在容器里跑一条命令并返回合并后的输出。
//
// 走 Docker 的 exec API：先 /exec/create 建会话，再 /exec/{id}/start 执行。
// start 的响应是 Docker 的多路复用流（stdout/stderr 各带 8 字节头），
// 复用 demuxLogs 解析。
func (d *Docker) execInContainer(ctx context.Context, name string, argv []string) (string, error) {
	createBody, err := json.Marshal(map[string]any{
		"AttachStdout": true,
		"AttachStderr": true,
		"Cmd":          argv,
	})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"http://docker/containers/"+url.PathEscape(name)+"/exec", bytes.NewReader(createBody))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := d.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("连接 Docker socket 失败（%s）：%w", d.socket, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("docker exec create: %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	var created struct {
		ID string `json:"Id"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&created); err != nil {
		return "", fmt.Errorf("解析 exec create 响应失败：%w", err)
	}
	if created.ID == "" {
		return "", errors.New("docker 没有返回 exec id")
	}

	startBody, _ := json.Marshal(map[string]any{"Detach": false, "Tty": false})
	sreq, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"http://docker/exec/"+url.PathEscape(created.ID)+"/start", bytes.NewReader(startBody))
	if err != nil {
		return "", err
	}
	sreq.Header.Set("Content-Type", "application/json")
	sresp, err := d.http.Do(sreq)
	if err != nil {
		return "", fmt.Errorf("执行容器内命令失败：%w", err)
	}
	defer sresp.Body.Close()
	if sresp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(sresp.Body, 4096))
		return "", fmt.Errorf("docker exec start: %s: %s", sresp.Status, strings.TrimSpace(string(b)))
	}
	// 容器内命令输出可能很大，但仍然要有上限
	return demuxLogs(io.LimitReader(sresp.Body, 1<<20)), nil
}
