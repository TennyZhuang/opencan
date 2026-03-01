package proxy

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"time"

	"github.com/anthropics/opencan-daemon/internal/protocol"
)

// ProbeLoadableSessionsForCWD discovers loadable sessions without creating a daemon-managed session.
// It launches an ACP command, performs initialize, then calls session/list.
func ProbeLoadableSessionsForCWD(command, cwd string, timeout time.Duration, logger *slog.Logger) ([]LoadableSession, error) {
	if timeout <= 0 {
		timeout = 1200 * time.Millisecond
	}

	cmd, _, err := BuildExecCommand(command)
	if err != nil {
		return nil, fmt.Errorf("parse command: %w", err)
	}
	if cwd != "" {
		cmd.Dir = cwd
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, fmt.Errorf("stdout pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return nil, fmt.Errorf("start process: %w", err)
	}
	defer func() {
		_ = stdin.Close()
		_ = stdout.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)

	initParams, _ := json.Marshal(map[string]interface{}{
		"protocolVersion":    1,
		"clientCapabilities": map[string]interface{}{},
		"clientInfo": map[string]interface{}{
			"name":    "opencan-daemon-probe",
			"title":   "OpenCAN Daemon Probe",
			"version": "0.1.0",
		},
	})
	if err := writeProbeRequest(stdin, protocol.NewRequest(protocol.IntID(1), protocol.MethodInitialize, initParams)); err != nil {
		return nil, fmt.Errorf("send initialize: %w", err)
	}
	initResp, err := waitForProbeResponse(scanner, 1, timeout)
	if err != nil {
		return nil, fmt.Errorf("initialize: %w", err)
	}
	if initResp.Error != nil {
		return nil, fmt.Errorf("initialize error: %s", initResp.Error.Message)
	}

	params := map[string]interface{}{}
	if cwd != "" {
		params["cwd"] = cwd
	}
	listParams, _ := json.Marshal(params)
	if err := writeProbeRequest(stdin, protocol.NewRequest(protocol.IntID(2), protocol.MethodSessionList, listParams)); err != nil {
		return nil, fmt.Errorf("send session/list: %w", err)
	}
	listResp, err := waitForProbeResponse(scanner, 2, timeout)
	if err != nil {
		return nil, fmt.Errorf("session/list: %w", err)
	}
	if listResp.Error != nil {
		return nil, fmt.Errorf("session/list error: %s", listResp.Error.Message)
	}

	sessions, err := parseLoadableSessionsResult(listResp.Result)
	if err != nil {
		return nil, err
	}

	if logger != nil {
		logger.Debug("probe session/list succeeded", "command", command, "cwd", cwd, "sessions", len(sessions))
	}
	return sessions, nil
}

func writeProbeRequest(w io.Writer, msg *protocol.Message) error {
	data, err := protocol.SerializeLine(msg)
	if err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

func waitForProbeResponse(scanner *bufio.Scanner, expectedID int64, timeout time.Duration) (*protocol.Message, error) {
	type result struct {
		msg *protocol.Message
		err error
	}
	resultCh := make(chan result, 1)
	go func() {
		for scanner.Scan() {
			msg, err := protocol.ParseLine(scanner.Bytes())
			if err != nil || msg == nil {
				continue
			}
			if (msg.IsResponse() || msg.IsError()) && msg.ID != nil && msg.ID.IntValue() == expectedID {
				resultCh <- result{msg: msg}
				return
			}
		}
		if err := scanner.Err(); err != nil {
			resultCh <- result{err: err}
			return
		}
		resultCh <- result{err: io.EOF}
	}()

	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case r := <-resultCh:
		return r.msg, r.err
	case <-timer.C:
		return nil, fmt.Errorf("request timed out waiting for id %d", expectedID)
	}
}
