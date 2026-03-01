package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/anthropics/opencan-daemon/internal/attach"
	"github.com/anthropics/opencan-daemon/internal/daemon"
	godaemon "github.com/sevlyar/go-daemon"
	"github.com/spf13/cobra"
)

var version = "dev"

func main() {
	root := &cobra.Command{
		Use:   "opencan-daemon",
		Short: "OpenCAN daemon — persistent ACP process manager",
	}

	root.AddCommand(startCmd())
	root.AddCommand(attachCmd())
	root.AddCommand(statusCmd())
	root.AddCommand(stopCmd())
	root.AddCommand(versionCmd())

	if err := root.Execute(); err != nil {
		os.Exit(1)
	}
}

func startCmd() *cobra.Command {
	var foreground bool
	var verbose bool

	cmd := &cobra.Command{
		Use:   "start",
		Short: "Start the daemon",
		RunE: func(cmd *cobra.Command, args []string) error {
			var daemonCtx *godaemon.Context
			if !foreground {
				daemonCtx = &godaemon.Context{
					// Re-exec as foreground child so daemon.Run stays unchanged.
					Args: daemonizedArgs(verbose),
				}
				child, err := daemonCtx.Reborn()
				if err != nil {
					return fmt.Errorf("daemonize: %w", err)
				}
				if child != nil {
					// Parent exits successfully; child continues in foreground mode.
					return nil
				}
				defer func() {
					_ = daemonCtx.Release()
				}()
			}

			level := slog.LevelInfo
			if verbose {
				level = slog.LevelDebug
			}
			logWriter, closeWriter, err := openLogWriter(foreground && !godaemon.WasReborn())
			if err != nil {
				return err
			}
			defer closeWriter()

			logBuffer := daemon.NewLogRingBuffer(2000)
			innerHandler := slog.NewJSONHandler(logWriter, &slog.HandlerOptions{Level: level})
			logger := slog.New(daemon.NewBufferingHandler(innerHandler, logBuffer))

			cfg := daemon.DefaultConfig()
			cfg.Logger = logger
			cfg.LogBuffer = logBuffer

			d := daemon.New(cfg)

			// Handle signals
			sigCh := make(chan os.Signal, 1)
			signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
			go func() {
				<-sigCh
				logger.Info("received shutdown signal")
				d.Stop()
			}()

			return d.Run()
		},
	}

	cmd.Flags().BoolVar(&foreground, "foreground", false, "Run in foreground (don't daemonize)")
	cmd.Flags().BoolVar(&verbose, "verbose", false, "Enable debug logging")
	return cmd
}

func daemonizedArgs(verbose bool) []string {
	args := []string{os.Args[0], "start", "--foreground"}
	if verbose {
		args = append(args, "--verbose")
	}
	return args
}

func attachCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "attach",
		Short: "Connect to daemon, bridging stdin/stdout",
		RunE: func(cmd *cobra.Command, args []string) error {
			return attach.Run()
		},
	}
}

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show daemon status",
		RunE: func(cmd *cobra.Command, args []string) error {
			running, pid := attach.IsDaemonRunning()
			if !running {
				fmt.Println("Daemon is not running")
				return nil
			}

			status := map[string]interface{}{
				"running": true,
				"pid":     pid,
			}
			data, _ := json.MarshalIndent(status, "", "  ")
			fmt.Println(string(data))
			return nil
		},
	}
}

func stopCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "stop",
		Short: "Stop the daemon",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := attach.StopDaemon(); err != nil {
				return err
			}
			fmt.Println("Daemon stopped")
			return nil
		},
	}
}

func versionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Printf("opencan-daemon %s\n", version)
		},
	}
}

func openLogWriter(includeStderr bool) (io.Writer, func(), error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, nil, fmt.Errorf("resolve home directory: %w", err)
	}
	logDir := filepath.Join(home, ".opencan")
	if err := os.MkdirAll(logDir, 0700); err != nil {
		return nil, nil, fmt.Errorf("create log directory: %w", err)
	}

	logPath := filepath.Join(logDir, "daemon.log")
	if err := rotateLogIfNeeded(logPath, 10*1024*1024); err != nil {
		return nil, nil, err
	}

	file, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return nil, nil, fmt.Errorf("open daemon log file: %w", err)
	}

	writer := io.Writer(file)
	if includeStderr {
		writer = io.MultiWriter(os.Stderr, file)
	}
	return writer, func() { _ = file.Close() }, nil
}

func rotateLogIfNeeded(path string, maxSize int64) error {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("stat daemon log: %w", err)
	}
	if info.Size() <= maxSize {
		return nil
	}
	prevPath := path + ".prev"
	_ = os.Remove(prevPath)
	if err := os.Rename(path, prevPath); err != nil {
		return fmt.Errorf("rotate daemon log: %w", err)
	}
	return nil
}
