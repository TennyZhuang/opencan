package protocol

import (
	"encoding/json"
	"testing"
)

func TestJSONRPCID_Int(t *testing.T) {
	id := IntID(42)
	if !id.IsInt() || id.IsString() || id.IsZero() {
		t.Fatal("expected int ID")
	}
	if id.IntValue() != 42 {
		t.Fatalf("expected 42, got %d", id.IntValue())
	}
	if id.String() != "42" {
		t.Fatalf("expected '42', got %q", id.String())
	}
}

func TestJSONRPCID_String(t *testing.T) {
	id := StringID("abc")
	if id.IsInt() || !id.IsString() || id.IsZero() {
		t.Fatal("expected string ID")
	}
	if id.StringValue() != "abc" {
		t.Fatalf("expected 'abc', got %q", id.StringValue())
	}
}

func TestJSONRPCID_MarshalInt(t *testing.T) {
	id := IntID(123)
	data, err := json.Marshal(id)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "123" {
		t.Fatalf("expected '123', got %q", string(data))
	}
}

func TestJSONRPCID_MarshalString(t *testing.T) {
	id := StringID("req-1")
	data, err := json.Marshal(id)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `"req-1"` {
		t.Fatalf("expected '\"req-1\"', got %q", string(data))
	}
}

func TestJSONRPCID_UnmarshalInt(t *testing.T) {
	var id JSONRPCID
	if err := json.Unmarshal([]byte("42"), &id); err != nil {
		t.Fatal(err)
	}
	if !id.IsInt() || id.IntValue() != 42 {
		t.Fatalf("expected int 42, got %v", id)
	}
}

func TestJSONRPCID_UnmarshalString(t *testing.T) {
	var id JSONRPCID
	if err := json.Unmarshal([]byte(`"hello"`), &id); err != nil {
		t.Fatal(err)
	}
	if !id.IsString() || id.StringValue() != "hello" {
		t.Fatalf("expected string 'hello', got %v", id)
	}
}

func TestParseLine_Request(t *testing.T) {
	line := []byte(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"version":1}}`)
	msg, err := ParseLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if msg == nil {
		t.Fatal("expected non-nil message")
	}
	if !msg.IsRequest() {
		t.Fatal("expected request")
	}
	if msg.Method != "initialize" {
		t.Fatalf("expected 'initialize', got %q", msg.Method)
	}
	if msg.ID.IntValue() != 1 {
		t.Fatalf("expected ID 1, got %v", msg.ID)
	}
}

func TestParseLine_Notification(t *testing.T) {
	line := []byte(`{"jsonrpc":"2.0","method":"session/update","params":{"update":{}}}`)
	msg, err := ParseLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if !msg.IsNotification() {
		t.Fatal("expected notification")
	}
	if msg.Method != "session/update" {
		t.Fatalf("expected 'session/update', got %q", msg.Method)
	}
}

func TestParseLine_Response(t *testing.T) {
	line := []byte(`{"jsonrpc":"2.0","id":1,"result":{"sessionId":"sess-1"}}`)
	msg, err := ParseLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if !msg.IsResponse() {
		t.Fatal("expected response")
	}
}

func TestParseLine_ResponseWithNullResult(t *testing.T) {
	line := []byte(`{"jsonrpc":"2.0","id":1,"result":null}`)
	msg, err := ParseLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if !msg.IsResponse() {
		t.Fatal("expected response for explicit null result")
	}
	if msg.Result == nil {
		t.Fatal("expected non-nil raw result for explicit null")
	}
	if got := string(*msg.Result); got != "null" {
		t.Fatalf("expected raw result null, got %q", got)
	}
}

func TestParseLine_Error(t *testing.T) {
	line := []byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"not found"}}`)
	msg, err := ParseLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if !msg.IsError() {
		t.Fatal("expected error")
	}
	if msg.Error.Code != -32601 {
		t.Fatalf("expected code -32601, got %d", msg.Error.Code)
	}
}

func TestParseLine_NonJSON(t *testing.T) {
	lines := [][]byte{
		[]byte(""),
		[]byte("not json"),
		[]byte("  "),
		[]byte("bash: command not found"),
	}
	for _, line := range lines {
		msg, err := ParseLine(line)
		if err != nil {
			t.Fatalf("unexpected error for %q: %v", string(line), err)
		}
		if msg != nil {
			t.Fatalf("expected nil for %q, got %v", string(line), msg)
		}
	}
}

func TestParseLine_TrimmedJSON(t *testing.T) {
	line := []byte(" \t{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"daemon/hello\"}\r\n")
	msg, err := ParseLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if msg == nil || !msg.IsRequest() {
		t.Fatalf("expected request, got %#v", msg)
	}
	if msg.ID.IntValue() != 7 {
		t.Fatalf("expected ID 7, got %v", msg.ID)
	}
}

func TestParseLine_InvalidJSON(t *testing.T) {
	line := []byte(`{"jsonrpc":"2.0","id":1,`)
	msg, err := ParseLine(line)
	if err == nil {
		t.Fatal("expected parse error")
	}
	if msg != nil {
		t.Fatalf("expected nil message on parse error, got %#v", msg)
	}
}

func TestExtractIDFromPossiblyMalformedLine_IntID(t *testing.T) {
	line := []byte(`{"jsonrpc":"2.0","id":123,"method":"session/prompt","params":{"sessionId":"abc"}`)
	id, ok := ExtractIDFromPossiblyMalformedLine(line)
	if !ok {
		t.Fatal("expected id extraction to succeed")
	}
	if !id.IsInt() || id.IntValue() != 123 {
		t.Fatalf("expected int id 123, got %#v", id)
	}
}

func TestExtractIDFromPossiblyMalformedLine_StringID(t *testing.T) {
	line := []byte(`{"jsonrpc":"2.0","id":"req-42","method":"session/prompt","params":{"sessionId":"abc"}`)
	id, ok := ExtractIDFromPossiblyMalformedLine(line)
	if !ok {
		t.Fatal("expected id extraction to succeed")
	}
	if !id.IsString() || id.StringValue() != "req-42" {
		t.Fatalf("expected string id req-42, got %#v", id)
	}
}

func TestExtractIDFromPossiblyMalformedLine_MissingID(t *testing.T) {
	line := []byte(`{"jsonrpc":"2.0","method":"session/prompt","params":{"sessionId":"abc"}`)
	if _, ok := ExtractIDFromPossiblyMalformedLine(line); ok {
		t.Fatal("expected id extraction to fail without id")
	}
}

func TestIsDaemonMethod(t *testing.T) {
	tests := []struct {
		method string
		want   bool
	}{
		{"daemon/hello", true},
		{"daemon/session.create", true},
		{"session/prompt", false},
		{"initialize", false},
		{"", false},
	}
	for _, tt := range tests {
		msg := &Message{Method: tt.method}
		if got := msg.IsDaemonMethod(); got != tt.want {
			t.Errorf("IsDaemonMethod(%q) = %v, want %v", tt.method, got, tt.want)
		}
	}
}

func TestExtractSessionID(t *testing.T) {
	params := json.RawMessage(`{"sessionId":"sess-123","prompt":[]}`)
	msg := &Message{Params: &params}
	if got := ExtractSessionID(msg); got != "sess-123" {
		t.Fatalf("expected 'sess-123', got %q", got)
	}
}

func TestExtractSessionID_Missing(t *testing.T) {
	params := json.RawMessage(`{"prompt":[]}`)
	msg := &Message{Params: &params}
	if got := ExtractSessionID(msg); got != "" {
		t.Fatalf("expected empty, got %q", got)
	}
}

func TestExtractTraceID(t *testing.T) {
	params := json.RawMessage(`{"sessionId":"sess-123","_meta":{"traceId":"trace-abc"}}`)
	msg := &Message{Params: &params}
	if got := ExtractTraceID(msg); got != "trace-abc" {
		t.Fatalf("expected trace-abc, got %q", got)
	}
}

func TestExtractTraceID_MissingOrInvalid(t *testing.T) {
	tests := []json.RawMessage{
		json.RawMessage(`{"sessionId":"sess-123"}`),
		json.RawMessage(`{"_meta":{"traceId":123}}`),
		json.RawMessage(`[]`),
	}
	for _, params := range tests {
		msg := &Message{Params: &params}
		if got := ExtractTraceID(msg); got != "" {
			t.Fatalf("expected empty traceId for %s, got %q", string(params), got)
		}
	}
}

func TestNewRequest(t *testing.T) {
	params, _ := json.Marshal(map[string]string{"key": "val"})
	msg := NewRequest(IntID(5), "test/method", params)

	if msg.JSONRPC != "2.0" {
		t.Fatal("expected 2.0")
	}
	if !msg.IsRequest() {
		t.Fatal("expected request")
	}
	if msg.Method != "test/method" {
		t.Fatalf("expected 'test/method', got %q", msg.Method)
	}
}

func TestSerializeRoundTrip(t *testing.T) {
	params, _ := json.Marshal(map[string]int{"x": 1})
	original := NewRequest(IntID(10), "foo/bar", params)

	data, err := Serialize(original)
	if err != nil {
		t.Fatal(err)
	}

	parsed, err := ParseLine(data)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Method != "foo/bar" {
		t.Fatalf("expected 'foo/bar', got %q", parsed.Method)
	}
	if parsed.ID.IntValue() != 10 {
		t.Fatalf("expected ID 10, got %v", parsed.ID)
	}
}

func TestSetParam(t *testing.T) {
	params := json.RawMessage(`{"sessionId":"s1"}`)
	msg := &Message{Params: &params}

	if err := msg.SetParam("__seq", uint64(42)); err != nil {
		t.Fatal(err)
	}

	var p map[string]json.RawMessage
	json.Unmarshal(*msg.Params, &p)

	if string(p["sessionId"]) != `"s1"` {
		t.Fatalf("sessionId lost, got %s", string(p["sessionId"]))
	}
	if string(p["__seq"]) != "42" {
		t.Fatalf("__seq wrong, got %s", string(p["__seq"]))
	}
}

func TestSetParam_ReplacesNonObjectParams(t *testing.T) {
	params := json.RawMessage(`[]`)
	msg := &Message{Params: &params}

	if err := msg.SetParam("__seq", uint64(9)); err != nil {
		t.Fatal(err)
	}

	var p map[string]json.RawMessage
	if err := json.Unmarshal(*msg.Params, &p); err != nil {
		t.Fatal(err)
	}
	if string(p["__seq"]) != "9" {
		t.Fatalf("__seq wrong, got %s", string(p["__seq"]))
	}
}

func TestClone(t *testing.T) {
	params := json.RawMessage(`{"key":"val"}`)
	original := &Message{
		JSONRPC: "2.0",
		Method:  "test",
		Params:  &params,
	}
	id := IntID(5)
	original.ID = &id

	clone := original.Clone()

	// Modify clone
	newID := IntID(99)
	clone.ID = &newID
	clone.Method = "modified"

	// Original unchanged
	if original.ID.IntValue() != 5 {
		t.Fatal("original ID was modified")
	}
	if original.Method != "test" {
		t.Fatal("original method was modified")
	}
}
