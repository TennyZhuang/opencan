package daemon

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os/exec"
	"sync"
	"time"

	"github.com/anthropics/opencan-daemon/internal/protocol"
	"github.com/anthropics/opencan-daemon/internal/proxy"
)

type AgentProbeRequest struct {
	ID      string `json:"id"`
	Command string `json:"command"`
}

type AgentProbeResult struct {
	ID              string `json:"id"`
	Command         string `json:"command"`
	Available       bool   `json:"available"`
	ResolvedCommand string `json:"resolvedCommand,omitempty"`
	Reason          string `json:"reason,omitempty"`
}

func ProbeAgentCommands(requests []AgentProbeRequest) []AgentProbeResult {
	results := make([]AgentProbeResult, len(requests))

	var wg sync.WaitGroup
	for i, req := range requests {
		wg.Add(1)
		go func(i int, req AgentProbeRequest) {
			defer wg.Done()
			results[i] = probeAgentCommand(req)
		}(i, req)
	}
	wg.Wait()

	return results
}

func probeAgentCommand(req AgentProbeRequest) AgentProbeResult {
	result := AgentProbeResult{
		ID:      req.ID,
		Command: req.Command,
	}

	cmd, parsed, err := proxy.BuildExecCommand(req.Command)
	if err != nil {
		result.Reason = "invalid command"
		return result
	}

	resolved, err := resolveExecutable(parsed.Executable)
	if err != nil {
		result.Reason = "not found"
		return result
	}

	result.ResolvedCommand = resolved
	if err := checkACPHandshake(cmd, 8*time.Second); err != nil {
		result.Reason = fmt.Sprintf("handshake failed: %s", err.Error())
		return result
	}

	result.Available = true
	return result
}

func resolveExecutable(executable string) (string, error) {
	return exec.LookPath(executable)
}

func checkACPHandshake(cmd *exec.Cmd, timeout time.Duration) error {
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("stdin: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start: %w", err)
	}

	done := make(chan error, 1)
	go func() {
		defer close(done)
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 64*1024), 64*1024)
		for scanner.Scan() {
			msg, parseErr := protocol.ParseLine(scanner.Bytes())
			if parseErr != nil || msg == nil {
				continue
			}
			if msg.ID == nil || msg.ID.IntValue() != 1 {
				continue
			}
			if msg.IsError() {
				done <- fmt.Errorf("initialize error: %s", msg.Error.Message)
				return
			}
			if msg.IsResponse() {
				done <- nil
				return
			}
		}
		if err := scanner.Err(); err != nil {
			done <- err
			return
		}
		done <- fmt.Errorf("no initialize response")
	}()

	params, _ := json.Marshal(map[string]interface{}{
		"protocolVersion":    1,
		"clientCapabilities": map[string]interface{}{},
		"clientInfo": map[string]interface{}{
			"name":    "opencan-daemon-probe",
			"title":   "OpenCAN Daemon Probe",
			"version": "0.1.0",
		},
	})
	request := protocol.NewRequest(protocol.IntID(1), protocol.MethodInitialize, params)
	line, err := protocol.SerializeLine(request)
	if err != nil {
		terminateProbeProcess(cmd)
		return fmt.Errorf("encode initialize: %w", err)
	}
	if _, err := stdin.Write(line); err != nil {
		terminateProbeProcess(cmd)
		return fmt.Errorf("write initialize: %w", err)
	}
	_ = stdin.Close()

	select {
	case err := <-done:
		terminateProbeProcess(cmd)
		return err
	case <-time.After(timeout):
		terminateProbeProcess(cmd)
		return fmt.Errorf("timeout")
	}
}

func terminateProbeProcess(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Kill()
	_ = cmd.Wait()
}
