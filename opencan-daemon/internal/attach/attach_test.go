package attach

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestConnectWithRetrySucceedsWhenSocketAppears(t *testing.T) {
	tmpDir, err := os.MkdirTemp("/tmp", "ocd-attach-*")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(tmpDir) })
	sockPath := filepath.Join(tmpDir, "daemon.sock")

	ready := make(chan error, 1)
	go func() {
		time.Sleep(75 * time.Millisecond)
		ln, err := net.Listen("unix", sockPath)
		if err != nil {
			ready <- err
			return
		}
		defer ln.Close()
		ready <- nil

		conn, err := ln.Accept()
		if err == nil {
			conn.Close()
		}
	}()

	if err := <-ready; err != nil {
		t.Fatalf("listen failed: %v", err)
	}

	conn, err := connectWithRetry(sockPath, 2*time.Second)
	if err != nil {
		t.Fatalf("connectWithRetry should succeed, got %v", err)
	}
	conn.Close()
}

func TestConnectWithRetryTimesOut(t *testing.T) {
	tmpDir, err := os.MkdirTemp("/tmp", "ocd-attach-*")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(tmpDir) })
	sockPath := filepath.Join(tmpDir, "missing.sock")

	_, err = connectWithRetry(sockPath, 200*time.Millisecond)
	if err == nil {
		t.Fatal("expected timeout error")
	}
	if !strings.Contains(err.Error(), "timeout connecting") {
		t.Fatalf("expected timeout error, got %v", err)
	}
}

func TestIsDaemonRunningHandlesMalformedPID(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	pidFile := filepath.Join(home, ".opencan", "daemon.pid")
	if err := os.MkdirAll(filepath.Dir(pidFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pidFile, []byte("not-a-pid"), 0o600); err != nil {
		t.Fatal(err)
	}

	running, pid := IsDaemonRunning()
	if running || pid != 0 {
		t.Fatalf("expected malformed pid to report not running, got running=%v pid=%d", running, pid)
	}
}

func TestStopDaemonReturnsErrorWhenNotRunning(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	err := StopDaemon()
	if err == nil {
		t.Fatal("expected error when daemon is not running")
	}
	if !strings.Contains(err.Error(), "not running") {
		t.Fatalf("unexpected error: %v", err)
	}
}
