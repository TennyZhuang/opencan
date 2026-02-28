package proxy

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os/exec"
	"sync"
	"sync/atomic"
	"time"

	"github.com/anthropics/opencan-daemon/internal/protocol"
)

// ClientConn represents an attached client connection that can receive messages.
type ClientConn interface {
	Send(msg *protocol.Message) error
	// ForwardServerRequest forwards a server-initiated request (e.g., permission)
	// to the client, tracking which proxy it came from so the response can be routed back.
	ForwardServerRequest(msg *protocol.Message, source *ACPProxy) error
}

// PendingRequest tracks a forwarded request so the response can be routed back.
type PendingRequest struct {
	OriginalID *protocol.JSONRPCID
	Client     ClientConn
	Method     string
	ResponseCh chan *protocol.Message
}

// ACPProxy manages a single claude-agent-acp child process and its event buffer.
type ACPProxy struct {
	SessionID string
	CWD       string
	Command   string

	mu    sync.RWMutex
	state SessionState

	cmd     *exec.Cmd
	stdin   io.WriteCloser
	scanner *bufio.Scanner

	eventBuffer *EventBuffer
	client      atomic.Pointer[clientWrapper]

	pendingMu       sync.Mutex
	pendingRequests map[int64]PendingRequest
	nextInternalID  atomic.Int64

	doneCh  chan struct{}
	logger  *slog.Logger
	writeMu sync.Mutex
}

type clientWrapper struct {
	conn ClientConn
}

// NewACPProxy spawns an ACP process, initializes the ACP protocol,
// creates a session, and starts the background read loop.
// Returns the proxy or an error if initialization fails.
func NewACPProxy(cwd, command string, logger *slog.Logger) (*ACPProxy, error) {
	cmd, _, err := BuildExecCommand(command)
	if err != nil {
		return nil, fmt.Errorf("parse command: %w", err)
	}
	cmd.Dir = cwd

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		stdin.Close()
		return nil, fmt.Errorf("stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		stdin.Close()
		stdout.Close()
		return nil, fmt.Errorf("start process: %w", err)
	}

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)

	p := &ACPProxy{
		CWD:             cwd,
		Command:         command,
		state:           StateStarting,
		cmd:             cmd,
		stdin:           stdin,
		scanner:         scanner,
		eventBuffer:     NewEventBuffer(100000),
		pendingRequests: make(map[int64]PendingRequest),
		doneCh:          make(chan struct{}),
		logger:          logger.With("component", "acp_proxy"),
	}
	p.nextInternalID.Store(100) // Start after daemon's own IDs

	// Run initialization synchronously using the same scanner
	sessionID, err := p.initializeACP(cwd)
	if err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		stdin.Close()
		return nil, fmt.Errorf("ACP init: %w", err)
	}
	p.SessionID = sessionID
	p.setState(StateIdle)

	// Start background read loop (continues using the same scanner)
	go p.readLoop()

	return p, nil
}

// initializeACP sends initialize + session/new and returns the session ID.
// Uses the proxy's scanner, which is later handed off to readLoop.
func (p *ACPProxy) initializeACP(cwd string) (string, error) {
	// Send initialize
	initID := protocol.IntID(1)
	initParams, _ := json.Marshal(map[string]interface{}{
		"protocolVersion":    1,
		"clientCapabilities": map[string]interface{}{},
		"clientInfo": map[string]interface{}{
			"name":    "opencan-daemon",
			"title":   "OpenCAN Daemon",
			"version": "0.1.0",
		},
	})
	if err := p.writeMessage(protocol.NewRequest(initID, protocol.MethodInitialize, initParams)); err != nil {
		return "", fmt.Errorf("send initialize: %w", err)
	}

	// Read initialize response
	if err := p.readUntilResponse(1); err != nil {
		return "", fmt.Errorf("initialize: %w", err)
	}

	// Send session/new
	newID := protocol.IntID(2)
	newParams, _ := json.Marshal(map[string]interface{}{
		"cwd":        cwd,
		"mcpServers": []interface{}{},
	})
	if err := p.writeMessage(protocol.NewRequest(newID, protocol.MethodSessionNew, newParams)); err != nil {
		return "", fmt.Errorf("send session/new: %w", err)
	}

	// Read session/new response, buffer any notifications
	var sessionID string
	for p.scanner.Scan() {
		msg, err := protocol.ParseLine(p.scanner.Bytes())
		if err != nil || msg == nil {
			continue
		}
		if msg.IsNotification() {
			raw, _ := protocol.Serialize(msg)
			p.eventBuffer.Append(raw)
			continue
		}
		if (msg.IsResponse() || msg.IsError()) && msg.ID != nil && msg.ID.IntValue() == 2 {
			if msg.IsError() {
				return "", fmt.Errorf("session/new error: %s", msg.Error.Message)
			}
			var result struct {
				SessionID string `json:"sessionId"`
			}
			if msg.Result != nil {
				json.Unmarshal(*msg.Result, &result)
			}
			sessionID = result.SessionID
			break
		}
	}
	if err := p.scanner.Err(); err != nil {
		return "", fmt.Errorf("scanner: %w", err)
	}
	if sessionID == "" {
		return "", fmt.Errorf("no sessionId in response")
	}
	return sessionID, nil
}

// readUntilResponse reads messages until a response with the given ID arrives.
// Notifications encountered along the way are buffered.
func (p *ACPProxy) readUntilResponse(id int64) error {
	for p.scanner.Scan() {
		msg, err := protocol.ParseLine(p.scanner.Bytes())
		if err != nil || msg == nil {
			continue
		}
		if msg.IsNotification() {
			raw, _ := protocol.Serialize(msg)
			p.eventBuffer.Append(raw)
			continue
		}
		if msg.ID != nil && msg.ID.IntValue() == id {
			if msg.IsError() {
				return fmt.Errorf("RPC error %d: %s", msg.Error.Code, msg.Error.Message)
			}
			return nil
		}
	}
	return fmt.Errorf("EOF before response for id=%d", id)
}

// readLoop reads from the ACP process stdout until it closes.
func (p *ACPProxy) readLoop() {
	defer func() {
		p.setState(StateDead)
		close(p.doneCh)
		p.stdin.Close()
		p.cancelAllPending()
		p.cmd.Wait()
	}()

	for p.scanner.Scan() {
		msg, err := protocol.ParseLine(p.scanner.Bytes())
		if err != nil || msg == nil {
			continue
		}

		if msg.IsNotification() {
			p.handleNotification(msg)
		} else if msg.IsResponse() || msg.IsError() {
			p.routeResponse(msg)
		} else if msg.IsRequest() {
			p.handleServerRequest(msg)
		}
	}
}

func (p *ACPProxy) handleNotification(msg *protocol.Message) {
	// Serialize and buffer the raw notification
	raw, err := protocol.Serialize(msg)
	if err != nil {
		p.logger.Error("serialize notification", "error", err)
		return
	}
	seq := p.eventBuffer.Append(raw)

	// Check for prompt_complete
	if isPromptComplete(msg) {
		p.handlePromptComplete()
	}

	// Forward to attached client with __seq metadata
	if client := p.GetClient(); client != nil {
		fwd := msg.Clone()
		fwd.SetParam("__seq", seq)
		client.Send(fwd)
	}
}

func (p *ACPProxy) routeResponse(msg *protocol.Message) {
	if msg.ID == nil {
		return
	}
	internalID := msg.ID.IntValue()

	p.pendingMu.Lock()
	pr, ok := p.pendingRequests[internalID]
	if ok {
		delete(p.pendingRequests, internalID)
	}
	p.pendingMu.Unlock()

	if !ok {
		p.logger.Warn("response for unknown request", "id", internalID)
		return
	}

	fwd := msg.Clone()
	fwd.ID = pr.OriginalID
	if pr.Client != nil {
		pr.Client.Send(fwd)
	}
	if pr.ResponseCh != nil {
		pr.ResponseCh <- msg.Clone()
		close(pr.ResponseCh)
	}

	if pr.Method == protocol.MethodSessionPrompt && (msg.IsResponse() || msg.IsError()) {
		p.handlePromptTerminalResponse()
	}
}

func (p *ACPProxy) handleServerRequest(msg *protocol.Message) {
	if msg.Method == "session/request_permission" {
		if client := p.GetClient(); client != nil {
			client.ForwardServerRequest(msg, p)
			return
		}
		// No client — auto-approve
		p.logger.Info("auto-approving permission (no client)", "session", p.SessionID)
		p.writeMessage(p.buildAutoApproveResponse(msg))
		// Buffer for replay
		raw, _ := protocol.Serialize(msg)
		p.eventBuffer.Append(raw)
		return
	}
	// Unknown server request
	if msg.ID != nil {
		p.writeMessage(protocol.NewErrorResponse(*msg.ID, -32601, "Method not found: "+msg.Method))
	}
}

func (p *ACPProxy) buildAutoApproveResponse(msg *protocol.Message) *protocol.Message {
	selectedID := "allow"
	if msg.Params != nil {
		var params struct {
			Options []struct {
				Kind     string `json:"kind"`
				OptionID string `json:"optionId"`
			} `json:"options"`
		}
		if err := json.Unmarshal(*msg.Params, &params); err == nil {
			for _, opt := range params.Options {
				if opt.Kind == "allow_once" || opt.Kind == "allow_always" {
					selectedID = opt.OptionID
					break
				}
			}
		}
	}
	result, _ := json.Marshal(map[string]interface{}{
		"outcome": map[string]interface{}{
			"outcome":  "selected",
			"optionId": selectedID,
		},
	})
	return protocol.NewResponse(*msg.ID, result)
}

func (p *ACPProxy) handlePromptComplete() {
	p.finishPromptLifecycle()
}

// handlePromptTerminalResponse clears stale running states when a prompt
// request reaches a terminal response without emitting prompt_complete.
func (p *ACPProxy) handlePromptTerminalResponse() {
	p.finishPromptLifecycle()
}

func (p *ACPProxy) finishPromptLifecycle() {
	switch p.State() {
	case StatePrompting, StateDraining:
		if p.GetClient() != nil {
			p.setState(StateIdle)
		} else {
			p.setState(StateCompleted)
		}
	}
}

func (p *ACPProxy) cancelAllPending() {
	p.pendingMu.Lock()
	defer p.pendingMu.Unlock()
	for id, pr := range p.pendingRequests {
		if pr.Client != nil && pr.OriginalID != nil {
			errMsg := protocol.NewErrorResponse(*pr.OriginalID, -32000, "ACP process exited")
			pr.Client.Send(errMsg)
		}
		if pr.ResponseCh != nil {
			close(pr.ResponseCh)
		}
		delete(p.pendingRequests, id)
	}
}

// State returns the current session state.
func (p *ACPProxy) State() SessionState {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.state
}

func (p *ACPProxy) setState(s SessionState) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.state == StateDead && s != StateDead {
		p.logger.Warn("ignoring transition from dead state", "from", p.state, "to", s, "session", p.SessionID)
		return
	}
	if p.state == s {
		return
	}
	p.logger.Info("state transition", "from", p.state, "to", s, "session", p.SessionID)
	p.state = s
}

// Done returns a channel closed when the ACP process exits.
func (p *ACPProxy) Done() <-chan struct{} { return p.doneCh }

// EventBuf returns the proxy's event buffer.
func (p *ACPProxy) EventBuf() *EventBuffer { return p.eventBuffer }

// AttachClient sets the active client. Returns the resulting state.
func (p *ACPProxy) AttachClient(c ClientConn) SessionState {
	state, _ := p.TryAttachClient(c)
	return state
}

// TryAttachClient attaches a client if no other client is attached.
// Returns false when another client already owns the session.
func (p *ACPProxy) TryAttachClient(c ClientConn) (SessionState, bool) {
	for {
		current := p.client.Load()
		if current != nil {
			if current.conn != c {
				return p.State(), false
			}
		} else {
			if !p.client.CompareAndSwap(nil, &clientWrapper{conn: c}) {
				// Lost a race; re-check ownership.
				continue
			}
		}

		// Keep behavior identical to AttachClient for valid attaches.
		p.client.Store(&clientWrapper{conn: c})
		state := p.State()
		switch state {
		case StateCompleted:
			p.setState(StateIdle)
			return StateIdle, true
		case StateDraining:
			p.setState(StatePrompting)
			return StatePrompting, true
		}
		return state, true
	}
}

// DetachClient removes the client if it matches.
func (p *ACPProxy) DetachClient(c ClientConn) {
	current := p.client.Load()
	if current != nil && current.conn == c {
		p.client.Store(nil)
		if p.State() == StatePrompting {
			p.setState(StateDraining)
		}
	}
}

// GetClient returns the attached client or nil.
func (p *ACPProxy) GetClient() ClientConn {
	w := p.client.Load()
	if w == nil {
		return nil
	}
	return w.conn
}

// ForwardFromClient forwards a request to the ACP process with ID rewriting.
func (p *ACPProxy) ForwardFromClient(msg *protocol.Message, client ClientConn) error {
	if msg.IsRequest() {
		if msg.Method == protocol.MethodSessionPrompt && p.State() == StateDead {
			return fmt.Errorf("session is dead")
		}
		internalID := p.nextInternalID.Add(1)
		p.pendingMu.Lock()
		p.pendingRequests[internalID] = PendingRequest{
			OriginalID: msg.ID,
			Client:     client,
			Method:     msg.Method,
		}
		p.pendingMu.Unlock()

		fwd := msg.Clone()
		newID := protocol.IntID(internalID)
		fwd.ID = &newID
		if err := p.writeMessage(fwd); err != nil {
			p.pendingMu.Lock()
			delete(p.pendingRequests, internalID)
			p.pendingMu.Unlock()
			return err
		}
		if msg.Method == protocol.MethodSessionPrompt {
			p.setState(StatePrompting)
		}
		return nil
	}
	// Direct forward (e.g., permission response from client)
	return p.writeMessage(msg)
}

// LoadableSession holds metadata for a session discovered via ACP session/list.
type LoadableSession struct {
	SessionID string
	CWD       string
	Title     string
}

// LoadableSessions queries ACP session/list and returns full metadata
// for all sessions that session/load can resolve.
func (p *ACPProxy) LoadableSessions(timeout time.Duration) ([]LoadableSession, error) {
	resp, err := p.callACPRequest(protocol.MethodSessionList, map[string]interface{}{}, timeout)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("session/list error: %s", resp.Error.Message)
	}

	var payload struct {
		Sessions []struct {
			SessionID string `json:"sessionId"`
			CWD       string `json:"cwd"`
			Title     string `json:"title"`
		} `json:"sessions"`
	}
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &payload); err != nil {
			return nil, fmt.Errorf("decode session/list result: %w", err)
		}
	}

	sessions := make([]LoadableSession, 0, len(payload.Sessions))
	for _, s := range payload.Sessions {
		if s.SessionID == "" {
			continue
		}
		sessions = append(sessions, LoadableSession{
			SessionID: s.SessionID,
			CWD:       s.CWD,
			Title:     s.Title,
		})
	}
	return sessions, nil
}

// LoadableSessionIDs queries ACP session/list and returns the set of history
// session IDs that session/load can resolve.
func (p *ACPProxy) LoadableSessionIDs(timeout time.Duration) (map[string]struct{}, error) {
	sessions, err := p.LoadableSessions(timeout)
	if err != nil {
		return nil, err
	}
	ids := make(map[string]struct{}, len(sessions))
	for _, s := range sessions {
		ids[s.SessionID] = struct{}{}
	}
	return ids, nil
}

func (p *ACPProxy) callACPRequest(method string, params interface{}, timeout time.Duration) (*protocol.Message, error) {
	if p.State() == StateDead {
		return nil, fmt.Errorf("session is dead")
	}

	paramsJSON, err := json.Marshal(params)
	if err != nil {
		return nil, fmt.Errorf("marshal %s params: %w", method, err)
	}

	internalID := p.nextInternalID.Add(1)
	reqID := protocol.IntID(internalID)
	respCh := make(chan *protocol.Message, 1)

	p.pendingMu.Lock()
	p.pendingRequests[internalID] = PendingRequest{
		Method:     method,
		ResponseCh: respCh,
	}
	p.pendingMu.Unlock()

	if err := p.writeMessage(protocol.NewRequest(reqID, method, paramsJSON)); err != nil {
		p.pendingMu.Lock()
		delete(p.pendingRequests, internalID)
		p.pendingMu.Unlock()
		close(respCh)
		return nil, err
	}

	if timeout <= 0 {
		timeout = 1 * time.Second
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case resp, ok := <-respCh:
		if !ok || resp == nil {
			return nil, fmt.Errorf("%s request interrupted", method)
		}
		return resp, nil
	case <-timer.C:
		p.pendingMu.Lock()
		if pr, ok := p.pendingRequests[internalID]; ok {
			delete(p.pendingRequests, internalID)
			if pr.ResponseCh != nil {
				close(pr.ResponseCh)
			}
		}
		p.pendingMu.Unlock()
		return nil, fmt.Errorf("%s request timed out", method)
	case <-p.doneCh:
		p.pendingMu.Lock()
		if pr, ok := p.pendingRequests[internalID]; ok {
			delete(p.pendingRequests, internalID)
			if pr.ResponseCh != nil {
				close(pr.ResponseCh)
			}
		}
		p.pendingMu.Unlock()
		return nil, fmt.Errorf("ACP process exited")
	}
}

// Kill terminates the ACP process.
func (p *ACPProxy) Kill() {
	if p.cmd != nil && p.cmd.Process != nil {
		p.cmd.Process.Kill()
	}
}

func (p *ACPProxy) writeMessage(msg *protocol.Message) error {
	data, err := protocol.SerializeLine(msg)
	if err != nil {
		return err
	}
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	_, err = p.stdin.Write(data)
	return err
}

func isPromptComplete(msg *protocol.Message) bool {
	if msg.Params == nil {
		return false
	}
	var params struct {
		Update struct {
			SessionUpdate string `json:"sessionUpdate"`
		} `json:"update"`
	}
	if err := json.Unmarshal(*msg.Params, &params); err != nil {
		return false
	}
	return params.Update.SessionUpdate == "prompt_complete"
}
