package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
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
			logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

			cfg := daemon.DefaultConfig()
			cfg.Logger = logger

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
