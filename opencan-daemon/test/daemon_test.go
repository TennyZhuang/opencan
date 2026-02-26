package test

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/anthropics/opencan-daemon/internal/daemon"
)

// testDaemon starts a daemon in a temp directory for testing.
// Uses /tmp directly to keep Unix socket paths short (macOS 104-char limit).
func testDaemon(t *testing.T) (*daemon.Daemon, string) {
	t.Helper()
	tmpDir, err := os.MkdirTemp("/tmp", "ocd-*")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(tmpDir) })
	sockPath := filepath.Join(tmpDir, "d.sock")
	pidFile := filepath.Join(tmpDir, "d.pid")

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))

	cfg := daemon.Config{
		SocketPath:  sockPath,
		PIDFile:     pidFile,
		IdleTimeout: 10 * time.Minute,
		Logger:      logger,
	}

	d := daemon.New(cfg)
	go func() {
		if err := d.Run(); err != nil {
			t.Logf("daemon exited: %v", err)
		}
	}()

	// Wait for socket to be ready
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(sockPath); err == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	return d, sockPath
}

func connectToDaemon(t *testing.T, sockPath string) net.Conn {
	t.Helper()
	conn, err := net.DialTimeout("unix", sockPath, 2*time.Second)
	if err != nil {
		t.Fatalf("connect to daemon: %v", err)
	}
	return conn
}

func sendJSON(conn net.Conn, msg interface{}) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	_, err = conn.Write(append(data, '\n'))
	return err
}

func readJSON(t *testing.T, conn net.Conn) map[string]interface{} {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	scanner := bufio.NewScanner(conn)
	if !scanner.Scan() {
		t.Fatalf("no response: %v", scanner.Err())
	}
	var result map[string]interface{}
	if err := json.Unmarshal(scanner.Bytes(), &result); err != nil {
		t.Fatalf("parse response: %v (raw: %s)", err, scanner.Text())
	}
	return result
}

// readJSONWithScanner reads a single message using an existing scanner.
func readJSONWithScanner(t *testing.T, scanner *bufio.Scanner) map[string]interface{} {
	t.Helper()
	if !scanner.Scan() {
		t.Fatalf("no response: %v", scanner.Err())
	}
	var result map[string]interface{}
	if err := json.Unmarshal(scanner.Bytes(), &result); err != nil {
		t.Fatalf("parse response: %v (raw: %s)", err, scanner.Text())
	}
	return result
}

func TestDaemon_Hello(t *testing.T) {
	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	// Send hello
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/hello",
		"params":  map[string]interface{}{"clientVersion": "0.1.0"},
	})

	resp := readJSON(t, conn)
	if resp["id"].(float64) != 1 {
		t.Fatalf("expected id 1, got %v", resp["id"])
	}
	result := resp["result"].(map[string]interface{})
	if result["daemonVersion"] != "0.1.0" {
		t.Fatalf("expected version 0.1.0, got %v", result["daemonVersion"])
	}
}

func TestDaemon_SessionList_Empty(t *testing.T) {
	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.list",
		"params":  map[string]interface{}{},
	})

	resp := readJSON(t, conn)
	result := resp["result"].(map[string]interface{})
	sessions := result["sessions"].([]interface{})
	if len(sessions) != 0 {
		t.Fatalf("expected 0 sessions, got %d", len(sessions))
	}
}

func TestDaemon_SessionCreate(t *testing.T) {
	// This test requires the mock-acp-server binary
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found, run 'make mock-acp' first")
	}

	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn.SetReadDeadline(time.Now().Add(30 * time.Second))

	// Create session using mock ACP
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.create",
		"params": map[string]interface{}{
			"cwd":     "/tmp",
			"command": mockBin,
		},
	})

	resp := readJSONWithScanner(t, scanner)
	if resp["error"] != nil {
		t.Fatalf("session.create error: %v", resp["error"])
	}
	result := resp["result"].(map[string]interface{})
	sessionID, ok := result["sessionId"].(string)
	if !ok || sessionID == "" {
		t.Fatalf("expected sessionId, got %v", result)
	}
	t.Logf("created session: %s", sessionID)

	// List sessions — should see our session
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.list",
		"params":  map[string]interface{}{},
	})

	resp = readJSONWithScanner(t, scanner)
	result = resp["result"].(map[string]interface{})
	sessions := result["sessions"].([]interface{})
	if len(sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(sessions))
	}
}

func TestDaemon_SessionCreateAndPrompt(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found")
	}

	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn.SetReadDeadline(time.Now().Add(30 * time.Second))

	// Create session
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.create",
		"params": map[string]interface{}{
			"cwd":     "/tmp",
			"command": mockBin,
		},
	})

	resp := readJSONWithScanner(t, scanner)
	sessionID := resp["result"].(map[string]interface{})["sessionId"].(string)

	// Attach to session
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.attach",
		"params": map[string]interface{}{
			"sessionId":    sessionID,
			"lastEventSeq": 0,
		},
	})

	resp = readJSONWithScanner(t, scanner)
	if resp["error"] != nil {
		t.Fatalf("session.attach error: %v", resp["error"])
	}

	// Send prompt
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1001,
		"method":  "session/prompt",
		"params": map[string]interface{}{
			"sessionId": sessionID,
			"prompt": []map[string]interface{}{
				{"type": "text", "text": "hello"},
			},
		},
	})

	// Read streaming events + final response
	var notifications []map[string]interface{}
	var promptResponse map[string]interface{}
	for {
		msg := readJSONWithScanner(t, scanner)
		if msg["method"] != nil {
			// Notification
			notifications = append(notifications, msg)
		} else if msg["id"] != nil && msg["id"].(float64) == 1001 {
			// Response to our prompt
			promptResponse = msg
			break
		}
	}

	if len(notifications) == 0 {
		t.Fatal("expected streaming notifications")
	}
	if promptResponse == nil {
		t.Fatal("expected prompt response")
	}
	t.Logf("received %d notifications", len(notifications))

	// Verify notifications have __seq
	for _, n := range notifications {
		params := n["params"].(map[string]interface{})
		if _, ok := params["__seq"]; !ok {
			t.Error("notification missing __seq")
		}
	}
}

func TestDaemon_DisconnectAndReattach(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found")
	}

	d, sockPath := testDaemon(t)
	defer d.Stop()

	// Client 1: create session and start prompt
	conn1 := connectToDaemon(t, sockPath)
	scanner1 := bufio.NewScanner(conn1)
	scanner1.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn1.SetReadDeadline(time.Now().Add(30 * time.Second))

	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.create",
		"params":  map[string]interface{}{"cwd": "/tmp", "command": mockBin},
	})
	resp := readJSONWithScanner(t, scanner1)
	sessionID := resp["result"].(map[string]interface{})["sessionId"].(string)

	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.attach",
		"params":  map[string]interface{}{"sessionId": sessionID, "lastEventSeq": 0},
	})
	readJSONWithScanner(t, scanner1) // attach response

	// Send prompt
	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1001,
		"method":  "session/prompt",
		"params": map[string]interface{}{
			"sessionId": sessionID,
			"prompt":    []map[string]interface{}{{"type": "text", "text": "hello"}},
		},
	})

	// Read a couple notifications, then disconnect
	readJSONWithScanner(t, scanner1)
	readJSONWithScanner(t, scanner1)
	conn1.Close()

	// Wait for mock ACP to finish prompt
	time.Sleep(2 * time.Second)

	// Client 2: reconnect and reattach
	conn2 := connectToDaemon(t, sockPath)
	defer conn2.Close()
	scanner2 := bufio.NewScanner(conn2)
	scanner2.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn2.SetReadDeadline(time.Now().Add(10 * time.Second))

	sendJSON(conn2, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.attach",
		"params":  map[string]interface{}{"sessionId": sessionID, "lastEventSeq": 0},
	})

	resp = readJSONWithScanner(t, scanner2)
	if resp["error"] != nil {
		t.Fatalf("reattach error: %v", resp["error"])
	}
	result := resp["result"].(map[string]interface{})

	// Should have buffered events
	buffered, ok := result["bufferedEvents"].([]interface{})
	if !ok {
		t.Fatalf("expected bufferedEvents array, got %T", result["bufferedEvents"])
	}
	t.Logf("reattach: state=%v, bufferedEvents=%d", result["state"], len(buffered))

	if len(buffered) == 0 {
		t.Fatal("expected buffered events after disconnect/reconnect")
	}
}

func TestDaemon_SessionLoadRouteToSession(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found")
	}

	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn.SetReadDeadline(time.Now().Add(30 * time.Second))

	// Create a session (this will be the "new" session we route to)
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.create",
		"params":  map[string]interface{}{"cwd": "/tmp", "command": mockBin},
	})
	resp := readJSONWithScanner(t, scanner)
	newSessionID := resp["result"].(map[string]interface{})["sessionId"].(string)

	// Attach to the new session
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.attach",
		"params":  map[string]interface{}{"sessionId": newSessionID, "lastEventSeq": 0},
	})
	resp = readJSONWithScanner(t, scanner)
	if resp["error"] != nil {
		t.Fatalf("attach error: %v", resp["error"])
	}

	// Send session/load with a fake "old" sessionId but __routeToSession pointing
	// to the new session. The daemon should route this to the new session's ACP proxy.
	oldSessionID := "old-session-that-doesnt-exist"
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1001,
		"method":  "session/load",
		"params": map[string]interface{}{
			"sessionId":        oldSessionID,
			"cwd":              "/tmp",
			"mcpServers":       []interface{}{},
			"__routeToSession": newSessionID,
		},
	})

	resp = readJSONWithScanner(t, scanner)

	// Should succeed — the daemon routed to the new session's proxy
	if resp["error"] != nil {
		t.Fatalf("session/load with __routeToSession should succeed, got error: %v", resp["error"])
	}
	if resp["id"].(float64) != 1001 {
		t.Fatalf("expected response id 1001, got %v", resp["id"])
	}
	t.Logf("session/load with __routeToSession succeeded")

	// Also verify that session/load WITHOUT __routeToSession fails for the old ID
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1002,
		"method":  "session/load",
		"params": map[string]interface{}{
			"sessionId":  oldSessionID,
			"cwd":        "/tmp",
			"mcpServers": []interface{}{},
		},
	})

	resp = readJSONWithScanner(t, scanner)
	if resp["error"] == nil {
		t.Fatal("session/load for unknown session without __routeToSession should fail")
	}
	t.Logf("session/load without __routeToSession correctly failed: %v", resp["error"])
}

func findMockBin(t *testing.T) string {
	t.Helper()
	// Look for mock-acp-server binary relative to the project root
	candidates := []string{
		"bin/mock-acp-server",
		"../bin/mock-acp-server",
		"../../bin/mock-acp-server",
	}
	// Also check via MOCK_ACP_BIN env var
	if bin := os.Getenv("MOCK_ACP_BIN"); bin != "" {
		candidates = append([]string{bin}, candidates...)
	}

	for _, c := range candidates {
		abs, _ := filepath.Abs(c)
		if _, err := os.Stat(abs); err == nil {
			return abs
		}
	}

	// Try to find from the current working directory
	cwd, _ := os.Getwd()
	// Walk up from cwd looking for opencan-daemon/bin/mock-acp-server
	dir := cwd
	for i := 0; i < 5; i++ {
		candidate := filepath.Join(dir, "bin", "mock-acp-server")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
		candidate = filepath.Join(dir, "opencan-daemon", "bin", "mock-acp-server")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
		dir = filepath.Dir(dir)
	}

	return ""
}

func init() {
	// Suppress "unused import" for fmt if not used in all tests
	_ = fmt.Sprintf
}
