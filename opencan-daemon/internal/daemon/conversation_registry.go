package daemon

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/anthropics/opencan-daemon/internal/proxy"
)

// ConversationInfo is the daemon-owned view exposed by daemon/conversation.list.
type ConversationInfo struct {
	ConversationID string `json:"conversationId"`
	RuntimeID      string `json:"runtimeId,omitempty"`
	State          string `json:"state"`
	CWD            string `json:"cwd,omitempty"`
	Command        string `json:"command,omitempty"`
	Title          string `json:"title,omitempty"`
	UpdatedAt      string `json:"updatedAt,omitempty"`
	OwnerID        string `json:"ownerId,omitempty"`
	Origin         string `json:"origin,omitempty"`
	LastEventSeq   uint64 `json:"lastEventSeq,omitempty"`
}

type LoadableConversationCandidate struct {
	Session proxy.LoadableSession
	Command string
}

func (sm *SessionManager) assignConversationRuntimeLocked(conversationID, runtimeID string) {
	if conversationID == "" || runtimeID == "" {
		return
	}
	if previousRuntimeID, ok := sm.conversationRuntimeIDs[conversationID]; ok && previousRuntimeID != runtimeID {
		delete(sm.runtimeConversationIDs, previousRuntimeID)
		if previousProxy, ok := sm.sessions[previousRuntimeID]; ok {
			previousProxy.SetConversationID(previousRuntimeID)
		}
	}
	if previousConversationID, ok := sm.runtimeConversationIDs[runtimeID]; ok && previousConversationID != conversationID {
		delete(sm.conversationRuntimeIDs, previousConversationID)
	}
	sm.conversationRuntimeIDs[conversationID] = runtimeID
	sm.runtimeConversationIDs[runtimeID] = conversationID
	if p, ok := sm.sessions[runtimeID]; ok {
		p.SetConversationID(conversationID)
	}
}

func (sm *SessionManager) AssignConversationRuntime(conversationID, runtimeID string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	sm.assignConversationRuntimeLocked(conversationID, runtimeID)
}

func (sm *SessionManager) removeRuntimeMappingLocked(runtimeID string) {
	if runtimeID == "" {
		return
	}
	conversationID, ok := sm.runtimeConversationIDs[runtimeID]
	if !ok {
		if currentRuntimeID, ok := sm.conversationRuntimeIDs[runtimeID]; ok && currentRuntimeID == runtimeID {
			delete(sm.conversationRuntimeIDs, runtimeID)
		}
		if p, ok := sm.sessions[runtimeID]; ok {
			p.SetConversationID(runtimeID)
		}
		return
	}
	delete(sm.runtimeConversationIDs, runtimeID)
	if currentRuntimeID, ok := sm.conversationRuntimeIDs[conversationID]; ok && currentRuntimeID == runtimeID {
		delete(sm.conversationRuntimeIDs, conversationID)
	}
	if p, ok := sm.sessions[runtimeID]; ok {
		p.SetConversationID(runtimeID)
	}
}

func (sm *SessionManager) ConversationIDForRuntime(runtimeID string) string {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	if conversationID, ok := sm.runtimeConversationIDs[runtimeID]; ok && conversationID != "" {
		return conversationID
	}
	return runtimeID
}

func (sm *SessionManager) DetachOwnerFromOtherRuntimes(ownerID, exceptRuntimeID string) {
	ownerID = strings.TrimSpace(ownerID)
	if ownerID == "" {
		return
	}

	sm.mu.RLock()
	proxies := make([]*proxy.ACPProxy, 0, len(sm.sessions))
	for _, p := range sm.sessions {
		proxies = append(proxies, p)
	}
	sm.mu.RUnlock()

	for _, p := range proxies {
		if p == nil || p.SessionID == exceptRuntimeID {
			continue
		}
		if p.CurrentOwnerID() != ownerID {
			continue
		}
		client := p.GetClient()
		if client == nil {
			continue
		}
		p.DetachClient(client)
		if previousHandler, ok := client.(*ClientHandler); ok {
			previousHandler.removeAttachedProxyIfMatches(p.SessionID, p)
		}
	}
}

func (sm *SessionManager) GetConversation(conversationID string) (string, *proxy.ACPProxy, bool) {
	sm.mu.RLock()
	runtimeID, ok := sm.conversationRuntimeIDs[conversationID]
	if !ok {
		runtimeID = conversationID
	}
	p, ok := sm.sessions[runtimeID]
	sm.mu.RUnlock()
	if !ok {
		sm.mu.Lock()
		if currentRuntimeID, exists := sm.conversationRuntimeIDs[conversationID]; exists && currentRuntimeID == runtimeID {
			delete(sm.conversationRuntimeIDs, conversationID)
		}
		delete(sm.runtimeConversationIDs, runtimeID)
		sm.mu.Unlock()
		return "", nil, false
	}
	if p.State() != proxy.StateDead {
		return runtimeID, p, true
	}

	sm.mu.Lock()
	if current, ok := sm.sessions[runtimeID]; ok && current.State() == proxy.StateDead {
		delete(sm.sessions, runtimeID)
		sm.removeRuntimeMappingLocked(runtimeID)
	}
	sm.mu.Unlock()
	return "", nil, false
}

func (sm *SessionManager) ListConversationsForCWD(cwd string) []ConversationInfo {
	sessionInfos := sm.ListSessionsForCWD(cwd)

	sm.mu.RLock()
	runtimeToConversation := make(map[string]string, len(sm.runtimeConversationIDs))
	for runtimeID, conversationID := range sm.runtimeConversationIDs {
		runtimeToConversation[runtimeID] = conversationID
	}
	sm.mu.RUnlock()

	byConversation := make(map[string]ConversationInfo, len(sessionInfos))
	for _, sessionInfo := range sessionInfos {
		conversationInfo := conversationInfoFromSessionInfo(sessionInfo, runtimeToConversation)
		existing, ok := byConversation[conversationInfo.ConversationID]
		if !ok || shouldReplaceConversationInfo(existing, conversationInfo) {
			byConversation[conversationInfo.ConversationID] = conversationInfo
		}
	}

	conversations := make([]ConversationInfo, 0, len(byConversation))
	for _, conversationInfo := range byConversation {
		conversations = append(conversations, conversationInfo)
	}
	sort.Slice(conversations, func(i, j int) bool {
		if conversations[i].UpdatedAt != conversations[j].UpdatedAt {
			return conversations[i].UpdatedAt > conversations[j].UpdatedAt
		}
		return conversations[i].ConversationID < conversations[j].ConversationID
	})
	return conversations
}

func conversationInfoFromSessionInfo(sessionInfo SessionInfo, runtimeToConversation map[string]string) ConversationInfo {
	conversationID := sessionInfo.SessionID
	runtimeID := sessionInfo.SessionID
	origin := "managed"
	if sessionInfo.State == proxy.StateExternal {
		runtimeID = ""
		origin = "discovered"
	} else if mappedConversationID, ok := runtimeToConversation[sessionInfo.SessionID]; ok && mappedConversationID != "" {
		conversationID = mappedConversationID
	}
	return ConversationInfo{
		ConversationID: conversationID,
		RuntimeID:      runtimeID,
		State:          conversationStateFromSessionInfo(sessionInfo),
		CWD:            sessionInfo.CWD,
		Command:        sessionInfo.Command,
		Title:          sessionInfo.Title,
		UpdatedAt:      sessionInfo.UpdatedAt,
		OwnerID:        sessionInfo.OwnerID,
		Origin:         origin,
		LastEventSeq:   sessionInfo.LastEventSeq,
	}
}

func conversationStateFromSessionInfo(sessionInfo SessionInfo) string {
	switch sessionInfo.State {
	case proxy.StateExternal:
		return "restorable"
	case proxy.StateDead:
		return "unavailable"
	case proxy.StateStarting, proxy.StatePrompting, proxy.StateDraining:
		return "running"
	case proxy.StateIdle, proxy.StateCompleted:
		if sessionInfo.Attached {
			return "attached"
		}
		return "ready"
	default:
		if sessionInfo.Attached {
			return "attached"
		}
		return "ready"
	}
}

func shouldReplaceConversationInfo(current, candidate ConversationInfo) bool {
	if current.Origin != candidate.Origin {
		return candidate.Origin == "managed"
	}
	if current.RuntimeID == "" && candidate.RuntimeID != "" {
		return true
	}
	currentScore := conversationStateScore(current.State)
	candidateScore := conversationStateScore(candidate.State)
	if currentScore != candidateScore {
		return candidateScore > currentScore
	}
	return candidate.UpdatedAt > current.UpdatedAt
}

func conversationStateScore(state string) int {
	switch strings.TrimSpace(state) {
	case "running":
		return 4
	case "attached":
		return 3
	case "ready":
		return 2
	case "restorable":
		return 1
	default:
		return 0
	}
}

func (sm *SessionManager) FindLoadableConversation(conversationID, preferredCommand string) (proxy.LoadableSession, string, bool, error) {
	candidates, err := sm.FindLoadableConversationCandidates(conversationID, preferredCommand)
	if len(candidates) == 0 {
		return proxy.LoadableSession{}, "", false, err
	}
	candidate := candidates[0]
	return candidate.Session, candidate.Command, true, nil
}

func (sm *SessionManager) FindLoadableConversationCandidates(conversationID, preferredCommand string) ([]LoadableConversationCandidate, error) {
	commands := orderedConversationOpenCommands(preferredCommand)
	timeout := discoveryProbeTimeout()
	candidates := make([]LoadableConversationCandidate, 0, len(commands))
	var lastErr error
	for _, command := range commands {
		sessions, err := proxy.ProbeLoadableSessionsForCWD(command, "", timeout, sm.logger)
		if err != nil {
			lastErr = err
			continue
		}
		for _, session := range sessions {
			if session.SessionID == conversationID {
				candidates = append(candidates, LoadableConversationCandidate{
					Session: session,
					Command: command,
				})
				break
			}
		}
	}
	if len(candidates) == 0 && lastErr == nil {
		lastErr = fmt.Errorf("conversation not found: %s", conversationID)
	}
	return candidates, lastErr
}

func orderedConversationOpenCommands(preferredCommand string) []string {
	commands := make([]string, 0, 1+len(discoveryProbeCommands()))
	seen := make(map[string]struct{})
	appendCommand := func(raw string) {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" {
			return
		}
		key := commandSignature(trimmed)
		if _, ok := seen[key]; ok {
			return
		}
		seen[key] = struct{}{}
		commands = append(commands, trimmed)
	}
	appendCommand(preferredCommand)
	for _, command := range discoveryProbeCommands() {
		appendCommand(command)
	}
	return commands
}

func conversationOpenLoadCWDCandidates(values ...string) []string {
	candidates := make([]string, 0, len(values)+1)
	seen := make(map[string]struct{})
	appendValue := func(raw string) {
		trimmed := strings.TrimSpace(raw)
		if _, ok := seen[trimmed]; ok {
			return
		}
		seen[trimmed] = struct{}{}
		candidates = append(candidates, trimmed)
	}
	for _, value := range values {
		appendValue(value)
	}
	if len(candidates) == 0 {
		candidates = append(candidates, "")
	}
	return candidates
}

func conversationOpenLoadTimeout() time.Duration {
	return 10 * time.Second
}
