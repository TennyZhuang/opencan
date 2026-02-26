package proxy

import "testing"

func TestSessionState_String(t *testing.T) {
	tests := []struct {
		state SessionState
		want  string
	}{
		{StateStarting, "starting"},
		{StateIdle, "idle"},
		{StatePrompting, "prompting"},
		{StateDraining, "draining"},
		{StateCompleted, "completed"},
		{StateDead, "dead"},
	}

	for _, tt := range tests {
		if got := tt.state.String(); got != tt.want {
			t.Errorf("State(%d).String() = %q, want %q", tt.state, got, tt.want)
		}
	}
}

func TestSessionState_MarshalJSON(t *testing.T) {
	data, err := StateIdle.MarshalJSON()
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `"idle"` {
		t.Fatalf("expected '\"idle\"', got %q", string(data))
	}
}
