package daemon

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/anthropics/opencan-daemon/internal/protocol"
	"github.com/anthropics/opencan-daemon/internal/proxy"
)

func (h *ClientHandler) handleConversationCreate(msg *protocol.Message) {
	logger := h.loggerForMessage(msg)
	var params struct {
		CWD     string `json:"cwd"`
		Command string `json:"command"`
		OwnerID string `json:"ownerId"`
	}
	if msg.Params != nil {
		if err := json.Unmarshal(*msg.Params, &params); err != nil {
			h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "invalid params: "+err.Error()))
			return
		}
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

	state, buffered, err := h.attachConversationRuntime(p.SessionID, p, params.OwnerID, 0)
	if err != nil {
		_ = h.daemon.sessions.KillSession(p.SessionID)
		h.Send(protocol.NewErrorResponse(*msg.ID, -32000, err.Error()))
		return
	}

	conversation := newManagedConversationInfo(p.SessionID, p, state)
	result, _ := json.Marshal(map[string]interface{}{
		"conversation": conversation,
		"attachment": map[string]interface{}{
			"runtimeId":           p.SessionID,
			"state":               state.String(),
			"bufferedEvents":      buffered,
			"reusedRuntime":       false,
			"restoredFromHistory": false,
		},
	})
	h.Send(protocol.NewResponse(*msg.ID, result))
	logger.Info("conversation created", "conversationId", p.SessionID, "runtimeId", p.SessionID)
}

func (h *ClientHandler) handleConversationOpen(msg *protocol.Message) {
	logger := h.loggerForMessage(msg)
	var params struct {
		ConversationID   string `json:"conversationId"`
		OwnerID          string `json:"ownerId"`
		LastRuntimeID    string `json:"lastRuntimeId"`
		LastEventSeq     uint64 `json:"lastEventSeq"`
		PreferredCommand string `json:"preferredCommand"`
		CWDHint          string `json:"cwdHint"`
	}
	if msg.Params != nil {
		if err := json.Unmarshal(*msg.Params, &params); err != nil {
			h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "invalid params: "+err.Error()))
			return
		}
	}
	if params.ConversationID == "" {
		h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "conversationId is required"))
		return
	}

	if runtimeID, p, ok := h.daemon.sessions.GetConversation(params.ConversationID); ok {
		afterSeq := params.LastEventSeq
		if params.LastRuntimeID != "" && params.LastRuntimeID != runtimeID {
			afterSeq = 0
		}
		state, buffered, err := h.attachConversationRuntime(runtimeID, p, params.OwnerID, afterSeq)
		if err != nil {
			h.Send(protocol.NewErrorResponse(*msg.ID, -32000, err.Error()))
			return
		}
		conversation := newManagedConversationInfo(params.ConversationID, p, state)
		conversation.RuntimeID = runtimeID
		result, _ := json.Marshal(map[string]interface{}{
			"conversation": conversation,
			"attachment": map[string]interface{}{
				"runtimeId":           runtimeID,
				"state":               state.String(),
				"bufferedEvents":      buffered,
				"reusedRuntime":       true,
				"restoredFromHistory": false,
			},
		})
		h.Send(protocol.NewResponse(*msg.ID, result))
		logger.Info("conversation opened via existing runtime", "conversationId", params.ConversationID, "runtimeId", runtimeID)
		return
	}

	candidates, err := h.daemon.sessions.FindLoadableConversationCandidates(
		params.ConversationID,
		params.PreferredCommand,
	)
	if err != nil && len(candidates) == 0 {
		logger.Warn("conversation discovery failed", "conversationId", params.ConversationID, "error", err)
	}
	if len(candidates) == 0 {
		h.Send(protocol.NewErrorResponse(*msg.ID, -32000, "conversation not found: "+params.ConversationID))
		return
	}

	var lastRestoreErr error
	for _, candidate := range candidates {
		loadable := candidate.Session
		command := candidate.Command
		runtimeCWD := firstNonEmpty(loadable.CWD, params.CWDHint, ".")
		loadCWDs := conversationOpenLoadCWDCandidates(loadable.CWD, params.CWDHint)

		p, createErr := h.daemon.sessions.CreateSession(runtimeCWD, command)
		if createErr != nil {
			lastRestoreErr = createErr
			logger.Warn(
				"conversation restore runtime create failed",
				"conversationId", params.ConversationID,
				"command", command,
				"cwd", runtimeCWD,
				"error", createErr,
			)
			continue
		}

		var loadErr error
		var loadedCWD string
		for _, loadCWD := range loadCWDs {
			if err := p.LoadSession(params.ConversationID, loadCWD, conversationOpenLoadTimeout()); err != nil {
				loadErr = err
				logger.Warn(
					"conversation restore load failed",
					"conversationId", params.ConversationID,
					"runtimeId", p.SessionID,
					"command", command,
					"loadCwd", loadCWD,
					"error", err,
				)
				continue
			}
			loadedCWD = loadCWD
			loadErr = nil
			break
		}
		if loadErr != nil {
			_ = h.daemon.sessions.KillSession(p.SessionID)
			lastRestoreErr = fmt.Errorf("restore conversation: %w", loadErr)
			continue
		}
		if loadable.UpdatedAt == "" {
			loadable.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
		}

		h.daemon.sessions.AssignConversationRuntime(params.ConversationID, p.SessionID)
		state, buffered, err := h.attachConversationRuntime(p.SessionID, p, params.OwnerID, 0)
		if err != nil {
			_ = h.daemon.sessions.KillSession(p.SessionID)
			h.Send(protocol.NewErrorResponse(*msg.ID, -32000, err.Error()))
			return
		}
		conversation := newManagedConversationInfo(params.ConversationID, p, state)
		conversation.RuntimeID = p.SessionID
		if conversation.CWD == "" {
			conversation.CWD = runtimeCWD
		}
		if loadedCWD != "" {
			conversation.CWD = loadedCWD
		}
		if conversation.Title == "" {
			conversation.Title = loadable.Title
		}
		if conversation.UpdatedAt == "" {
			conversation.UpdatedAt = loadable.UpdatedAt
		}

		result, _ := json.Marshal(map[string]interface{}{
			"conversation": conversation,
			"attachment": map[string]interface{}{
				"runtimeId":           p.SessionID,
				"state":               state.String(),
				"bufferedEvents":      buffered,
				"reusedRuntime":       false,
				"restoredFromHistory": true,
			},
		})
		h.Send(protocol.NewResponse(*msg.ID, result))
		logger.Info(
			"conversation restored from history",
			"conversationId", params.ConversationID,
			"runtimeId", p.SessionID,
			"command", command,
			"loadCwd", loadedCWD,
		)
		return
	}

	if lastRestoreErr != nil {
		h.Send(protocol.NewErrorResponse(*msg.ID, -32000, lastRestoreErr.Error()))
		return
	}
	if err != nil {
		h.Send(protocol.NewErrorResponse(*msg.ID, -32000, err.Error()))
		return
	}
	h.Send(protocol.NewErrorResponse(*msg.ID, -32000, "conversation not found: "+params.ConversationID))
}

func (h *ClientHandler) handleConversationDetach(msg *protocol.Message) {
	var params struct {
		ConversationID string `json:"conversationId"`
	}
	if msg.Params != nil {
		if err := json.Unmarshal(*msg.Params, &params); err != nil {
			h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "invalid params: "+err.Error()))
			return
		}
	}
	if params.ConversationID == "" {
		h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "conversationId is required"))
		return
	}
	if runtimeID, p, ok := h.daemon.sessions.GetConversation(params.ConversationID); ok {
		if p.GetClient() == h {
			p.DetachClient(h)
			h.removeAttachedProxyIfMatches(runtimeID, p)
		}
	}
	result, _ := json.Marshal(map[string]interface{}{})
	h.Send(protocol.NewResponse(*msg.ID, result))
}

func (h *ClientHandler) handleConversationList(msg *protocol.Message) {
	var params struct {
		CWD string `json:"cwd"`
	}
	if msg.Params != nil {
		if err := json.Unmarshal(*msg.Params, &params); err != nil {
			h.logger.Debug("failed to parse conversation list params", "error", err)
		}
	}
	conversations := h.daemon.sessions.ListConversationsForCWD(params.CWD)
	result, _ := json.Marshal(map[string]interface{}{
		"conversations": conversations,
	})
	h.Send(protocol.NewResponse(*msg.ID, result))
}

func (h *ClientHandler) attachConversationRuntime(runtimeID string, p *proxy.ACPProxy, ownerID string, lastEventSeq uint64) (proxy.SessionState, []proxy.BufferedEvent, error) {
	previousClient := p.GetClient()
	state, attached := p.TryAttachClientWithOwner(h, ownerID)
	if !attached {
		return state, nil, fmt.Errorf("conversation already attached by another client: %s", runtimeID)
	}
	h.daemon.sessions.DetachOwnerFromOtherRuntimes(ownerID, runtimeID)
	h.setAttachedProxy(runtimeID, p)
	if previousClient != nil && previousClient != h {
		if previousHandler, ok := previousClient.(*ClientHandler); ok {
			if previousHandler.removeAttachedProxyIfMatches(runtimeID, p) {
				h.logger.Info("pruned stale attached proxy entry from previous owner", "sessionId", runtimeID)
			}
		}
	}
	h.detachOtherAttachedProxies(runtimeID)
	return state, p.BufferedEventsSince(lastEventSeq), nil
}

func (h *ClientHandler) detachOtherAttachedProxies(activeRuntimeID string) {
	for sessionID, p := range h.snapshotAttachedProxies() {
		if sessionID == activeRuntimeID || p == nil {
			continue
		}
		if removedProxy, ok := h.removeAttachedProxy(sessionID); ok && removedProxy != nil {
			removedProxy.DetachClient(h)
		}
	}
}

func newManagedConversationInfo(conversationID string, p *proxy.ACPProxy, state proxy.SessionState) ConversationInfo {
	derivedState := "ready"
	if p.GetClient() != nil {
		if state == proxy.StatePrompting || state == proxy.StateDraining || state == proxy.StateStarting {
			derivedState = "running"
		} else {
			derivedState = "attached"
		}
	} else if state == proxy.StatePrompting || state == proxy.StateDraining || state == proxy.StateStarting {
		derivedState = "running"
	}
	info := ConversationInfo{
		ConversationID: conversationID,
		RuntimeID:      p.SessionID,
		State:          derivedState,
		CWD:            p.CWD,
		Command:        p.Command,
		OwnerID:        p.CurrentOwnerID(),
		Origin:         "managed",
		LastEventSeq:   p.EventBuf().LastSeq(),
	}
	if updatedAt := p.EventBuf().LastAppendAt(); !updatedAt.IsZero() {
		info.UpdatedAt = updatedAt.UTC().Format(time.RFC3339)
	}
	return info
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
