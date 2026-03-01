package protocol

// Daemon method constants.
const (
	MethodDaemonHello         = "daemon/hello"
	MethodDaemonAgentProbe    = "daemon/agent.probe"
	MethodDaemonSessionCreate = "daemon/session.create"
	MethodDaemonSessionAttach = "daemon/session.attach"
	MethodDaemonSessionDetach = "daemon/session.detach"
	MethodDaemonSessionList   = "daemon/session.list"
	MethodDaemonSessionKill   = "daemon/session.kill"
	MethodDaemonLogs          = "daemon/logs"
)

// ACP method constants (for daemon-internal use during session creation).
const (
	MethodInitialize    = "initialize"
	MethodSessionNew    = "session/new"
	MethodSessionPrompt = "session/prompt"
	MethodSessionUpdate = "session/update"
	MethodSessionList   = "session/list"
	MethodSessionLoad   = "session/load"
)
