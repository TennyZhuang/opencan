package daemon

import (
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/nightlyone/lockfile"
)

// Daemon is the main daemon process that listens for client connections.
type Daemon struct {
	socketPath string
	pidFile    string
	pidLock    *lockfile.Lockfile
	listener   net.Listener
	sessions   *SessionManager
	logger     *slog.Logger

	clientsMu sync.Mutex
	clients   map[*ClientHandler]struct{}

	idleTimeout time.Duration
	timerMu     sync.Mutex
	idleTimer   *time.Timer
	stopCh      chan struct{}
}

// Config holds daemon configuration.
type Config struct {
	SocketPath  string
	PIDFile     string
	IdleTimeout time.Duration
	Logger      *slog.Logger
}

// DefaultConfig returns the default daemon configuration.
func DefaultConfig() Config {
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, ".opencan")
	return Config{
		SocketPath:  filepath.Join(dir, "daemon.sock"),
		PIDFile:     filepath.Join(dir, "daemon.pid"),
		IdleTimeout: 30 * time.Minute,
		Logger:      slog.Default(),
	}
}

// New creates a new Daemon with the given config.
func New(cfg Config) *Daemon {
	return &Daemon{
		socketPath:  cfg.SocketPath,
		pidFile:     cfg.PIDFile,
		sessions:    NewSessionManager(cfg.Logger),
		logger:      cfg.Logger.With("component", "daemon"),
		clients:     make(map[*ClientHandler]struct{}),
		idleTimeout: cfg.IdleTimeout,
		stopCh:      make(chan struct{}),
	}
}

// Run starts the daemon. Blocks until Stop() is called or idle timeout expires.
func (d *Daemon) Run() error {
	// Ensure directory exists
	dir := filepath.Dir(d.socketPath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return fmt.Errorf("create dir %s: %w", dir, err)
	}

	pidLock, err := lockfile.New(d.pidFile)
	if err != nil {
		return fmt.Errorf("create pid lock: %w", err)
	}
	if err := pidLock.TryLock(); err != nil {
		return fmt.Errorf("acquire pid lock: %w", err)
	}
	d.pidLock = &pidLock

	// Remove stale socket
	os.Remove(d.socketPath)

	// Listen
	listener, err := net.Listen("unix", d.socketPath)
	if err != nil {
		if unlockErr := d.pidLock.Unlock(); unlockErr != nil {
			d.logger.Warn("failed to release PID lock", "error", unlockErr)
		}
		d.pidLock = nil
		return fmt.Errorf("listen %s: %w", d.socketPath, err)
	}
	d.listener = listener

	// Set socket permissions
	os.Chmod(d.socketPath, 0600)

	d.logger.Info("daemon started", "socket", d.socketPath, "pid", os.Getpid())

	// Start idle timer
	d.resetIdleTimer()

	// Accept connections
	go d.acceptLoop()

	// Wait for stop signal
	<-d.stopCh

	d.cleanup()
	return nil
}

// Stop signals the daemon to shut down.
func (d *Daemon) Stop() {
	select {
	case <-d.stopCh:
	default:
		close(d.stopCh)
	}
}

// SocketPath returns the daemon's socket path.
func (d *Daemon) SocketPath() string {
	return d.socketPath
}

func (d *Daemon) acceptLoop() {
	for {
		conn, err := d.listener.Accept()
		if err != nil {
			select {
			case <-d.stopCh:
				return
			default:
				d.logger.Error("accept error", "error", err)
				continue
			}
		}

		handler := NewClientHandler(conn, d, d.logger)
		d.clientsMu.Lock()
		d.clients[handler] = struct{}{}
		d.clientsMu.Unlock()
		d.resetIdleTimer()

		go handler.Serve()
	}
}

func (d *Daemon) clientDisconnected(h *ClientHandler) {
	d.clientsMu.Lock()
	delete(d.clients, h)
	clientCount := len(d.clients)
	d.clientsMu.Unlock()

	d.logger.Info("client disconnected", "remainingClients", clientCount)

	if clientCount == 0 && d.sessions.IsIdle() {
		d.resetIdleTimer()
	}
}

func (d *Daemon) resetIdleTimer() {
	d.timerMu.Lock()
	defer d.timerMu.Unlock()

	if d.idleTimer != nil {
		d.idleTimer.Stop()
	}
	d.idleTimer = time.AfterFunc(d.idleTimeout, func() {
		d.clientsMu.Lock()
		clientCount := len(d.clients)
		d.clientsMu.Unlock()

		if clientCount == 0 && d.sessions.IsIdle() {
			d.logger.Info("idle timeout reached, shutting down")
			d.Stop()
			return
		}

		// Timer is one-shot; keep polling until the daemon actually becomes idle.
		select {
		case <-d.stopCh:
			return
		default:
			d.resetIdleTimer()
		}
	})
}

func (d *Daemon) cleanup() {
	d.logger.Info("cleaning up")
	if d.listener != nil {
		d.listener.Close()
	}
	d.timerMu.Lock()
	if d.idleTimer != nil {
		d.idleTimer.Stop()
	}
	d.timerMu.Unlock()
	os.Remove(d.socketPath)
	if d.pidLock != nil {
		if err := d.pidLock.Unlock(); err != nil {
			d.logger.Warn("failed to release PID lock", "error", err)
		}
		d.pidLock = nil
	}
}

// Status returns a summary of the daemon state.
func (d *Daemon) Status() map[string]interface{} {
	d.clientsMu.Lock()
	clientCount := len(d.clients)
	d.clientsMu.Unlock()

	return map[string]interface{}{
		"pid":      os.Getpid(),
		"socket":   d.socketPath,
		"clients":  clientCount,
		"sessions": d.sessions.ListSessions(),
	}
}
