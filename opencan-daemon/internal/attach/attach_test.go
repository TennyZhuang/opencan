package attach

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
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

func TestIsDaemonRunningRecognizesLiveProcessPID(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	pidFile := filepath.Join(home, ".opencan", "daemon.pid")
	if err := os.MkdirAll(filepath.Dir(pidFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pidFile, []byte(strconv.Itoa(os.Getpid())), 0o600); err != nil {
		t.Fatal(err)
	}

	running, pid := IsDaemonRunning()
	if !running {
		t.Fatal("expected current process pid to be considered running")
	}
	if pid != os.Getpid() {
		t.Fatalf("expected pid %d, got %d", os.Getpid(), pid)
	}
}

func TestIsDaemonRunningHandlesStalePID(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	pidFile := filepath.Join(home, ".opencan", "daemon.pid")
	if err := os.MkdirAll(filepath.Dir(pidFile), 0o700); err != nil {
		t.Fatal(err)
	}

	// Create a real PID then terminate it so the PID file points to a dead process.
	cmd := exec.Command("sleep", "10")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pid := cmd.Process.Pid
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = cmd.Wait()

	if err := os.WriteFile(pidFile, []byte(strconv.Itoa(pid)), 0o600); err != nil {
		t.Fatal(err)
	}

	running, gotPID := IsDaemonRunning()
	if running || gotPID != 0 {
		t.Fatalf("expected stale pid to report not running, got running=%v pid=%d", running, gotPID)
	}
}

func TestStopDaemonSignalsRunningProcess(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	pidFile := filepath.Join(home, ".opencan", "daemon.pid")
	if err := os.MkdirAll(filepath.Dir(pidFile), 0o700); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command("sleep", "10")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})

	if err := os.WriteFile(pidFile, []byte(strconv.Itoa(cmd.Process.Pid)), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := StopDaemon(); err != nil {
		t.Fatalf("StopDaemon returned error: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	select {
	case <-time.After(2 * time.Second):
		t.Fatal("expected process to exit after StopDaemon")
	case err := <-done:
		// Exit code is platform-dependent after SIGTERM; only require process exit.
		if err == nil {
			return
		}
		if !strings.Contains(err.Error(), "signal") && !strings.Contains(err.Error(), "exit status") {
			t.Fatalf("unexpected wait error: %v", err)
		}
	}
}
