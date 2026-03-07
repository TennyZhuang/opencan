package protocol

// Daemon method constants.
const (
	MethodDaemonHello              = "daemon/hello"
	MethodDaemonAgentProbe         = "daemon/agent.probe"
	MethodDaemonSessionList        = "daemon/session.list"
	MethodDaemonSessionKill        = "daemon/session.kill"
	MethodDaemonConversationCreate = "daemon/conversation.create"
	MethodDaemonConversationOpen   = "daemon/conversation.open"
	MethodDaemonConversationDetach = "daemon/conversation.detach"
	MethodDaemonConversationList   = "daemon/conversation.list"
	MethodDaemonLogs               = "daemon/logs"
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
