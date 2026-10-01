package main

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"
)

// demuxLogs / looksFramed 的回归测试。
//
// 这里曾有过一次误判：只看**第一个**帧头就断定"这是复用流"。TTY 容器的日志是原始流，
// 正文第一段完全可能是 0x01 0x00 0x00 0x00 这样的字节（例如以 \x01 开头的带色输出），
// 于是被按错误长度切分、输出成乱码或直接被截断。
func TestDemuxLogs(t *testing.T) {
	frame := func(stream byte, payload string) []byte {
		b := make([]byte, 8+len(payload))
		b[0] = stream
		binary.BigEndian.PutUint32(b[4:8], uint32(len(payload)))
		copy(b[8:], payload)
		return b
	}

	// ① 真正的复用流（多帧）→ 只留负载
	var framed []byte
	framed = append(framed, frame(1, "hello ")...)
	framed = append(framed, frame(1, "world\n")...)
	framed = append(framed, frame(2, "stderr line\n")...)
	if got := demuxLogs(bytes.NewReader(framed)); got != "hello world\nstderr line\n" {
		t.Errorf("复用流解析错误，得到 %q", got)
	}

	// ② 原始流：正文首字节恰好长得像帧头 → **不能**按帧切。
	//    这段字节与"两帧、第二帧被截断"在字节层面**无法区分**，属于固有的歧义；
	//    选择保守侧：解析不出两个完整帧就当原始流，宁可不解析也不把 TTY 原文切碎。
	//    （旧实现只看第一个帧头就切 → 得到 "ABn text tail" 这种乱码。）
	raw := []byte("\x01\x00\x00\x00\x00\x00\x00\x02AB\x01\x00\x00\x00plain text tail")
	if got := demuxLogs(bytes.NewReader(raw)); got != string(raw) {
		t.Errorf("原始流被误当成复用流：得到 %q，期望原样", got)
	}

	// ③ 单帧：不足以断定，按原始流处理（宁可不解析也不切碎）
	one := frame(1, "only one frame")
	if got := demuxLogs(bytes.NewReader(one)); got != string(one) {
		t.Errorf("单帧不应被断言为复用流，得到 %q", got)
	}

	// ④ 被截断的复用流：**先有两个完整帧**（足以断定这是复用流），最后一帧负载不全
	trunc := append([]byte{}, frame(1, "first ")...)
	trunc = append(trunc, frame(1, "second ")...)
	trunc = append(trunc, []byte{0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00}...) // 头部合法、长度超界
	trunc = append(trunc, []byte("partial")...)
	if got := demuxLogs(bytes.NewReader(trunc)); !strings.HasPrefix(got, "first second ") {
		t.Errorf("被截断的复用流应解析出前面的完整帧，得到 %q", got)
	}

	// ⑤ 不足 8 字节 → 原样
	if got := demuxLogs(bytes.NewReader([]byte("abc"))); got != "abc" {
		t.Errorf("短输入应原样返回，得到 %q", got)
	}
}
