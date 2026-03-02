package protocol

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// JSONRPCID represents a JSON-RPC request ID that can be either int or string.
type JSONRPCID struct {
	intVal    *int64
	stringVal *string
}

func IntID(v int64) JSONRPCID     { return JSONRPCID{intVal: &v} }
func StringID(v string) JSONRPCID { return JSONRPCID{stringVal: &v} }

func (id JSONRPCID) IsInt() bool    { return id.intVal != nil }
func (id JSONRPCID) IsString() bool { return id.stringVal != nil }
func (id JSONRPCID) IsZero() bool   { return id.intVal == nil && id.stringVal == nil }

func (id JSONRPCID) IntValue() int64 {
	if id.intVal != nil {
		return *id.intVal
	}
	return 0
}

func (id JSONRPCID) StringValue() string {
	if id.stringVal != nil {
		return *id.stringVal
	}
	return ""
}

func (id JSONRPCID) String() string {
	if id.intVal != nil {
		return fmt.Sprintf("%d", *id.intVal)
	}
	if id.stringVal != nil {
		return *id.stringVal
	}
	return "<nil>"
}

func (id JSONRPCID) MarshalJSON() ([]byte, error) {
	if id.intVal != nil {
		return json.Marshal(*id.intVal)
	}
	if id.stringVal != nil {
		return json.Marshal(*id.stringVal)
	}
	return []byte("null"), nil
}

func (id *JSONRPCID) UnmarshalJSON(data []byte) error {
	var intVal int64
	if err := json.Unmarshal(data, &intVal); err == nil {
		id.intVal = &intVal
		id.stringVal = nil
		return nil
	}
	var stringVal string
	if err := json.Unmarshal(data, &stringVal); err == nil {
		id.stringVal = &stringVal
		id.intVal = nil
		return nil
	}
	return fmt.Errorf("JSONRPCID must be int or string, got: %s", string(data))
}

// RPCError represents a JSON-RPC error object.
type RPCError struct {
	Code    int              `json:"code"`
	Message string           `json:"message"`
	Data    *json.RawMessage `json:"data,omitempty"`
}

func (e *RPCError) Error() string {
	return fmt.Sprintf("JSON-RPC error %d: %s", e.Code, e.Message)
}

// Message represents a JSON-RPC 2.0 message (request, response, notification, or error).
type Message struct {
	JSONRPC string           `json:"jsonrpc"`
	ID      *JSONRPCID       `json:"id,omitempty"`
	Method  string           `json:"method,omitempty"`
	Params  *json.RawMessage `json:"params,omitempty"`
	Result  *json.RawMessage `json:"result,omitempty"`
	Error   *RPCError        `json:"error,omitempty"`
}

var partialIDPattern = regexp.MustCompile(`"id"\s*:\s*("([^"\\]|\\.)*"|-?[0-9]+)`)

// NewRequest creates a JSON-RPC request message.
func NewRequest(id JSONRPCID, method string, params json.RawMessage) *Message {
	var p *json.RawMessage
	if params != nil {
		p = &params
	}
	return &Message{
		JSONRPC: "2.0",
		ID:      &id,
		Method:  method,
		Params:  p,
	}
}

// NewNotification creates a JSON-RPC notification (no ID).
func NewNotification(method string, params json.RawMessage) *Message {
	var p *json.RawMessage
	if params != nil {
		p = &params
	}
	return &Message{
		JSONRPC: "2.0",
		Method:  method,
		Params:  p,
	}
}

// NewResponse creates a JSON-RPC success response.
func NewResponse(id JSONRPCID, result json.RawMessage) *Message {
	var r *json.RawMessage
	if result != nil {
		r = &result
	}
	return &Message{
		JSONRPC: "2.0",
		ID:      &id,
		Result:  r,
	}
}

// NewErrorResponse creates a JSON-RPC error response.
func NewErrorResponse(id JSONRPCID, code int, message string) *Message {
	return &Message{
		JSONRPC: "2.0",
		ID:      &id,
		Error:   &RPCError{Code: code, Message: message},
	}
}

// IsRequest returns true if this is a request (has ID and method, no result/error).
func (m *Message) IsRequest() bool {
	return m.ID != nil && m.Method != "" && m.Result == nil && m.Error == nil
}

// IsNotification returns true if this is a notification (has method, no ID).
func (m *Message) IsNotification() bool {
	return m.ID == nil && m.Method != ""
}

// IsResponse returns true if this is a success response.
func (m *Message) IsResponse() bool {
	return m.ID != nil && m.Result != nil
}

// IsError returns true if this is an error response.
func (m *Message) IsError() bool {
	return m.Error != nil
}

// IsDaemonMethod returns true if the method has the "daemon/" prefix.
func (m *Message) IsDaemonMethod() bool {
	return strings.HasPrefix(m.Method, "daemon/")
}

// ParseLine parses a single line of JSON into a Message.
// Returns nil, nil for non-JSON lines (e.g. PTY noise).
func ParseLine(line []byte) (*Message, error) {
	// Skip empty lines and non-JSON content
	trimmed := strings.TrimSpace(string(line))
	if trimmed == "" || trimmed[0] != '{' {
		return nil, nil
	}

	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(trimmed), &raw); err != nil {
		return nil, fmt.Errorf("invalid JSON-RPC message: %w", err)
	}

	var msg Message
	if err := json.Unmarshal([]byte(trimmed), &msg); err != nil {
		return nil, fmt.Errorf("invalid JSON-RPC message: %w", err)
	}

	// encoding/json sets *json.RawMessage fields to nil for explicit null values.
	// Preserve explicit `result: null` so downstream logic can classify this as
	// a valid JSON-RPC response.
	if _, hasResult := raw["result"]; hasResult && msg.Result == nil {
		nullResult := json.RawMessage("null")
		msg.Result = &nullResult
	}
	return &msg, nil
}

// ExtractIDFromPossiblyMalformedLine extracts a JSON-RPC id from raw bytes even
// when the full line is malformed/truncated.
//
// This is best-effort and used to return parse errors against the originating
// request id instead of letting clients hang until timeout.
func ExtractIDFromPossiblyMalformedLine(line []byte) (JSONRPCID, bool) {
	matches := partialIDPattern.FindSubmatch(line)
	if len(matches) < 2 {
		return JSONRPCID{}, false
	}

	rawID := matches[1]
	if len(rawID) == 0 {
		return JSONRPCID{}, false
	}

	if rawID[0] == '"' {
		var id string
		if err := json.Unmarshal(rawID, &id); err != nil {
			return JSONRPCID{}, false
		}
		return StringID(id), true
	}

	intID, err := strconv.ParseInt(string(rawID), 10, 64)
	if err != nil {
		return JSONRPCID{}, false
	}
	return IntID(intID), true
}

// Serialize serializes a Message to JSON bytes (without trailing newline).
func Serialize(msg *Message) ([]byte, error) {
	return json.Marshal(msg)
}

// SerializeLine serializes a Message to JSON bytes with a trailing newline.
func SerializeLine(msg *Message) ([]byte, error) {
	data, err := json.Marshal(msg)
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

// ExtractSessionID extracts the sessionId from the message params.
func ExtractSessionID(msg *Message) string {
	if msg.Params == nil {
		return ""
	}
	var params struct {
		SessionID string `json:"sessionId"`
	}
	if err := json.Unmarshal(*msg.Params, &params); err != nil {
		return ""
	}
	return params.SessionID
}

// ExtractRouteToSession extracts the __routeToSession override from params.
// Used by daemon request routing for methods that support routing overrides.
func ExtractRouteToSession(msg *Message) string {
	if msg.Params == nil {
		return ""
	}
	var params struct {
		RouteToSession string `json:"__routeToSession"`
	}
	if err := json.Unmarshal(*msg.Params, &params); err != nil {
		return ""
	}
	return params.RouteToSession
}

// ExtractTraceID extracts params._meta.traceId from the message.
func ExtractTraceID(msg *Message) string {
	if msg.Params == nil {
		return ""
	}
	var params struct {
		Meta struct {
			TraceID string `json:"traceId"`
		} `json:"_meta"`
	}
	if err := json.Unmarshal(*msg.Params, &params); err != nil {
		return ""
	}
	return params.Meta.TraceID
}

// ExtractMethod returns the method name, or empty for responses.
func (m *Message) GetMethod() string {
	return m.Method
}

// SetParam sets a key-value pair in the params object.
// If params is nil or not an object, creates a new object.
func (m *Message) SetParam(key string, value interface{}) error {
	var params map[string]json.RawMessage
	if m.Params != nil {
		if err := json.Unmarshal(*m.Params, &params); err != nil {
			params = make(map[string]json.RawMessage)
		}
	} else {
		params = make(map[string]json.RawMessage)
	}

	val, err := json.Marshal(value)
	if err != nil {
		return err
	}
	params[key] = val

	data, err := json.Marshal(params)
	if err != nil {
		return err
	}
	raw := json.RawMessage(data)
	m.Params = &raw
	return nil
}

// Clone creates a deep copy of the message.
func (m *Message) Clone() *Message {
	clone := &Message{
		JSONRPC: m.JSONRPC,
		Method:  m.Method,
	}
	if m.ID != nil {
		id := *m.ID
		clone.ID = &id
	}
	if m.Params != nil {
		p := make(json.RawMessage, len(*m.Params))
		copy(p, *m.Params)
		clone.Params = &p
	}
	if m.Result != nil {
		r := make(json.RawMessage, len(*m.Result))
		copy(r, *m.Result)
		clone.Result = &r
	}
	if m.Error != nil {
		e := *m.Error
		clone.Error = &e
	}
	return clone
}
