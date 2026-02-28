package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
	results := make([]AgentProbeResult, 0, len(requests))
	for _, req := range requests {
		results = append(results, probeAgentCommand(req))
	}
	return results
}

func probeAgentCommand(req AgentProbeRequest) AgentProbeResult {
	result := AgentProbeResult{
		ID:      req.ID,
		Command: req.Command,
	}
	executable, ok := extractExecutable(req.Command)
	if !ok {
		result.Reason = "missing executable"
		return result
	}

	resolved, err := resolveExecutable(executable)
	if err != nil {
		result.Reason = "not found"
		return result
	}

	result.Available = true
	result.ResolvedCommand = resolved
	return result
}

func extractExecutable(command string) (string, bool) {
	tokens := strings.Fields(strings.TrimSpace(command))
	if len(tokens) == 0 {
		return "", false
	}

	for _, token := range tokens {
		// Skip shell-style env assignments (e.g. "FOO=bar cmd").
		if strings.Contains(token, "=") &&
			!strings.HasPrefix(token, "/") &&
			!strings.HasPrefix(token, ".") &&
			!strings.HasPrefix(token, "-") {
			continue
		}
		return token, true
	}

	return "", false
}

func resolveExecutable(executable string) (string, error) {
	if strings.Contains(executable, "/") {
		info, err := os.Stat(executable)
		if err != nil {
			return "", err
		}
		if info.IsDir() || info.Mode().Perm()&0111 == 0 {
			return "", os.ErrNotExist
		}
		return filepath.Clean(executable), nil
	}
	return exec.LookPath(executable)
}
