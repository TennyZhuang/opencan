package daemon

import "sync"

// LogBufferEntry is a structured daemon log entry returned by daemon/logs.
type LogBufferEntry struct {
	Timestamp string            `json:"timestamp"`
	Level     string            `json:"level"`
	Message   string            `json:"message"`
	Attrs     map[string]string `json:"attrs,omitempty"`
}

// LogRingBuffer stores recent daemon logs in memory for diagnostics.
type LogRingBuffer struct {
	mu      sync.RWMutex
	entries []LogBufferEntry
	maxSize int
}

// NewLogRingBuffer creates a log ring buffer.
func NewLogRingBuffer(maxSize int) *LogRingBuffer {
	if maxSize <= 0 {
		maxSize = 2000
	}
	return &LogRingBuffer{
		entries: make([]LogBufferEntry, 0, min(maxSize, 256)),
		maxSize: maxSize,
	}
}

// Append adds an entry and evicts old entries when over capacity.
func (b *LogRingBuffer) Append(entry LogBufferEntry) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.entries = append(b.entries, entry)
	if len(b.entries) > b.maxSize {
		excess := len(b.entries) - b.maxSize
		kept := make([]LogBufferEntry, b.maxSize)
		copy(kept, b.entries[excess:])
		b.entries = kept
	}
}

// Recent returns up to n most recent entries in chronological order.
func (b *LogRingBuffer) Recent(n int) []LogBufferEntry {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if n <= 0 || len(b.entries) == 0 {
		return nil
	}
	if n >= len(b.entries) {
		out := make([]LogBufferEntry, len(b.entries))
		copy(out, b.entries)
		return out
	}
	start := len(b.entries) - n
	out := make([]LogBufferEntry, n)
	copy(out, b.entries[start:])
	return out
}

// Filter returns entries whose attrs.traceId matches the given value.
func (b *LogRingBuffer) Filter(traceID string) []LogBufferEntry {
	if traceID == "" {
		return nil
	}
	b.mu.RLock()
	defer b.mu.RUnlock()

	filtered := make([]LogBufferEntry, 0)
	for _, entry := range b.entries {
		if entry.Attrs["traceId"] == traceID {
			filtered = append(filtered, entry)
		}
	}
	return filtered
}
