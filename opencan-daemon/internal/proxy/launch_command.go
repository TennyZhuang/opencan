package proxy

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// LaunchCommand is a parsed ACP launch command.
type LaunchCommand struct {
	Executable string
	Args       []string
	Env        []string
}

// ParseLaunchCommand parses a launcher command string into executable, args, and env assignments.
// Supports commands like:
//   - "claude-agent-acp"
//   - "npx @zed-industries/codex-acp"
//   - "FOO=bar codex-acp --verbose"
func ParseLaunchCommand(raw string) (LaunchCommand, error) {
	tokens := strings.Fields(strings.TrimSpace(raw))
	if len(tokens) == 0 {
		return LaunchCommand{}, fmt.Errorf("empty command")
	}

	cmd := LaunchCommand{}
	for len(tokens) > 0 && isEnvAssignmentToken(tokens[0]) {
		cmd.Env = append(cmd.Env, tokens[0])
		tokens = tokens[1:]
	}
	if len(tokens) == 0 {
		return LaunchCommand{}, fmt.Errorf("missing executable")
	}

	cmd.Executable = tokens[0]
	if len(tokens) > 1 {
		cmd.Args = append([]string{}, tokens[1:]...)
	}
	return cmd, nil
}

// BuildExecCommand constructs an *exec.Cmd from a parsed launcher command.
func BuildExecCommand(raw string) (*exec.Cmd, LaunchCommand, error) {
	parsed, err := ParseLaunchCommand(raw)
	if err != nil {
		return nil, LaunchCommand{}, err
	}

	cmd := exec.Command(parsed.Executable, parsed.Args...)
	if len(parsed.Env) > 0 {
		cmd.Env = append(os.Environ(), parsed.Env...)
	}
	return cmd, parsed, nil
}

func isEnvAssignmentToken(token string) bool {
	eq := strings.IndexByte(token, '=')
	if eq <= 0 {
		return false
	}
	key := token[:eq]
	for i, r := range key {
		if i == 0 {
			if !(r == '_' || (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z')) {
				return false
			}
			continue
		}
		if !(r == '_' || (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')) {
			return false
		}
	}
	return true
}
