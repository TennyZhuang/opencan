package daemon

import (
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/anthropics/opencan-daemon/internal/proxy"
)

// SessionInfo is a snapshot of a session's state for listing.
type SessionInfo struct {
	SessionID    string             `json:"sessionId"`
	CWD          string             `json:"cwd"`
	State        proxy.SessionState `json:"state"`
	LastEventSeq uint64             `json:"lastEventSeq"`
}

// SessionManager manages all ACPProxy instances.
type SessionManager struct {
	mu       sync.RWMutex
	sessions map[string]*proxy.ACPProxy
	logger   *slog.Logger
}

// NewSessionManager creates a new SessionManager.
func NewSessionManager(logger *slog.Logger) *SessionManager {
	return &SessionManager{
		sessions: make(map[string]*proxy.ACPProxy),
		logger:   logger.With("component", "session_manager"),
	}
}

// CreateSession spawns a new ACP process and registers the proxy.
func (sm *SessionManager) CreateSession(cwd, command string) (*proxy.ACPProxy, error) {
	p, err := proxy.NewACPProxy(cwd, command, sm.logger)
	if err != nil {
		return nil, fmt.Errorf("create ACP proxy: %w", err)
	}

	sm.mu.Lock()
	sm.sessions[p.SessionID] = p
	sm.mu.Unlock()

	sm.logger.Info("session created", "sessionId", p.SessionID, "cwd", cwd)
	return p, nil
}

// GetSession returns the proxy for the given session ID.
func (sm *SessionManager) GetSession(sessionID string) (*proxy.ACPProxy, bool) {
	sm.mu.RLock()
	p, ok := sm.sessions[sessionID]
	sm.mu.RUnlock()
	if !ok {
		return nil, false
	}
	if p.State() != proxy.StateDead {
		return p, true
	}

	// Opportunistically prune dead sessions on lookup so callers don't attach
	// to stale entries that can no longer service requests.
	sm.mu.Lock()
	if current, ok := sm.sessions[sessionID]; ok && current.State() == proxy.StateDead {
		delete(sm.sessions, sessionID)
	}
	sm.mu.Unlock()
	return nil, false
}

// ListSessions returns info about all sessions.
func (sm *SessionManager) ListSessions() []SessionInfo {
	sm.mu.RLock()
	proxies := make([]*proxy.ACPProxy, 0, len(sm.sessions))
	for _, p := range sm.sessions {
		proxies = append(proxies, p)
	}
	sm.mu.RUnlock()

	needsLoadabilityProbe := false
	for _, p := range proxies {
		if shouldFilterSessionFromList(p.State(), p.GetClient() == nil) {
			needsLoadabilityProbe = true
			break
		}
	}

	var loadableSessionIDs map[string]struct{}
	hasLoadableSet := false
	if needsLoadabilityProbe {
		loadableSessionIDs, hasLoadableSet = sm.loadableSessionSet(proxies)
	}

	infos := make([]SessionInfo, 0, len(proxies))
	for _, p := range proxies {
		state := p.State()
		if shouldFilterSessionFromList(state, p.GetClient() == nil) && hasLoadableSet {
			if _, ok := loadableSessionIDs[p.SessionID]; !ok {
				sm.logger.Debug("hiding non-loadable session from list", "sessionId", p.SessionID, "state", state)
				continue
			}
		}
		infos = append(infos, SessionInfo{
			SessionID:    p.SessionID,
			CWD:          p.CWD,
			State:        state,
			LastEventSeq: p.EventBuf().LastSeq(),
		})
	}
	return infos
}

func (sm *SessionManager) loadableSessionSet(proxies []*proxy.ACPProxy) (map[string]struct{}, bool) {
	var probe *proxy.ACPProxy
	for _, p := range proxies {
		state := p.State()
		hasClient := p.GetClient() != nil
		if (state == proxy.StateIdle || state == proxy.StateCompleted) && !hasClient {
			probe = p
			break
		}
		if probe == nil && state != proxy.StateDead && !hasClient {
			probe = p
		}
	}
	if probe == nil {
		for _, p := range proxies {
			if p.State() != proxy.StateDead {
				probe = p
				break
			}
		}
	}

	if probe == nil {
		return nil, false
	}

	ids, err := probe.LoadableSessionIDs(1200 * time.Millisecond)
	if err != nil {
		sm.logger.Warn("session/loadability probe failed; returning unfiltered list", "error", err)
		return nil, false
	}
	return ids, true
}

func shouldFilterSessionFromList(state proxy.SessionState, hasNoAttachedClient bool) bool {
	if !hasNoAttachedClient {
		return false
	}
	return state == proxy.StateIdle || state == proxy.StateCompleted
}

// KillSession terminates the ACP process for the given session.
func (sm *SessionManager) KillSession(sessionID string) error {
	sm.mu.Lock()
	p, ok := sm.sessions[sessionID]
	if ok {
		delete(sm.sessions, sessionID)
	}
	sm.mu.Unlock()

	if !ok {
		return fmt.Errorf("session not found: %s", sessionID)
	}

	p.Kill()
	sm.logger.Info("session killed", "sessionId", sessionID)
	return nil
}

// RemoveDead removes sessions in Dead state from the map.
func (sm *SessionManager) RemoveDead() int {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	removed := 0
	for id, p := range sm.sessions {
		if p.State() == proxy.StateDead {
			delete(sm.sessions, id)
			removed++
		}
	}
	return removed
}

// Count returns the number of active sessions.
func (sm *SessionManager) Count() int {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return len(sm.sessions)
}

// IsIdle returns true if there are no sessions or all are Dead/Completed.
func (sm *SessionManager) IsIdle() bool {
	sm.mu.RLock()
	defer sm.mu.RUnlock()

	for _, p := range sm.sessions {
		s := p.State()
		if s != proxy.StateDead && s != proxy.StateCompleted {
			return false
		}
	}
	return true
}
