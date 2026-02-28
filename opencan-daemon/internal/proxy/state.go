package proxy

import "encoding/json"

// SessionState represents the lifecycle state of an ACP session.
type SessionState int

const (
	StateStarting  SessionState = iota // ACP process starting, running initialize + session/new
	StateIdle                          // Waiting for prompt
	StatePrompting                     // Executing a prompt
	StateDraining                      // Client disconnected, waiting for prompt to complete
	StateCompleted                     // Drain complete, prompt finished while client was away
	StateDead                          // ACP process exited
	StateExternal                      // Session exists on disk but not managed by daemon
)

var stateNames = map[SessionState]string{
	StateStarting:  "starting",
	StateIdle:      "idle",
	StatePrompting: "prompting",
	StateDraining:  "draining",
	StateCompleted: "completed",
	StateDead:      "dead",
	StateExternal:  "external",
}

func (s SessionState) String() string {
	if name, ok := stateNames[s]; ok {
		return name
	}
	return "unknown"
}

func (s SessionState) MarshalJSON() ([]byte, error) {
	return json.Marshal(s.String())
}
