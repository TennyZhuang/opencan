package daemon

import (
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
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
	Command      string             `json:"command,omitempty"`
	Title        string             `json:"title,omitempty"`
	UpdatedAt    string             `json:"updatedAt,omitempty"`
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
	startedAt := time.Now()
	p, err := proxy.NewACPProxy(cwd, command, sm.logger)
	if err != nil {
		sm.logger.Error(
			"session create failed",
			"cwd", cwd,
			"command", command,
			"durationMs", time.Since(startedAt).Milliseconds(),
			"error", err,
		)
		return nil, fmt.Errorf("create ACP proxy: %w", err)
	}

	sm.mu.Lock()
	sm.sessions[p.SessionID] = p
	sm.mu.Unlock()

	sm.logger.Info(
		"session created",
		"sessionId", p.SessionID,
		"cwd", cwd,
		"command", command,
		"durationMs", time.Since(startedAt).Milliseconds(),
	)
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

// ListSessions returns info about all sessions, including external sessions
// discovered via ACP session/list that are not managed by this daemon.
func (sm *SessionManager) ListSessions() []SessionInfo {
	return sm.ListSessionsForCWD("")
}

// ListSessionsForCWD optionally scopes external discovery to a specific cwd.
func (sm *SessionManager) ListSessionsForCWD(cwd string) []SessionInfo {
	sm.mu.RLock()
	proxies := make([]*proxy.ACPProxy, 0, len(sm.sessions))
	for _, p := range sm.sessions {
		proxies = append(proxies, p)
	}
	sm.mu.RUnlock()

	// Collect the set of daemon-managed session IDs.
	// Always probe ACP session/list when we have any proxy available.
	// The result serves two purposes:
	//   1. Filter idle/completed daemon sessions that are no longer loadable.
	//   2. Discover external sessions not managed by this daemon.
	loadableSessions, hasLoadableSet := sm.loadableSessions(proxies, cwd)

	loadableIDs := make(map[string]struct{}, len(loadableSessions))
	for _, s := range loadableSessions {
		loadableIDs[s.SessionID] = struct{}{}
	}
	externalLimit := externalSessionLimit()

	// Dead managed entries can outlive their ACP process while the same session
	// remains loadable from backend storage. In that case, show it as External
	// instead of masking it as Dead.
	deadLoadableIDs := make(map[string]struct{})
	if hasLoadableSet {
		for _, p := range proxies {
			if p.State() != proxy.StateDead {
				continue
			}
			if _, ok := loadableIDs[p.SessionID]; ok {
				deadLoadableIDs[p.SessionID] = struct{}{}
			}
		}
	}

	// Collect daemon-managed IDs that should suppress external rows.
	daemonIDs := make(map[string]struct{}, len(proxies))
	for _, p := range proxies {
		if _, deadLoadable := deadLoadableIDs[p.SessionID]; deadLoadable {
			continue
		}
		daemonIDs[p.SessionID] = struct{}{}
	}

	estimatedCapacity := len(proxies)
	if hasLoadableSet {
		estimatedCapacity += min(len(loadableSessions), externalLimit)
	}
	infos := make([]SessionInfo, 0, estimatedCapacity)

	// Daemon-managed sessions (with loadability filtering for idle/completed).
	for _, p := range proxies {
		if _, deadLoadable := deadLoadableIDs[p.SessionID]; deadLoadable {
			sm.logger.Debug(
				"session is dead in daemon but loadable externally; exposing as external",
				"sessionId", p.SessionID,
			)
			continue
		}
		state := p.State()
		if shouldFilterSessionFromList(state, p.GetClient() == nil) && hasLoadableSet {
			if _, ok := loadableIDs[p.SessionID]; !ok {
				sm.logger.Debug("hiding non-loadable session from list", "sessionId", p.SessionID, "state", state)
				continue
			}
		}
		var updatedAt string
		if t := p.EventBuf().LastAppendAt(); !t.IsZero() {
			updatedAt = t.UTC().Format(time.RFC3339)
		}
		infos = append(infos, SessionInfo{
			SessionID:    p.SessionID,
			CWD:          p.CWD,
			State:        state,
			LastEventSeq: p.EventBuf().LastSeq(),
			Command:      p.Command,
			UpdatedAt:    updatedAt,
		})
	}

	// External sessions: in ACP list but not daemon-managed.
	if hasLoadableSet {
		externalCount := 0
		for _, ls := range loadableSessions {
			if externalCount >= externalLimit {
				break
			}
			if _, isDaemon := daemonIDs[ls.SessionID]; isDaemon {
				continue
			}
			infos = append(infos, SessionInfo{
				SessionID: ls.SessionID,
				CWD:       ls.CWD,
				State:     proxy.StateExternal,
				Title:     ls.Title,
				UpdatedAt: ls.UpdatedAt,
			})
			externalCount++
		}
	}

	return infos
}

func (sm *SessionManager) loadableSessions(proxies []*proxy.ACPProxy, discoveryCWD string) ([]proxy.LoadableSession, bool) {
	timeout := discoveryProbeTimeout()
	externalLimit := externalSessionLimit()

	seen := make(map[string]struct{}, externalLimit)
	merged := make([]proxy.LoadableSession, 0, externalLimit)
	appendSessions := func(items []proxy.LoadableSession) {
		for _, s := range items {
			if len(merged) >= externalLimit {
				return
			}
			if s.SessionID == "" {
				continue
			}
			if _, ok := seen[s.SessionID]; ok {
				continue
			}
			seen[s.SessionID] = struct{}{}
			merged = append(merged, s)
		}
	}

	probeByCommand := selectProxyProbeCandidates(proxies)
	proxyProbeSucceeded := false
	for _, p := range probeByCommand {
		sessions, err := p.LoadableSessionsForCWD(timeout, discoveryCWD)
		if err != nil {
			sm.logger.Warn(
				"session/loadability probe via managed proxy failed",
				"error", err,
				"cwd", discoveryCWD,
				"command", p.Command,
			)
			continue
		}
		proxyProbeSucceeded = true
		appendSessions(sessions)
	}

	commandsToProbe := make([]string, 0)
	if !proxyProbeSucceeded {
		// If managed-proxy probing failed (or there are no proxies), probe all
		// configured commands directly.
		commandsToProbe = append(commandsToProbe, discoveryProbeCommands()...)
	} else {
		// Managed proxies only represent one ACP command each; probe the rest.
		for _, command := range discoveryProbeCommands() {
			if _, ok := probeByCommand[commandSignature(command)]; ok {
				continue
			}
			commandsToProbe = append(commandsToProbe, command)
		}
	}

	if len(commandsToProbe) > 0 && len(merged) < externalLimit {
		discovered, err := sm.discoverExternalSessionsWithCommands(discoveryCWD, commandsToProbe, timeout)
		if err != nil {
			if !proxyProbeSucceeded {
				sm.logger.Warn(
					"session/loadability probe failed without managed sessions; returning managed list only",
					"error", err,
					"cwd", discoveryCWD,
				)
				return nil, false
			}
			sm.logger.Debug(
				"additional discovery probe commands failed; using managed-proxy results only",
				"error", err,
				"cwd", discoveryCWD,
			)
		} else {
			appendSessions(discovered)
		}
	}

	if !proxyProbeSucceeded && len(merged) == 0 {
		return nil, false
	}
	return merged, true
}

func (sm *SessionManager) discoverExternalSessionsWithoutProxy(discoveryCWD string) ([]proxy.LoadableSession, error) {
	return sm.discoverExternalSessionsWithCommands(discoveryCWD, discoveryProbeCommands(), discoveryProbeTimeout())
}

func (sm *SessionManager) discoverExternalSessionsWithCommands(
	discoveryCWD string,
	commands []string,
	timeout time.Duration,
) ([]proxy.LoadableSession, error) {
	if len(commands) == 0 {
		return nil, fmt.Errorf("no discovery commands configured")
	}
	if timeout <= 0 {
		timeout = discoveryProbeTimeout()
	}

	type probeResult struct {
		sessions []proxy.LoadableSession
		err      error
		command  string
	}

	results := make([]probeResult, len(commands))
	var wg sync.WaitGroup
	for i, command := range commands {
		wg.Add(1)
		go func(idx int, cmd string) {
			defer wg.Done()
			sessions, err := proxy.ProbeLoadableSessionsForCWD(cmd, discoveryCWD, timeout, sm.logger)
			results[idx] = probeResult{sessions: sessions, err: err, command: cmd}
		}(i, command)
	}
	wg.Wait()

	seen := make(map[string]struct{})
	merged := make([]proxy.LoadableSession, 0)
	var lastErr error
	succeeded := false
	externalLimit := externalSessionLimit()

resultsLoop:
	for _, r := range results {
		if len(merged) >= externalLimit {
			break
		}
		if r.err != nil {
			lastErr = r.err
			sm.logger.Debug(
				"external discovery probe command failed",
				"command", r.command,
				"cwd", discoveryCWD,
				"error", r.err,
			)
			continue
		}

		succeeded = true
		for _, s := range r.sessions {
			if len(merged) >= externalLimit {
				break resultsLoop
			}
			if s.SessionID == "" {
				continue
			}
			if _, ok := seen[s.SessionID]; ok {
				continue
			}
			seen[s.SessionID] = struct{}{}
			merged = append(merged, s)
		}
	}

	if !succeeded {
		if lastErr == nil {
			lastErr = fmt.Errorf("no probe command succeeded")
		}
		return nil, lastErr
	}
	return merged, nil
}

func selectProxyProbeCandidates(proxies []*proxy.ACPProxy) map[string]*proxy.ACPProxy {
	selected := make(map[string]*proxy.ACPProxy)
	selectedScore := make(map[string]int)
	for _, p := range proxies {
		score := proxyProbeScore(p)
		if score <= 0 {
			continue
		}
		key := commandSignature(p.Command)
		if current, ok := selectedScore[key]; ok && current >= score {
			continue
		}
		selected[key] = p
		selectedScore[key] = score
	}
	return selected
}

func proxyProbeScore(p *proxy.ACPProxy) int {
	if p == nil {
		return 0
	}
	state := p.State()
	if state == proxy.StateDead {
		return 0
	}
	hasClient := p.GetClient() != nil
	if (state == proxy.StateIdle || state == proxy.StateCompleted) && !hasClient {
		return 3
	}
	if !hasClient {
		return 2
	}
	return 1
}

func commandSignature(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	parsed, err := proxy.ParseLaunchCommand(trimmed)
	if err != nil {
		return trimmed
	}
	parts := append([]string{parsed.Executable}, parsed.Args...)
	return strings.Join(parts, " ")
}

func externalSessionLimit() int {
	const (
		defaultLimit = 2000
		hardLimit    = 20000
	)
	raw := strings.TrimSpace(os.Getenv("OPENCAN_MAX_EXTERNAL_SESSIONS"))
	if raw == "" {
		return defaultLimit
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 {
		return defaultLimit
	}
	if n > hardLimit {
		return hardLimit
	}
	return n
}

func discoveryProbeCommands() []string {
	raw := strings.TrimSpace(os.Getenv("OPENCAN_DISCOVERY_COMMANDS"))
	if raw == "" {
		return []string{"claude-agent-acp", "codex-acp"}
	}

	parts := strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == ';'
	})
	commands := make([]string, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		command := strings.TrimSpace(part)
		if command == "" {
			continue
		}
		if _, ok := seen[command]; ok {
			continue
		}
		seen[command] = struct{}{}
		commands = append(commands, command)
	}
	if len(commands) == 0 {
		return []string{"claude-agent-acp", "codex-acp"}
	}
	return commands
}

func discoveryProbeTimeout() time.Duration {
	const (
		defaultMs = 2500
		minMs     = 500
		maxMs     = 30000
	)

	raw := strings.TrimSpace(os.Getenv("OPENCAN_DISCOVERY_TIMEOUT_MS"))
	if raw == "" {
		return defaultMs * time.Millisecond
	}

	ms, err := strconv.Atoi(raw)
	if err != nil || ms <= 0 {
		return defaultMs * time.Millisecond
	}
	if ms < minMs {
		ms = minMs
	}
	if ms > maxMs {
		ms = maxMs
	}
	return time.Duration(ms) * time.Millisecond
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
