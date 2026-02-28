package attach

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Run connects to the daemon socket, bridging stdin/stdout.
// If the daemon is not running, starts it first.
func Run() error {
	home, _ := os.UserHomeDir()
	sockPath := filepath.Join(home, ".opencan", "daemon.sock")

	// Try to connect
	conn, err := net.DialTimeout("unix", sockPath, 2*time.Second)
	if err != nil {
		// Daemon not running — start it
		if err := startDaemon(); err != nil {
			return fmt.Errorf("start daemon: %w", err)
		}
		// Retry with backoff
		conn, err = connectWithRetry(sockPath, 5*time.Second)
		if err != nil {
			return fmt.Errorf("connect to daemon after start: %w", err)
		}
	}
	defer conn.Close()

	// Signal to the iOS app that we're connected and ready for JSON-RPC.
	// This must be a valid JSON-RPC notification so the framer picks it up.
	fmt.Fprintln(os.Stdout, `{"jsonrpc":"2.0","method":"daemon/attached","params":{}}`)

	// Bridge stdin/stdout <-> socket
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// stdin -> socket
	go func() {
		io.Copy(conn, os.Stdin)
		cancel()
	}()

	// socket -> stdout
	go func() {
		io.Copy(os.Stdout, conn)
		cancel()
	}()

	<-ctx.Done()
	return nil
}

// startDaemon launches the daemon as a background process.
func startDaemon() error {
	exePath, err := os.Executable()
	if err != nil {
		return err
	}

	cmd := exec.Command(exePath, "start")

	if err := cmd.Start(); err != nil {
		return err
	}

	// Release the child process so it continues after we exit
	cmd.Process.Release()
	return nil
}

// connectWithRetry attempts to connect to the socket with exponential backoff.
func connectWithRetry(sockPath string, timeout time.Duration) (net.Conn, error) {
	deadline := time.Now().Add(timeout)
	delay := 50 * time.Millisecond

	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("unix", sockPath, 1*time.Second)
		if err == nil {
			return conn, nil
		}
		time.Sleep(delay)
		delay = min(delay*2, 500*time.Millisecond)
	}
	return nil, fmt.Errorf("timeout connecting to %s", sockPath)
}

// IsDaemonRunning checks if the daemon is running by reading the PID file
// and checking if the process exists.
func IsDaemonRunning() (bool, int) {
	home, _ := os.UserHomeDir()
	pidFile := filepath.Join(home, ".opencan", "daemon.pid")

	data, err := os.ReadFile(pidFile)
	if err != nil {
		return false, 0
	}

	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return false, 0
	}

	// Check if process exists
	process, err := os.FindProcess(pid)
	if err != nil {
		return false, 0
	}

	// Signal 0 checks if process exists without sending a signal
	err = process.Signal(syscall.Signal(0))
	if err != nil {
		return false, 0
	}

	return true, pid
}

// StopDaemon sends SIGTERM to the daemon process.
func StopDaemon() error {
	running, pid := IsDaemonRunning()
	if !running {
		return fmt.Errorf("daemon is not running")
	}

	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Signal(syscall.SIGTERM)
}
