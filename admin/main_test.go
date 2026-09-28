package main

import "testing"

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
