package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"

	"github.com/anthropics/opencan-daemon/internal/protocol"
	"github.com/anthropics/opencan-daemon/internal/proxy"
)

// serverRequestMapping tracks a server-initiated request forwarded to the client.
type serverRequestMapping struct {
	originalID protocol.JSONRPCID
	proxy      *proxy.ACPProxy
}

// ClientHandler handles a single client connection (one per "opencan-daemon attach").
type ClientHandler struct {
	conn            net.Conn
	scanner         *bufio.Scanner
	attachedProxies map[string]*proxy.ACPProxy
	daemon          *Daemon
	logger          *slog.Logger

	writeMu sync.Mutex
	closed  bool

	// Server-initiated request routing: rewritten ID → original ID + source proxy.
	// When multiple proxies are attached, ACP processes may use overlapping request IDs.
	// We rewrite IDs when forwarding to the client and restore them when routing back.
	serverReqMu       sync.Mutex
	pendingServerReqs map[int64]serverRequestMapping
	nextServerReqID   int64
}

// NewClientHandler creates a handler for a client connection.
func NewClientHandler(conn net.Conn, daemon *Daemon, logger *slog.Logger) *ClientHandler {
	scanner := bufio.NewScanner(conn)
	// Requests can include large prompt payloads; keep headroom to avoid scanner
	// token truncation on valid JSON-RPC lines.
	scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)

	return &ClientHandler{
		conn:              conn,
		scanner:           scanner,
		attachedProxies:   make(map[string]*proxy.ACPProxy),
		daemon:            daemon,
		logger:            logger.With("component", "client_handler", "remote", conn.RemoteAddr()),
		pendingServerReqs: make(map[int64]serverRequestMapping),
		nextServerReqID:   5000, // Start high to avoid collision with client request IDs
	}
}

// Serve reads messages from the client and dispatches them.
// Blocks until the connection closes.
func (h *ClientHandler) Serve() {
	defer h.cleanup()

	for h.scanner.Scan() {
		line := append([]byte(nil), h.scanner.Bytes()...)
		msg, err := protocol.ParseLine(line)
		if err != nil {
			h.logger.Warn(
				"parse error",
				"error", err,
				"bytes", len(line),
				"preview", previewLine(line, 512),
			)
			if id, ok := protocol.ExtractIDFromPossiblyMalformedLine(line); ok {
				if sendErr := h.Send(protocol.NewErrorResponse(
					id,
					-32700,
					"Parse error: invalid JSON-RPC payload",
				)); sendErr != nil {
					h.logger.Warn("failed to send parse error response", "error", sendErr)
				}
			}
			continue
		}
		if msg == nil {
			continue
		}

		if msg.IsDaemonMethod() {
			h.handleDaemonMethod(msg)
		} else if msg.IsRequest() {
			h.handleACPRequest(msg)
		} else if msg.IsResponse() || msg.IsError() {
			// Client responding to a server-initiated request (e.g. permission)
			h.handleACPResponse(msg)
		}
	}

	if err := h.scanner.Err(); err != nil {
		if errors.Is(err, bufio.ErrTooLong) {
			h.logger.Warn("client disconnected: JSON-RPC line exceeded scanner limit", "error", err)
			return
		}
		h.logger.Info("client disconnected", "error", err)
	} else {
		h.logger.Info("client disconnected (EOF)")
	}
}

func (h *ClientHandler) cleanup() {
	// Detach from all sessions but don't kill them
	for sid, p := range h.attachedProxies {
		p.DetachClient(h)
		h.logger.Info("detached from session", "sessionId", sid)
	}
	h.attachedProxies = nil
	h.writeMu.Lock()
	h.closed = true
	h.writeMu.Unlock()
	h.conn.Close()
	h.daemon.clientDisconnected(h)
}

// Send sends a message to the client (implements proxy.ClientConn).
func (h *ClientHandler) Send(msg *protocol.Message) error {
	data, err := protocol.SerializeLine(msg)
	if err != nil {
		return err
	}
	h.writeMu.Lock()
	defer h.writeMu.Unlock()
	if h.closed {
		return fmt.Errorf("client connection closed")
	}
	return writeAll(h.conn, data)
}

func (h *ClientHandler) loggerForMessage(msg *protocol.Message) *slog.Logger {
	traceID := protocol.ExtractTraceID(msg)
	if traceID == "" {
		return h.logger
	}
	return h.logger.With("traceId", traceID)
}

func writeAll(w io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := w.Write(data)
		if n > 0 {
			data = data[n:]
		}
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}

func previewLine(line []byte, max int) string {
	if max <= 0 || len(line) <= max {
		return string(line)
	}
	return string(line[:max]) + "...(truncated)"
}

// handleDaemonMethod dispatches daemon/ prefixed methods.
func (h *ClientHandler) handleDaemonMethod(msg *protocol.Message) {
	logger := h.loggerForMessage(msg)
	if msg.ID == nil {
		// JSON-RPC notifications do not expect a response.
		// Ignore daemon notifications to avoid nil-id panics in handlers.
		logger.Warn("ignoring daemon notification", "method", msg.Method)
		return
	}
	logger.Info("daemon request", "method", msg.Method)

	switch msg.Method {
	case protocol.MethodDaemonHello:
		h.handleHello(msg)
	case protocol.MethodDaemonAgentProbe:
		h.handleAgentProbe(msg)
	case protocol.MethodDaemonSessionCreate:
		h.handleSessionCreate(msg)
	case protocol.MethodDaemonSessionAttach:
		h.handleSessionAttach(msg)
	case protocol.MethodDaemonSessionDetach:
		h.handleSessionDetach(msg)
	case protocol.MethodDaemonSessionList:
		h.handleSessionList(msg)
	case protocol.MethodDaemonSessionKill:
		h.handleSessionKill(msg)
	case protocol.MethodDaemonLogs:
		h.handleLogs(msg)
	default:
		if msg.ID != nil {
			h.Send(protocol.NewErrorResponse(*msg.ID, -32601, "Unknown daemon method: "+msg.Method))
		}
	}
}

func (h *ClientHandler) handleHello(msg *protocol.Message) {
	sessions := h.daemon.sessions.ListSessions()
	result, _ := json.Marshal(map[string]interface{}{
		"daemonVersion": "0.1.0",
		"sessions":      sessions,
	})
	h.Send(protocol.NewResponse(*msg.ID, result))
}

func (h *ClientHandler) handleAgentProbe(msg *protocol.Message) {
	var params struct {
		Agents []AgentProbeRequest `json:"agents"`
	}
	if msg.Params != nil {
		json.Unmarshal(*msg.Params, &params)
	}

	results := ProbeAgentCommands(params.Agents)
	result, _ := json.Marshal(map[string]interface{}{
		"agents": results,
	})
	h.Send(protocol.NewResponse(*msg.ID, result))
}

func (h *ClientHandler) handleSessionCreate(msg *protocol.Message) {
	var params struct {
		CWD     string `json:"cwd"`
		Command string `json:"command"`
	}
	if msg.Params != nil {
		json.Unmarshal(*msg.Params, &params)
	}
	if params.CWD == "" {
		h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "cwd is required"))
		return
	}
	if params.Command == "" {
		params.Command = "claude-agent-acp"
	}

	p, err := h.daemon.sessions.CreateSession(params.CWD, params.Command)
	if err != nil {
		h.Send(protocol.NewErrorResponse(*msg.ID, -32000, err.Error()))
		return
	}

	result, _ := json.Marshal(map[string]interface{}{
		"sessionId": p.SessionID,
	})
	h.Send(protocol.NewResponse(*msg.ID, result))
}

func (h *ClientHandler) handleSessionAttach(msg *protocol.Message) {
	logger := h.loggerForMessage(msg)
	var params struct {
		SessionID    string `json:"sessionId"`
		LastEventSeq uint64 `json:"lastEventSeq"`
		ClientID     string `json:"clientId"`
	}
	if msg.Params != nil {
		json.Unmarshal(*msg.Params, &params)
	}
	if params.SessionID == "" {
		h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "sessionId is required"))
		return
	}

	p, ok := h.daemon.sessions.GetSession(params.SessionID)
	if !ok {
		h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "session not found: "+params.SessionID))
		return
	}

	// Attach client (single owner per session)
	state, attached := p.TryAttachClientWithOwner(h, params.ClientID)
	if !attached {
		h.Send(protocol.NewErrorResponse(*msg.ID, -32000, "session already attached by another client: "+params.SessionID))
		return
	}
	h.attachedProxies[params.SessionID] = p

	// Get buffered events since lastEventSeq
	buffered := p.EventBuf().Since(params.LastEventSeq)

	result, _ := json.Marshal(map[string]interface{}{
		"state":          state.String(),
		"bufferedEvents": buffered,
	})
	h.Send(protocol.NewResponse(*msg.ID, result))
	logger.Info("attached to session", "sessionId", params.SessionID, "state", state, "bufferedEvents", len(buffered))
}

func (h *ClientHandler) handleSessionDetach(msg *protocol.Message) {
	var params struct {
		SessionID string `json:"sessionId"`
	}
	if msg.Params != nil {
		json.Unmarshal(*msg.Params, &params)
	}

	if p, ok := h.attachedProxies[params.SessionID]; ok {
		p.DetachClient(h)
		delete(h.attachedProxies, params.SessionID)
	}

	result, _ := json.Marshal(map[string]interface{}{})
	h.Send(protocol.NewResponse(*msg.ID, result))
}

func (h *ClientHandler) handleSessionList(msg *protocol.Message) {
	var params struct {
		CWD string `json:"cwd"`
	}
	if msg.Params != nil {
		if err := json.Unmarshal(*msg.Params, &params); err != nil {
			h.logger.Debug("failed to parse session list params", "error", err)
		}
	}

	sessions := h.daemon.sessions.ListSessionsForCWD(params.CWD)
	result, _ := json.Marshal(map[string]interface{}{
		"sessions": sessions,
	})
	h.Send(protocol.NewResponse(*msg.ID, result))
}

func (h *ClientHandler) handleSessionKill(msg *protocol.Message) {
	var params struct {
		SessionID string `json:"sessionId"`
	}
	if msg.Params != nil {
		json.Unmarshal(*msg.Params, &params)
	}

	// Detach if attached
	if p, ok := h.attachedProxies[params.SessionID]; ok {
		p.DetachClient(h)
		delete(h.attachedProxies, params.SessionID)
	}

	if err := h.daemon.sessions.KillSession(params.SessionID); err != nil {
		h.Send(protocol.NewErrorResponse(*msg.ID, -32000, err.Error()))
		return
	}

	result, _ := json.Marshal(map[string]interface{}{})
	h.Send(protocol.NewResponse(*msg.ID, result))
}

func (h *ClientHandler) handleLogs(msg *protocol.Message) {
	var params struct {
		Count   int    `json:"count"`
		TraceID string `json:"traceId"`
	}
	if msg.Params != nil {
		_ = json.Unmarshal(*msg.Params, &params)
	}
	if params.Count <= 0 {
		params.Count = 200
	}
	if params.Count > 2000 {
		params.Count = 2000
	}

	var entries []LogBufferEntry
	if params.TraceID != "" {
		entries = h.daemon.LogBuffer().Filter(params.TraceID)
		if len(entries) > params.Count {
			entries = entries[len(entries)-params.Count:]
		}
	} else {
		entries = h.daemon.LogBuffer().Recent(params.Count)
	}

	result, _ := json.Marshal(map[string]interface{}{
		"entries": entries,
	})
	h.Send(protocol.NewResponse(*msg.ID, result))
}

// handleACPRequest forwards non-daemon requests to the appropriate ACPProxy.
func (h *ClientHandler) handleACPRequest(msg *protocol.Message) {
	logger := h.loggerForMessage(msg)
	sessionID := protocol.ExtractSessionID(msg)
	if sessionID == "" {
		if msg.ID != nil {
			h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "sessionId required in params"))
		}
		return
	}

	// Support __routeToSession only for methods that intentionally decouple
	// the logical sessionId from the attached proxy session.
	routeID := sessionID
	if override := protocol.ExtractRouteToSession(msg); override != "" {
		if msg.Method == protocol.MethodSessionLoad || msg.Method == protocol.MethodSessionPrompt {
			routeID = override
			logger.Info("routing override", "method", msg.Method, "sessionId", sessionID, "routeToSession", routeID)
		} else {
			logger.Warn("ignoring routing override for unsupported method", "method", msg.Method, "sessionId", sessionID)
		}
	}

	p, ok := h.attachedProxies[routeID]
	if !ok {
		if msg.ID != nil {
			h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "not attached to session: "+routeID))
		}
		return
	}
	if p.GetClient() != h {
		logger.Warn("rejecting request from stale session owner", "sessionId", routeID, "method", msg.Method)
		if msg.ID != nil {
			h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "not attached to session: "+routeID))
		}
		return
	}

	if err := p.ForwardFromClient(msg, h); err != nil {
		logger.Error("forward to ACP", "error", err, "sessionId", sessionID)
		if msg.ID != nil {
			h.Send(protocol.NewErrorResponse(*msg.ID, -32000, "failed to forward: "+err.Error()))
		}
	}
}

// ForwardServerRequest rewrites the ID of a server-initiated request and tracks the
// mapping so the response can be routed back to the correct proxy. This prevents
// ID collisions when multiple ACP processes send requests with overlapping IDs.
func (h *ClientHandler) ForwardServerRequest(msg *protocol.Message, source *proxy.ACPProxy) error {
	if msg.ID == nil {
		return h.Send(msg)
	}

	h.serverReqMu.Lock()
	rewrittenID := h.nextServerReqID
	h.nextServerReqID++
	h.pendingServerReqs[rewrittenID] = serverRequestMapping{
		originalID: *msg.ID,
		proxy:      source,
	}
	h.serverReqMu.Unlock()

	fwd := msg.Clone()
	newID := protocol.IntID(rewrittenID)
	fwd.ID = &newID
	return h.Send(fwd)
}

// handleACPResponse routes client responses (e.g., permission decisions) back to
// the correct ACP proxy using the rewritten ID mapping.
func (h *ClientHandler) handleACPResponse(msg *protocol.Message) {
	if msg.ID == nil {
		return
	}
	rewrittenID := msg.ID.IntValue()

	h.serverReqMu.Lock()
	mapping, ok := h.pendingServerReqs[rewrittenID]
	if ok {
		delete(h.pendingServerReqs, rewrittenID)
	}
	h.serverReqMu.Unlock()

	if !ok {
		h.logger.Warn("response for unknown server request", "id", rewrittenID)
		return
	}

	// Restore the original ACP request ID and forward to the correct proxy
	fwd := msg.Clone()
	fwd.ID = &mapping.originalID
	mapping.proxy.ForwardFromClient(fwd, h)
}
