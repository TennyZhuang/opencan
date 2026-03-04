package test

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anthropics/opencan-daemon/internal/daemon"
)

// testDaemon starts a daemon in a temp directory for testing.
// Uses /tmp directly to keep Unix socket paths short (macOS 104-char limit).
func testDaemon(t *testing.T) (*daemon.Daemon, string) {
	return testDaemonWithTimeout(t, 10*time.Minute)
}

func testDaemonWithTimeout(t *testing.T, idleTimeout time.Duration) (*daemon.Daemon, string) {
	t.Helper()
	tmpDir, err := os.MkdirTemp("/tmp", "ocd-*")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(tmpDir) })
	sockPath := filepath.Join(tmpDir, "d.sock")
	pidFile := filepath.Join(tmpDir, "d.pid")

	logBuffer := daemon.NewLogRingBuffer(2000)
	logger := slog.New(
		daemon.NewBufferingHandler(
			slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}),
			logBuffer,
		),
	)

	cfg := daemon.Config{
		SocketPath:  sockPath,
		PIDFile:     pidFile,
		IdleTimeout: idleTimeout,
		Logger:      logger,
		LogBuffer:   logBuffer,
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

// readResponseWithID scans until a JSON-RPC response/error with the requested id arrives.
// Notifications can be interleaved before the response.
func readResponseWithID(t *testing.T, scanner *bufio.Scanner, id float64) map[string]interface{} {
	t.Helper()
	for i := 0; i < 20; i++ {
		msg := readJSONWithScanner(t, scanner)
		if msgID, ok := msg["id"].(float64); ok && msgID == id {
			return msg
		}
	}
	t.Fatalf("response id %.0f not found after reading interleaved messages", id)
	return nil
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

func TestDaemon_Hello_StringRequestIDRoundTrip(t *testing.T) {
	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      "hello-1",
		"method":  "daemon/hello",
		"params":  map[string]interface{}{"clientVersion": "0.1.0"},
	})

	resp := readJSON(t, conn)
	id, ok := resp["id"].(string)
	if !ok {
		t.Fatalf("expected string id round-trip, got %T (%v)", resp["id"], resp["id"])
	}
	if id != "hello-1" {
		t.Fatalf("expected id hello-1, got %q", id)
	}
}

func TestDaemon_MalformedRequestReturnsParseErrorOnSameID(t *testing.T) {
	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	// Intentionally malformed/truncated JSON so ParseLine fails after the id.
	raw := `{"jsonrpc":"2.0","id":99,"method":"session/prompt","params":{"sessionId":"abc","prompt":[{"type":"text","text":"hello"}]}`
	if _, err := conn.Write([]byte(raw + "\n")); err != nil {
		t.Fatalf("write malformed request: %v", err)
	}

	resp := readJSON(t, conn)
	if resp["id"].(float64) != 99 {
		t.Fatalf("expected id 99 in parse error response, got %v", resp["id"])
	}
	errObj, ok := resp["error"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected error object, got %#v", resp)
	}
	if code := errObj["code"].(float64); code != -32700 {
		t.Fatalf("expected parse error code -32700, got %v", code)
	}
	if !strings.Contains(fmt.Sprint(errObj["message"]), "Parse error") {
		t.Fatalf("unexpected parse error message: %v", errObj["message"])
	}
}

func TestDaemon_LogsEndpointSupportsTraceFiltering(t *testing.T) {
	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.list",
		"params": map[string]interface{}{
			"_meta": map[string]interface{}{"traceId": "trace-a"},
		},
	})
	_ = readJSON(t, conn)

	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/hello",
		"params": map[string]interface{}{
			"clientVersion": "0.1.0",
			"_meta":         map[string]interface{}{"traceId": "trace-b"},
		},
	})
	_ = readJSON(t, conn)

	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "daemon/logs",
		"params": map[string]interface{}{
			"count": 200,
		},
	})
	resp := readJSON(t, conn)
	if resp["error"] != nil {
		t.Fatalf("daemon/logs error: %v", resp["error"])
	}
	entries := resp["result"].(map[string]interface{})["entries"].([]interface{})
	if len(entries) == 0 {
		t.Fatal("expected daemon/logs to return entries")
	}

	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      4,
		"method":  "daemon/logs",
		"params": map[string]interface{}{
			"count":   200,
			"traceId": "trace-a",
		},
	})
	filteredResp := readJSON(t, conn)
	if filteredResp["error"] != nil {
		t.Fatalf("daemon/logs filtered error: %v", filteredResp["error"])
	}
	filtered := filteredResp["result"].(map[string]interface{})["entries"].([]interface{})
	if len(filtered) == 0 {
		t.Fatal("expected filtered daemon/logs to return trace-a entries")
	}
	for _, raw := range filtered {
		entry := raw.(map[string]interface{})
		attrs, ok := entry["attrs"].(map[string]interface{})
		if !ok {
			t.Fatalf("expected attrs map in filtered entry, got %#v", entry)
		}
		if attrs["traceId"] != "trace-a" {
			t.Fatalf("unexpected traceId in filtered result: %v", attrs["traceId"])
		}
	}

	// Filter should happen before truncation by count.
	// Even with count=1, we should still get the most recent trace-a entry.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      5,
		"method":  "daemon/logs",
		"params": map[string]interface{}{
			"count":   1,
			"traceId": "trace-a",
		},
	})
	filteredLimitedResp := readJSON(t, conn)
	if filteredLimitedResp["error"] != nil {
		t.Fatalf("daemon/logs filtered limited error: %v", filteredLimitedResp["error"])
	}
	filteredLimited := filteredLimitedResp["result"].(map[string]interface{})["entries"].([]interface{})
	if len(filteredLimited) != 1 {
		t.Fatalf("expected 1 filtered entry with count=1, got %d", len(filteredLimited))
	}
	entry := filteredLimited[0].(map[string]interface{})
	attrs, ok := entry["attrs"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected attrs map in filtered limited entry, got %#v", entry)
	}
	if attrs["traceId"] != "trace-a" {
		t.Fatalf("unexpected traceId in filtered limited result: %v", attrs["traceId"])
	}
}

func TestDaemon_AgentProbe(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found, run 'make mock-acp' first")
	}

	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/agent.probe",
		"params": map[string]interface{}{
			"agents": []map[string]interface{}{
				{
					"id":      "mock",
					"command": mockBin,
				},
				{
					"id":      "missing",
					"command": "definitely-not-installed-acp-binary",
				},
			},
		},
	})

	resp := readJSON(t, conn)
	result := resp["result"].(map[string]interface{})
	agents, ok := result["agents"].([]interface{})
	if !ok || len(agents) != 2 {
		t.Fatalf("expected 2 probed agents, got %v", result["agents"])
	}

	byID := map[string]map[string]interface{}{}
	for _, raw := range agents {
		entry := raw.(map[string]interface{})
		byID[entry["id"].(string)] = entry
	}

	mock := byID["mock"]
	if mock == nil {
		t.Fatalf("missing probe result for mock command: %#v", byID)
	}
	if mock["available"] != true {
		t.Fatalf("expected mock probe available=true, got %#v", mock)
	}

	missing := byID["missing"]
	if missing == nil {
		t.Fatalf("missing probe result for missing command: %#v", byID)
	}
	if missing["available"] != false {
		t.Fatalf("expected missing probe available=false, got %#v", missing)
	}
}

func TestDaemon_AgentProbeMalformedParamsReturnsInvalidParams(t *testing.T) {
	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/agent.probe",
		"params":  "malformed",
	})

	resp := readJSON(t, conn)
	if resp["error"] == nil {
		t.Fatalf("expected invalid params error, got response: %#v", resp)
	}
	errObj, ok := resp["error"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected error object, got %#v", resp["error"])
	}
	if code := errObj["code"].(float64); code != -32602 {
		t.Fatalf("expected -32602 invalid params, got %v", code)
	}
}

func TestDaemon_DaemonNotificationWithoutIDDoesNotCrash(t *testing.T) {
	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	// Send daemon/hello as a notification (no id). Daemon should ignore it
	// instead of panicking due to nil request id.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "daemon/hello",
		"params":  map[string]interface{}{"clientVersion": "0.1.0"},
	})

	// Verify the same connection is still alive with a regular request.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.list",
		"params":  map[string]interface{}{},
	})

	resp := readJSON(t, conn)
	if resp["id"].(float64) != 2 {
		t.Fatalf("expected id 2, got %v", resp["id"])
	}
	if resp["error"] != nil {
		t.Fatalf("unexpected error response: %v", resp["error"])
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

func TestDaemon_SessionList_DiscoversExternalWithoutManagedSessions(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found, run 'make mock-acp' first")
	}

	t.Setenv("OPENCAN_DISCOVERY_COMMANDS", mockBin)
	t.Setenv("MOCK_LIST_SESSIONS", "external-a,external-b")
	t.Setenv("MOCK_LIST_OMIT_CREATED", "1")

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
	if resp["error"] != nil {
		t.Fatalf("session.list error: %v", resp["error"])
	}

	result := resp["result"].(map[string]interface{})
	sessions := result["sessions"].([]interface{})
	if len(sessions) != 2 {
		t.Fatalf("expected 2 discovered sessions, got %d", len(sessions))
	}

	ids := make(map[string]bool, len(sessions))
	for _, raw := range sessions {
		item, ok := raw.(map[string]interface{})
		if !ok {
			t.Fatalf("unexpected session entry: %#v", raw)
		}
		id, ok := item["sessionId"].(string)
		if !ok || id == "" {
			t.Fatalf("missing sessionId in entry: %#v", item)
		}
		ids[id] = true
		if state, _ := item["state"].(string); state != "external" {
			t.Fatalf("expected state=external for %s, got %q", id, state)
		}
	}
	if !ids["external-a"] || !ids["external-b"] {
		t.Fatalf("missing expected discovered sessions, got ids=%v", ids)
	}
}

func TestDaemon_SessionList_ManagedProxyAlsoProbesOtherDiscoveryCommands(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found, run 'make mock-acp' first")
	}

	// Simulate command-specific session/list behavior:
	// - emptyCmd (managed proxy) returns no loadable sessions.
	// - richCmd (extra discovery command) returns an external session.
	tmpDir := t.TempDir()
	emptyCmd := writeMockWrapperCommand(t, filepath.Join(tmpDir, "mock-empty.sh"), mockBin, "")
	richCmd := writeMockWrapperCommand(t, filepath.Join(tmpDir, "mock-rich.sh"), mockBin, "external-rich")

	t.Setenv("OPENCAN_DISCOVERY_COMMANDS", emptyCmd+","+richCmd)
	t.Setenv("MOCK_LIST_OMIT_CREATED", "1")
	t.Setenv("MOCK_LIST_SESSIONS", "")

	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn.SetReadDeadline(time.Now().Add(30 * time.Second))

	// Create a managed session using the "empty" command so proxy-based probing
	// alone would return no loadable sessions.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.create",
		"params": map[string]interface{}{
			"cwd":     "/tmp",
			"command": emptyCmd,
		},
	})
	resp := readResponseWithID(t, scanner, 1)
	if resp["error"] != nil {
		t.Fatalf("session.create error: %v", resp["error"])
	}

	// session.list should still include externally discovered sessions from the
	// additional command.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.list",
		"params":  map[string]interface{}{},
	})
	resp = readResponseWithID(t, scanner, 2)
	if resp["error"] != nil {
		t.Fatalf("session.list error: %v", resp["error"])
	}

	result := resp["result"].(map[string]interface{})
	sessions := result["sessions"].([]interface{})

	foundExternal := false
	for _, raw := range sessions {
		item, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		id, _ := item["sessionId"].(string)
		if id != "external-rich" {
			continue
		}
		state, _ := item["state"].(string)
		if state != "external" {
			t.Fatalf("expected external-rich state=external, got %q", state)
		}
		foundExternal = true
		break
	}
	if !foundExternal {
		t.Fatalf("expected external-rich in session.list, got %v", sessions)
	}
}

func TestDaemon_SessionList_DeadManagedLoadableSessionShownAsExternal(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found, run 'make mock-acp' first")
	}

	t.Setenv("OPENCAN_DISCOVERY_COMMANDS", mockBin)
	t.Setenv("MOCK_CRASH_AFTER", "1")

	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn.SetReadDeadline(time.Now().Add(30 * time.Second))

	// Create a managed session.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.create",
		"params": map[string]interface{}{
			"cwd":     "/tmp",
			"command": mockBin,
		},
	})
	resp := readResponseWithID(t, scanner, 1)
	if resp["error"] != nil {
		t.Fatalf("session.create error: %v", resp["error"])
	}
	sessionID, _ := resp["result"].(map[string]interface{})["sessionId"].(string)
	if sessionID == "" {
		t.Fatalf("missing sessionId in create response: %v", resp["result"])
	}

	// Attach so session/prompt can be routed.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.attach",
		"params": map[string]interface{}{
			"sessionId":    sessionID,
			"lastEventSeq": 0,
			"clientId":     "test-client",
		},
	})
	resp = readResponseWithID(t, scanner, 2)
	if resp["error"] != nil {
		t.Fatalf("session.attach error: %v", resp["error"])
	}

	// Trigger mock ACP crash so daemon marks managed proxy dead.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "session/prompt",
		"params": map[string]interface{}{
			"sessionId": sessionID,
			"prompt": []map[string]interface{}{
				{
					"type": "text",
					"text": "crash",
				},
			},
		},
	})

	// Expose the same session ID via external discovery.
	t.Setenv("MOCK_LIST_SESSIONS", sessionID)

	deadline := time.Now().Add(5 * time.Second)
	var lastState string
	for attempt := 0; time.Now().Before(deadline); attempt++ {
		reqID := float64(100 + attempt)
		sendJSON(conn, map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      reqID,
			"method":  "daemon/session.list",
			"params":  map[string]interface{}{},
		})

		resp = readResponseWithID(t, scanner, reqID)
		if resp["error"] != nil {
			t.Fatalf("session.list error: %v", resp["error"])
		}

		result, _ := resp["result"].(map[string]interface{})
		items, _ := result["sessions"].([]interface{})
		lastState = ""
		for _, raw := range items {
			item, ok := raw.(map[string]interface{})
			if !ok {
				continue
			}
			id, _ := item["sessionId"].(string)
			if id != sessionID {
				continue
			}
			lastState, _ = item["state"].(string)
			break
		}
		if lastState == "external" {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}

	t.Fatalf("expected %s to be listed as external after managed death; lastState=%q", sessionID, lastState)
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

func TestDaemon_SessionListFiltersNonLoadableIdleSessions(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found, run 'make mock-acp' first")
	}

	// Simulate transient daemon-only sessions that do not appear in ACP session/list.
	t.Setenv("MOCK_LIST_OMIT_CREATED", "1")

	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn.SetReadDeadline(time.Now().Add(30 * time.Second))

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

	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.list",
		"params":  map[string]interface{}{},
	})
	resp = readJSONWithScanner(t, scanner)
	if resp["error"] != nil {
		t.Fatalf("session.list error: %v", resp["error"])
	}
	result := resp["result"].(map[string]interface{})
	sessions := result["sessions"].([]interface{})
	if len(sessions) != 0 {
		t.Fatalf("expected transient non-loadable session to be filtered, got %d entries", len(sessions))
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

func TestDaemon_PromptResponseWithoutPromptCompleteStillEndsPrompting(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found")
	}
	t.Setenv("MOCK_OMIT_PROMPT_COMPLETE", "1")

	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	defer conn.Close()

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn.SetReadDeadline(time.Now().Add(30 * time.Second))

	// Create session.
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
	sessionID := resp["result"].(map[string]interface{})["sessionId"].(string)

	// Attach session.
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

	// Prompt. Mock omits prompt_complete but still returns stopReason.
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

	sawPromptComplete := false
	for {
		msg := readJSONWithScanner(t, scanner)
		if method, ok := msg["method"].(string); ok {
			if method == "session/update" {
				params, _ := msg["params"].(map[string]interface{})
				update, _ := params["update"].(map[string]interface{})
				if update["sessionUpdate"] == "prompt_complete" {
					sawPromptComplete = true
				}
			}
			continue
		}
		if msgID, ok := msg["id"].(float64); ok && msgID == 1001 {
			result := msg["result"].(map[string]interface{})
			if result["stopReason"] != "end_turn" {
				t.Fatalf("unexpected stopReason: %v", result["stopReason"])
			}
			break
		}
	}
	if sawPromptComplete {
		t.Fatal("mock unexpectedly emitted prompt_complete")
	}

	// Prompt lifecycle should still terminate in daemon state machine.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2001,
		"method":  "daemon/session.list",
		"params":  map[string]interface{}{},
	})
	resp = readJSONWithScanner(t, scanner)
	if resp["error"] != nil {
		t.Fatalf("session.list error: %v", resp["error"])
	}
	sessions := resp["result"].(map[string]interface{})["sessions"].([]interface{})
	if len(sessions) == 0 {
		t.Fatal("expected at least one session")
	}

	state := ""
	for _, item := range sessions {
		entry, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		if entry["sessionId"] == sessionID {
			state, _ = entry["state"].(string)
			break
		}
	}
	if state == "" {
		t.Fatalf("session %s not found in session.list", sessionID)
	}
	if state != "idle" {
		t.Fatalf("session state = %q, want %q", state, "idle")
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
	resp := readResponseWithID(t, scanner1, 1)
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

func TestDaemon_SessionAttachRejectsSecondClient(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found")
	}

	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn1 := connectToDaemon(t, sockPath)
	defer conn1.Close()
	scanner1 := bufio.NewScanner(conn1)
	scanner1.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn1.SetReadDeadline(time.Now().Add(30 * time.Second))

	// Client 1 creates and attaches a session.
	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.create",
		"params":  map[string]interface{}{"cwd": "/tmp", "command": mockBin},
	})
	resp := readResponseWithID(t, scanner1, 1)
	sessionID := resp["result"].(map[string]interface{})["sessionId"].(string)

	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.attach",
		"params":  map[string]interface{}{"sessionId": sessionID, "lastEventSeq": 0},
	})
	resp = readResponseWithID(t, scanner1, 2)
	if resp["error"] != nil {
		t.Fatalf("client1 attach error: %v", resp["error"])
	}

	// Client 2 cannot attach while client 1 owns the session.
	conn2 := connectToDaemon(t, sockPath)
	defer conn2.Close()
	scanner2 := bufio.NewScanner(conn2)
	scanner2.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn2.SetReadDeadline(time.Now().Add(30 * time.Second))

	sendJSON(conn2, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.attach",
		"params":  map[string]interface{}{"sessionId": sessionID, "lastEventSeq": 0},
	})
	resp = readResponseWithID(t, scanner2, 1)
	if resp["error"] == nil {
		t.Fatal("expected attach rejection for second client")
	}

	// Once client 1 detaches, client 2 can attach successfully.
	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "daemon/session.detach",
		"params":  map[string]interface{}{"sessionId": sessionID},
	})
	resp = readResponseWithID(t, scanner1, 3)
	if resp["error"] != nil {
		t.Fatalf("client1 detach error: %v", resp["error"])
	}

	sendJSON(conn2, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.attach",
		"params":  map[string]interface{}{"sessionId": sessionID, "lastEventSeq": 0},
	})
	resp = readResponseWithID(t, scanner2, 2)
	if resp["error"] != nil {
		t.Fatalf("client2 attach after detach should succeed: %v", resp["error"])
	}
}

func TestDaemon_SessionAttachAllowsSameClientIDReclaim(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found")
	}

	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn1 := connectToDaemon(t, sockPath)
	defer conn1.Close()
	scanner1 := bufio.NewScanner(conn1)
	scanner1.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn1.SetReadDeadline(time.Now().Add(30 * time.Second))

	// Client 1 creates and attaches a session with clientId.
	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.create",
		"params":  map[string]interface{}{"cwd": "/tmp", "command": mockBin},
	})
	resp := readResponseWithID(t, scanner1, 1)
	sessionID := resp["result"].(map[string]interface{})["sessionId"].(string)

	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.attach",
		"params": map[string]interface{}{
			"sessionId":    sessionID,
			"lastEventSeq": 0,
			"clientId":     "ios-app-1",
		},
	})
	resp = readResponseWithID(t, scanner1, 2)
	if resp["error"] != nil {
		t.Fatalf("client1 attach error: %v", resp["error"])
	}

	// Client 2 with the same clientId can reclaim ownership.
	conn2 := connectToDaemon(t, sockPath)
	defer conn2.Close()
	scanner2 := bufio.NewScanner(conn2)
	scanner2.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn2.SetReadDeadline(time.Now().Add(30 * time.Second))

	sendJSON(conn2, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.attach",
		"params": map[string]interface{}{
			"sessionId":    sessionID,
			"lastEventSeq": 0,
			"clientId":     "ios-app-1",
		},
	})
	resp = readResponseWithID(t, scanner2, 1)
	if resp["error"] != nil {
		t.Fatalf("client2 attach with same clientId should succeed: %v", resp["error"])
	}

	// Old reclaimed connection should no longer be allowed to forward ACP requests.
	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "session/prompt",
		"params": map[string]interface{}{
			"sessionId": sessionID,
			"prompt": []map[string]interface{}{
				{"type": "text", "text": "old-owner-should-fail"},
			},
		},
	})
	resp = readResponseWithID(t, scanner1, 3)
	if resp["error"] == nil {
		t.Fatal("expected old connection prompt rejection after reclaim")
	}
	if !strings.Contains(fmt.Sprint(resp["error"]), "not attached to session: "+sessionID) {
		t.Fatalf("unexpected old connection error: %v", resp["error"])
	}

	// A third client with a different clientId is still rejected.
	conn3 := connectToDaemon(t, sockPath)
	defer conn3.Close()
	scanner3 := bufio.NewScanner(conn3)
	scanner3.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn3.SetReadDeadline(time.Now().Add(30 * time.Second))

	sendJSON(conn3, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.attach",
		"params": map[string]interface{}{
			"sessionId":    sessionID,
			"lastEventSeq": 0,
			"clientId":     "ios-app-2",
		},
	})
	resp = readResponseWithID(t, scanner3, 1)
	if resp["error"] == nil {
		t.Fatal("expected attach rejection for different clientId")
	}
}

func TestDaemon_SessionAttachReclaimPrunesPreviousHandlerCache(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found")
	}

	d, sockPath := testDaemon(t)
	defer d.Stop()

	conn1 := connectToDaemon(t, sockPath)
	defer conn1.Close()
	scanner1 := bufio.NewScanner(conn1)
	scanner1.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn1.SetReadDeadline(time.Now().Add(30 * time.Second))

	// Client1 creates and attaches a session.
	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.create",
		"params":  map[string]interface{}{"cwd": "/tmp", "command": mockBin},
	})
	resp := readResponseWithID(t, scanner1, 1)
	if resp["error"] != nil {
		t.Fatalf("session.create error: %v", resp["error"])
	}
	sessionID := resp["result"].(map[string]interface{})["sessionId"].(string)

	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.attach",
		"params": map[string]interface{}{
			"sessionId":    sessionID,
			"lastEventSeq": 0,
			"clientId":     "ios-app-1",
		},
	})
	resp = readResponseWithID(t, scanner1, 2)
	if resp["error"] != nil {
		t.Fatalf("session.attach error: %v", resp["error"])
	}

	// Client2 reclaims ownership of session A using same clientId.
	conn2 := connectToDaemon(t, sockPath)
	defer conn2.Close()
	scanner2 := bufio.NewScanner(conn2)
	scanner2.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn2.SetReadDeadline(time.Now().Add(30 * time.Second))

	sendJSON(conn2, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.attach",
		"params": map[string]interface{}{
			"sessionId":    sessionID,
			"lastEventSeq": 0,
			"clientId":     "ios-app-1",
		},
	})
	resp = readResponseWithID(t, scanner2, 1)
	if resp["error"] != nil {
		t.Fatalf("client2 reclaim attach error: %v", resp["error"])
	}

	// Old connection should no longer route session/load via stale local cache.
	sendJSON(conn1, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "session/load",
		"params": map[string]interface{}{
			"sessionId":  "external-session-id",
			"cwd":        "/tmp",
			"mcpServers": []interface{}{},
		},
	})
	resp = readResponseWithID(t, scanner1, 3)
	if resp["error"] == nil {
		t.Fatal("expected stale owner session/load rejection")
	}
	if !strings.Contains(fmt.Sprint(resp["error"]), "not attached to session: external-session-id") {
		t.Fatalf("unexpected stale owner session/load error: %v", resp["error"])
	}

	// Verify reclaim path emitted explicit stale-cache prune observability.
	sendJSON(conn2, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/logs",
		"params": map[string]interface{}{
			"count": 200,
		},
	})
	resp = readResponseWithID(t, scanner2, 2)
	if resp["error"] != nil {
		t.Fatalf("daemon/logs error: %v", resp["error"])
	}
	entries := resp["result"].(map[string]interface{})["entries"].([]interface{})
	foundPruneLog := false
	for _, raw := range entries {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		if !strings.Contains(fmt.Sprint(entry), "pruned stale attached proxy entry from previous owner") {
			continue
		}
		foundPruneLog = true
		break
	}
	if !foundPruneLog {
		t.Fatal("expected reclaim path to log stale attached proxy prune")
	}
}

func TestDaemon_SessionLoadUnknownSessionIDRoutesToSoleAttachedProxy(t *testing.T) {
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

	// Create and attach one managed session.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.create",
		"params":  map[string]interface{}{"cwd": "/tmp", "command": mockBin},
	})
	resp := readResponseWithID(t, scanner, 1)
	if resp["error"] != nil {
		t.Fatalf("session.create error: %v", resp["error"])
	}
	sessionID := resp["result"].(map[string]interface{})["sessionId"].(string)

	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.attach",
		"params":  map[string]interface{}{"sessionId": sessionID, "lastEventSeq": 0},
	})
	resp = readResponseWithID(t, scanner, 2)
	if resp["error"] != nil {
		t.Fatalf("session.attach error: %v", resp["error"])
	}

	// session/load with an unknown sessionId should route to the sole attached proxy.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "session/load",
		"params": map[string]interface{}{
			"sessionId":  "external-session-id",
			"cwd":        "/tmp",
			"mcpServers": []interface{}{},
		},
	})
	resp = readResponseWithID(t, scanner, 3)
	if resp["error"] != nil {
		t.Fatalf("session/load should route via fallback, got error: %v", resp["error"])
	}

	// The fallback must remain load-only; prompt for unknown sessionId is still rejected.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      4,
		"method":  "session/prompt",
		"params": map[string]interface{}{
			"sessionId": "external-session-id",
			"prompt": []map[string]interface{}{
				{"type": "text", "text": "should-fail"},
			},
		},
	})
	resp = readResponseWithID(t, scanner, 4)
	if resp["error"] == nil {
		t.Fatal("expected prompt rejection for unknown sessionId")
	}
	if !strings.Contains(fmt.Sprint(resp["error"]), "not attached to session: external-session-id") {
		t.Fatalf("unexpected prompt error: %v", resp["error"])
	}
}

func TestDaemon_IdleTimeoutRearmsWhileSessionBusy(t *testing.T) {
	mockBin := findMockBin(t)
	if mockBin == "" {
		t.Skip("mock-acp-server binary not found")
	}

	d, sockPath := testDaemonWithTimeout(t, 200*time.Millisecond)
	defer d.Stop()

	conn := connectToDaemon(t, sockPath)
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	conn.SetReadDeadline(time.Now().Add(30 * time.Second))

	// Create and attach session.
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "daemon/session.create",
		"params":  map[string]interface{}{"cwd": "/tmp", "command": mockBin},
	})
	resp := readJSONWithScanner(t, scanner)
	sessionID := resp["result"].(map[string]interface{})["sessionId"].(string)

	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "daemon/session.attach",
		"params":  map[string]interface{}{"sessionId": sessionID, "lastEventSeq": 0},
	})
	readJSONWithScanner(t, scanner) // attach response

	// Start a long-enough prompt (mock streams ~400ms total by default).
	sendJSON(conn, map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1001,
		"method":  "session/prompt",
		"params": map[string]interface{}{
			"sessionId": sessionID,
			"prompt":    []map[string]interface{}{{"type": "text", "text": "hello"}},
		},
	})

	// Wait for first streamed notification, then disconnect mid-prompt.
	for {
		msg := readJSONWithScanner(t, scanner)
		if msg["method"] != nil {
			break
		}
	}
	conn.Close()

	// Daemon should eventually stop once prompt completes and idleness is re-checked.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(sockPath); os.IsNotExist(err) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("daemon did not stop after idle timeout while no clients were connected")
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

func writeMockWrapperCommand(t *testing.T, path, mockBin, configuredListSessions string) string {
	t.Helper()
	content := fmt.Sprintf(
		"#!/bin/sh\nexport MOCK_LIST_SESSIONS=%q\nexec %q \"$@\"\n",
		configuredListSessions,
		mockBin,
	)
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatalf("write wrapper command %s: %v", path, err)
	}
	return path
}

func init() {
	// Suppress "unused import" for fmt if not used in all tests
	_ = fmt.Sprintf
}
