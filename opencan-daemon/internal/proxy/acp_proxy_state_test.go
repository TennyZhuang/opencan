package proxy

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"testing"

	"github.com/anthropics/opencan-daemon/internal/protocol"
)

var errWriteFailed = errors.New("write failed")

type fakeWriteCloser struct {
	fail bool
}

func (w *fakeWriteCloser) Write(p []byte) (int, error) {
	if w.fail {
		return 0, errWriteFailed
	}
	return len(p), nil
}

func (w *fakeWriteCloser) Close() error { return nil }

type fakeClientConn struct {
	sent []*protocol.Message
}

func (c *fakeClientConn) Send(msg *protocol.Message) error {
	c.sent = append(c.sent, msg)
	return nil
}

func (c *fakeClientConn) ForwardServerRequest(msg *protocol.Message, source *ACPProxy) error {
	c.sent = append(c.sent, msg)
	return nil
}

func newTestProxy(state SessionState, writer io.WriteCloser) *ACPProxy {
	if writer == nil {
		writer = &fakeWriteCloser{}
	}
	return &ACPProxy{
		state:           state,
		stdin:           writer,
		eventBuffer:     NewEventBuffer(10),
		pendingRequests: make(map[int64]PendingRequest),
		logger:          slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

func newPromptRequest(id int64) *protocol.Message {
	params, _ := json.Marshal(map[string]interface{}{
		"sessionId": "s1",
		"prompt": []map[string]interface{}{
			{"type": "text", "text": "hello"},
		},
	})
	return protocol.NewRequest(protocol.IntID(id), protocol.MethodSessionPrompt, params)
}

func TestAttachClient_DrainingBecomesPrompting(t *testing.T) {
	p := newTestProxy(StateDraining, nil)
	client := &fakeClientConn{}

	state := p.AttachClient(client)

	if state != StatePrompting {
		t.Fatalf("AttachClient() state = %v, want %v", state, StatePrompting)
	}
	if p.State() != StatePrompting {
		t.Fatalf("proxy state = %v, want %v", p.State(), StatePrompting)
	}
}

func TestTryAttachClientWithOwner_AllowsReclaimBySameOwnerID(t *testing.T) {
	p := newTestProxy(StateIdle, nil)
	first := &fakeClientConn{}
	second := &fakeClientConn{}

	state, attached := p.TryAttachClientWithOwner(first, "app-owner-1")
	if !attached {
		t.Fatal("first attach should succeed")
	}
	if state != StateIdle {
		t.Fatalf("first attach state = %v, want %v", state, StateIdle)
	}

	state, attached = p.TryAttachClientWithOwner(second, "app-owner-1")
	if !attached {
		t.Fatal("same-owner reclaim should succeed")
	}
	if state != StateIdle {
		t.Fatalf("reclaim attach state = %v, want %v", state, StateIdle)
	}
	if got := p.GetClient(); got != second {
		t.Fatalf("attached client = %v, want second client", got)
	}
	if gotOwner := p.CurrentOwnerID(); gotOwner != "app-owner-1" {
		t.Fatalf("ownerID = %q, want %q", gotOwner, "app-owner-1")
	}
}

func TestTryAttachClientWithOwner_RejectsDifferentOwnerID(t *testing.T) {
	p := newTestProxy(StateIdle, nil)
	first := &fakeClientConn{}
	second := &fakeClientConn{}

	if _, attached := p.TryAttachClientWithOwner(first, "app-owner-1"); !attached {
		t.Fatal("first attach should succeed")
	}

	if _, attached := p.TryAttachClientWithOwner(second, "app-owner-2"); attached {
		t.Fatal("different owner should be rejected")
	}
	if got := p.GetClient(); got != first {
		t.Fatalf("attached client should remain first, got %v", got)
	}
}

func TestHandlePromptComplete_AttachedDrainingEndsIdle(t *testing.T) {
	p := newTestProxy(StateDraining, nil)
	client := &fakeClientConn{}
	p.AttachClient(client)
	p.setState(StateDraining)

	p.handlePromptComplete()

	if p.State() != StateIdle {
		t.Fatalf("proxy state = %v, want %v", p.State(), StateIdle)
	}
}

func TestForwardFromClient_PromptWriteFailureDoesNotMarkPrompting(t *testing.T) {
	p := newTestProxy(StateIdle, &fakeWriteCloser{fail: true})
	client := &fakeClientConn{}

	err := p.ForwardFromClient(newPromptRequest(1), client)
	if !errors.Is(err, errWriteFailed) {
		t.Fatalf("ForwardFromClient() error = %v, want %v", err, errWriteFailed)
	}
	if p.State() != StateIdle {
		t.Fatalf("proxy state = %v, want %v", p.State(), StateIdle)
	}
	if len(p.pendingRequests) != 0 {
		t.Fatalf("pendingRequests = %d, want 0", len(p.pendingRequests))
	}
}

func TestForwardFromClient_DeadSessionRejected(t *testing.T) {
	p := newTestProxy(StateDead, nil)
	client := &fakeClientConn{}

	err := p.ForwardFromClient(newPromptRequest(1), client)
	if err == nil {
		t.Fatal("ForwardFromClient() error = nil, want non-nil")
	}
	if len(p.pendingRequests) != 0 {
		t.Fatalf("pendingRequests = %d, want 0", len(p.pendingRequests))
	}
}

func TestRouteResponse_PromptErrorClearsRunningState(t *testing.T) {
	p := newTestProxy(StatePrompting, nil)
	client := &fakeClientConn{}
	p.AttachClient(client)

	origID := protocol.IntID(7)
	internalID := int64(101)
	p.pendingRequests[internalID] = PendingRequest{
		OriginalID: &origID,
		Client:     client,
		Method:     protocol.MethodSessionPrompt,
	}
	errMsg := protocol.NewErrorResponse(protocol.IntID(internalID), -32000, "boom")

	p.routeResponse(errMsg)

	if p.State() != StateIdle {
		t.Fatalf("proxy state = %v, want %v", p.State(), StateIdle)
	}
	if len(client.sent) != 1 {
		t.Fatalf("forwarded messages = %d, want 1", len(client.sent))
	}
	if client.sent[0].ID == nil || client.sent[0].ID.IntValue() != origID.IntValue() {
		t.Fatalf("forwarded ID = %v, want %v", client.sent[0].ID, origID)
	}
}

func TestRouteResponse_PromptSuccessClearsRunningState(t *testing.T) {
	p := newTestProxy(StatePrompting, nil)
	client := &fakeClientConn{}
	p.AttachClient(client)

	origID := protocol.IntID(8)
	internalID := int64(102)
	p.pendingRequests[internalID] = PendingRequest{
		OriginalID: &origID,
		Client:     client,
		Method:     protocol.MethodSessionPrompt,
	}

	result, _ := json.Marshal(map[string]interface{}{
		"stopReason": "end_turn",
	})
	resp := protocol.NewResponse(protocol.IntID(internalID), result)

	p.routeResponse(resp)

	if p.State() != StateIdle {
		t.Fatalf("proxy state = %v, want %v", p.State(), StateIdle)
	}
	if len(client.sent) != 1 {
		t.Fatalf("forwarded messages = %d, want 1", len(client.sent))
	}
	if client.sent[0].ID == nil || client.sent[0].ID.IntValue() != origID.IntValue() {
		t.Fatalf("forwarded ID = %v, want %v", client.sent[0].ID, origID)
	}
}

func TestRouteResponse_PromptSuccessClearsDrainingStateWithoutClient(t *testing.T) {
	p := newTestProxy(StateDraining, nil)
	internalID := int64(103)
	p.pendingRequests[internalID] = PendingRequest{
		Method: protocol.MethodSessionPrompt,
	}

	result, _ := json.Marshal(map[string]interface{}{
		"stopReason": "end_turn",
	})
	resp := protocol.NewResponse(protocol.IntID(internalID), result)

	p.routeResponse(resp)

	if p.State() != StateCompleted {
		t.Fatalf("proxy state = %v, want %v", p.State(), StateCompleted)
	}
}

func TestSetState_DeadIsTerminal(t *testing.T) {
	p := newTestProxy(StateDead, nil)

	p.setState(StatePrompting)

	if p.State() != StateDead {
		t.Fatalf("proxy state = %v, want %v", p.State(), StateDead)
	}
}
