// mock_acp_server simulates ACP agent adapters for testing.
// It reads JSON-RPC from stdin and writes responses/notifications to stdout.
//
// Environment variables:
//
//	MOCK_PROMPT_DELAY  - delay in ms between streaming events (default 50)
//	MOCK_CRASH_AFTER   - crash after N events during prompt (0 = no crash)
//	MOCK_TOOL_CALL     - include a tool call in prompt response (1 = yes)
//	MOCK_OMIT_PROMPT_COMPLETE - skip prompt_complete notification (1 = yes)
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

var promptDelay = 50 * time.Millisecond
var crashAfter = 0
var includeToolCall = false
var omitPromptComplete = false
var omitCreatedFromList = false
var loadErrorDetails = ""
var sessions []string
var configuredListSessions []string
var sessionRecords = map[string]sessionRecord{}

type sessionRecord struct {
	CWD       string
	Title     string
	UpdatedAt string
}

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
	if os.Getenv("MOCK_OMIT_PROMPT_COMPLETE") == "1" {
		omitPromptComplete = true
	}
	if os.Getenv("MOCK_LIST_OMIT_CREATED") == "1" {
		omitCreatedFromList = true
	}
	if v := os.Getenv("MOCK_SESSION_LOAD_ERROR"); v != "" {
		loadErrorDetails = strings.TrimSpace(v)
	}
	if v := os.Getenv("MOCK_LIST_SESSIONS"); v != "" {
		for _, token := range strings.Split(v, ",") {
			id := strings.TrimSpace(token)
			if id == "" {
				continue
			}
			configuredListSessions = append(configuredListSessions, id)
			upsertSessionRecord(id, "/tmp/mock-workspace")
		}
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
		case "session/cancel":
			respond(msg.ID, map[string]interface{}{})
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

func respondError(id *json.RawMessage, code int, message string, data interface{}) {
	payload, _ := json.Marshal(map[string]interface{}{
		"code":    code,
		"message": message,
		"data":    data,
	})
	msg := jsonrpcMessage{
		JSONRPC: "2.0",
		ID:      id,
		Error:   payload,
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
		"agentCapabilities": map[string]interface{}{
			"loadSession": true,
			"promptCapabilities": map[string]interface{}{
				"image":           true,
				"embeddedContext": true,
			},
			"sessionCapabilities": map[string]interface{}{
				"list": map[string]interface{}{},
			},
		},
		"agentInfo": map[string]interface{}{
			"name":    "mock-acp-server",
			"title":   "Mock ACP Server",
			"version": "0.2.0",
		},
	})
}

func handleSessionNew(id *json.RawMessage, params json.RawMessage) {
	var payload struct {
		CWD string `json:"cwd"`
	}
	_ = json.Unmarshal(params, &payload)

	sessionCounter++
	sessionID := fmt.Sprintf("mock-sess-%04d", sessionCounter)
	sessions = append(sessions, sessionID)
	upsertSessionRecord(sessionID, payload.CWD)

	respond(id, map[string]interface{}{
		"sessionId":     sessionID,
		"modes":         mockModes(),
		"models":        mockModels(),
		"configOptions": mockConfigOptions(),
	})

	sendSessionMetadataUpdates(sessionID)

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
	_ = json.Unmarshal(params, &p)

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
		sendEvent(map[string]interface{}{
			"sessionUpdate": "tool_call",
			"toolCallId":    "tool-1",
			"title":         "Read",
			"kind":          "read",
			"status":        "pending",
			"rawInput":      map[string]interface{}{"file_path": "/tmp/test.txt"},
		})

		sendEvent(map[string]interface{}{
			"sessionUpdate": "tool_call_update",
			"toolCallId":    "tool-1",
			"title":         "Read",
			"status":        "in_progress",
		})

		sendEvent(map[string]interface{}{
			"sessionUpdate": "tool_call_update",
			"toolCallId":    "tool-1",
			"title":         "Read",
			"status":        "completed",
			"rawOutput": []map[string]interface{}{{
				"type": "text",
				"text": "file contents here",
			}},
		})

		sendEvent(map[string]interface{}{
			"sessionUpdate": "agent_message_chunk",
			"content": map[string]interface{}{
				"type": "text",
				"text": "\nI read the file for you.",
			},
		})
	}

	sendEvent(map[string]interface{}{
		"sessionUpdate": "agent_message",
		"content": map[string]interface{}{
			"type": "text",
			"text": "Hello! I'm the mock ACP server. How can I help you?",
		},
	})

	if !omitPromptComplete {
		sendEvent(map[string]interface{}{
			"sessionUpdate": "prompt_complete",
			"stopReason":    "end_turn",
		})
	}

	respond(id, map[string]interface{}{
		"stopReason": "end_turn",
	})
}

func handleSessionList(id *json.RawMessage) {
	items := make([]map[string]interface{}, 0, len(sessions)+len(configuredListSessions))
	if !omitCreatedFromList {
		for _, sid := range sessions {
			items = append(items, sessionListItem(sid))
		}
	}
	for _, sid := range configuredListSessions {
		items = append(items, sessionListItem(sid))
	}

	respond(id, map[string]interface{}{
		"sessions": items,
	})
}

func handleSessionLoad(id *json.RawMessage, params json.RawMessage) {
	var payload struct {
		SessionID  string        `json:"sessionId"`
		CWD        string        `json:"cwd"`
		MCPServers []interface{} `json:"mcpServers"`
	}
	if err := json.Unmarshal(params, &payload); err != nil {
		respondError(id, -32602, "Invalid params", err.Error())
		return
	}
	if payload.SessionID == "" {
		respondError(id, -32602, "Invalid params", "missing field `sessionId`")
		return
	}
	if payload.CWD == "" {
		respondError(id, -32602, "Invalid params", "missing field `cwd`")
		return
	}
	if payload.MCPServers == nil {
		respondError(id, -32602, "Invalid params", "missing field `mcpServers`")
		return
	}
	if loadErrorDetails != "" {
		respondError(id, -32603, "Internal error", map[string]interface{}{
			"details": loadErrorDetails,
		})
		return
	}
	upsertSessionRecord(payload.SessionID, payload.CWD)
	respond(id, map[string]interface{}{
		"sessionId":     payload.SessionID,
		"modes":         mockModes(),
		"models":        mockModels(),
		"configOptions": mockConfigOptions(),
	})
	sendSessionMetadataUpdates(payload.SessionID)
}

func sendSessionMetadataUpdates(sessionID string) {
	notify("session/update", map[string]interface{}{
		"sessionId": sessionID,
		"update": map[string]interface{}{
			"sessionUpdate": "current_mode_update",
			"currentModeId": "default",
		},
	})
	notify("session/update", map[string]interface{}{
		"sessionId": sessionID,
		"update": map[string]interface{}{
			"sessionUpdate": "config_options_update",
			"configOptions": mockConfigOptions(),
		},
	})
	notify("session/update", map[string]interface{}{
		"sessionId": sessionID,
		"update": map[string]interface{}{
			"sessionUpdate":     "available_commands_update",
			"availableCommands": mockAvailableCommands(),
		},
	})
}

func mockModes() map[string]interface{} {
	return map[string]interface{}{
		"currentModeId": "default",
		"availableModes": []map[string]interface{}{
			{"id": "default", "name": "Default", "description": "Standard behavior"},
			{"id": "plan", "name": "Plan Mode", "description": "Planning mode"},
			{"id": "acceptEdits", "name": "Accept Edits", "description": "Auto-accept edits"},
		},
	}
}

func mockModels() map[string]interface{} {
	return map[string]interface{}{
		"currentModelId": "mock-model",
		"availableModels": []map[string]interface{}{
			{"modelId": "mock-model", "name": "Mock Model", "description": "Mock ACP test model"},
		},
	}
}

func mockConfigOptions() []map[string]interface{} {
	return []map[string]interface{}{
		{
			"id":           "mode",
			"name":         "Mode",
			"description":  "Session permission mode",
			"category":     "mode",
			"type":         "select",
			"currentValue": "default",
			"options": []map[string]interface{}{
				{"value": "default", "name": "Default", "description": "Standard behavior"},
				{"value": "plan", "name": "Plan Mode", "description": "Planning mode"},
				{"value": "acceptEdits", "name": "Accept Edits", "description": "Auto-accept edits"},
			},
		},
		{
			"id":           "model",
			"name":         "Model",
			"description":  "AI model to use",
			"category":     "model",
			"type":         "select",
			"currentValue": "mock-model",
			"options": []map[string]interface{}{
				{"value": "mock-model", "name": "Mock Model", "description": "Mock ACP test model"},
			},
		},
	}
}

func mockAvailableCommands() []map[string]interface{} {
	return []map[string]interface{}{
		{"name": "status", "description": "Show current session status"},
		{"name": "review", "description": "Review current changes and find issues"},
		{"name": "compact", "description": "Compact the conversation"},
	}
}

func upsertSessionRecord(sessionID, cwd string) {
	trimmedCWD := strings.TrimSpace(cwd)
	if trimmedCWD == "" {
		trimmedCWD = "/tmp/mock-workspace"
	}
	record := sessionRecords[sessionID]
	record.CWD = trimmedCWD
	if strings.TrimSpace(record.Title) == "" {
		record.Title = fmt.Sprintf("Mock Session %s", sessionID)
	}
	record.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	sessionRecords[sessionID] = record
}

func sessionListItem(sessionID string) map[string]interface{} {
	record, ok := sessionRecords[sessionID]
	if !ok {
		upsertSessionRecord(sessionID, "/tmp/mock-workspace")
		record = sessionRecords[sessionID]
	}
	return map[string]interface{}{
		"sessionId": sessionID,
		"cwd":       record.CWD,
		"title":     record.Title,
		"updatedAt": record.UpdatedAt,
	}
}
