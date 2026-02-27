// mock_acp_server simulates claude-agent-acp for testing.
// It reads JSON-RPC from stdin and writes responses/notifications to stdout.
//
// Environment variables:
//
//	MOCK_PROMPT_DELAY  - delay in ms between streaming events (default 50)
//	MOCK_CRASH_AFTER   - crash after N events during prompt (0 = no crash)
//	MOCK_TOOL_CALL     - include a tool call in prompt response (1 = yes)
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"time"
)

var promptDelay = 50 * time.Millisecond
var crashAfter = 0
var includeToolCall = false
var omitCreatedFromList = false
var sessions []string

func init() {
	if v := os.Getenv("MOCK_PROMPT_DELAY"); v != "" {
		if ms, err := strconv.Atoi(v); err == nil {
			promptDelay = time.Duration(ms) * time.Millisecond
		}
	}
	if v := os.Getenv("MOCK_CRASH_AFTER"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			crashAfter = n
		}
	}
	if os.Getenv("MOCK_TOOL_CALL") == "1" {
		includeToolCall = true
	}
	if os.Getenv("MOCK_LIST_OMIT_CREATED") == "1" {
		omitCreatedFromList = true
	}
}

type jsonrpcMessage struct {
	JSONRPC string           `json:"jsonrpc"`
	ID      *json.RawMessage `json:"id,omitempty"`
	Method  string           `json:"method,omitempty"`
	Params  json.RawMessage  `json:"params,omitempty"`
	Result  json.RawMessage  `json:"result,omitempty"`
	Error   json.RawMessage  `json:"error,omitempty"`
}

var sessionCounter int

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 || line[0] != '{' {
			continue
		}

		var msg jsonrpcMessage
		if err := json.Unmarshal(line, &msg); err != nil {
			continue
		}

		switch msg.Method {
		case "initialize":
			handleInitialize(msg.ID)
		case "session/new":
			handleSessionNew(msg.ID, msg.Params)
		case "session/prompt":
			handleSessionPrompt(msg.ID, msg.Params)
		case "session/list":
			handleSessionList(msg.ID)
		case "session/load":
			handleSessionLoad(msg.ID, msg.Params)
		}
	}
}

func respond(id *json.RawMessage, result interface{}) {
	data, _ := json.Marshal(result)
	msg := jsonrpcMessage{
		JSONRPC: "2.0",
		ID:      id,
		Result:  data,
	}
	out, _ := json.Marshal(msg)
	fmt.Fprintln(os.Stdout, string(out))
}

func notify(method string, params interface{}) {
	data, _ := json.Marshal(params)
	msg := jsonrpcMessage{
		JSONRPC: "2.0",
		Method:  method,
		Params:  json.RawMessage(data),
	}
	out, _ := json.Marshal(msg)
	fmt.Fprintln(os.Stdout, string(out))
}

func handleInitialize(id *json.RawMessage) {
	respond(id, map[string]interface{}{
		"protocolVersion": 1,
		"serverCapabilities": map[string]interface{}{
			"prompts": true,
		},
		"serverInfo": map[string]interface{}{
			"name":    "mock-acp-server",
			"version": "0.1.0",
		},
	})
}

func handleSessionNew(id *json.RawMessage, params json.RawMessage) {
	sessionCounter++
	sessionID := fmt.Sprintf("mock-sess-%04d", sessionCounter)
	sessions = append(sessions, sessionID)

	respond(id, map[string]interface{}{
		"sessionId": sessionID,
	})

	// Send system message
	notify("session/update", map[string]interface{}{
		"sessionId": sessionID,
		"update": map[string]interface{}{
			"sessionUpdate": "agent_message",
			"content": map[string]interface{}{
				"type": "text",
				"text": "Session started. How can I help you?",
			},
		},
	})
}

func handleSessionPrompt(id *json.RawMessage, params json.RawMessage) {
	var p struct {
		SessionID string `json:"sessionId"`
	}
	json.Unmarshal(params, &p)

	eventCount := 0
	sendEvent := func(update map[string]interface{}) bool {
		eventCount++
		if crashAfter > 0 && eventCount > crashAfter {
			os.Exit(1)
		}
		notify("session/update", map[string]interface{}{
			"sessionId": p.SessionID,
			"update":    update,
		})
		time.Sleep(promptDelay)
		return true
	}

	// Stream text chunks
	chunks := []string{"Hello", "! I'm ", "the mock ", "ACP server", ". How can ", "I help you?"}
	for _, chunk := range chunks {
		sendEvent(map[string]interface{}{
			"sessionUpdate": "agent_message_chunk",
			"content": map[string]interface{}{
				"type": "text",
				"text": chunk,
			},
		})
	}

	if includeToolCall {
		// Tool call start
		sendEvent(map[string]interface{}{
			"sessionUpdate": "tool_call",
			"toolCallId":    "tool-1",
			"title":         "Read",
			"rawInput":      map[string]interface{}{"file_path": "/tmp/test.txt"},
		})

		// Tool call update with output
		sendEvent(map[string]interface{}{
			"sessionUpdate": "tool_call_update",
			"toolCallId":    "tool-1",
			"title":         "Read",
			"status":        "completed",
			"rawOutput":     "file contents here",
		})

		// More text after tool call
		sendEvent(map[string]interface{}{
			"sessionUpdate": "agent_message_chunk",
			"content": map[string]interface{}{
				"type": "text",
				"text": "\nI read the file for you.",
			},
		})
	}

	// Full message
	sendEvent(map[string]interface{}{
		"sessionUpdate": "agent_message",
		"content": map[string]interface{}{
			"type": "text",
			"text": "Hello! I'm the mock ACP server. How can I help you?",
		},
	})

	// Prompt complete
	sendEvent(map[string]interface{}{
		"sessionUpdate": "prompt_complete",
		"stopReason":    "end_turn",
	})

	respond(id, map[string]interface{}{
		"stopReason": "end_turn",
	})
}

func handleSessionList(id *json.RawMessage) {
	items := make([]map[string]interface{}, 0, len(sessions))
	if !omitCreatedFromList {
		for _, sid := range sessions {
			items = append(items, map[string]interface{}{
				"sessionId": sid,
			})
		}
	}

	respond(id, map[string]interface{}{
		"sessions": items,
	})
}

func handleSessionLoad(id *json.RawMessage, params json.RawMessage) {
	respond(id, map[string]interface{}{})
}
