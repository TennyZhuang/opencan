package proxy

import (
	"encoding/json"
	"sync"
	"time"
)

// BufferedEvent is a notification event with a sequence number.
type BufferedEvent struct {
	Seq   uint64          `json:"seq"`
	Event json.RawMessage `json:"event"`
}

// EventBuffer is a thread-safe ring buffer that stores JSON-RPC notifications
// with monotonically increasing sequence numbers.
type EventBuffer struct {
	mu           sync.RWMutex
	events       []BufferedEvent
	nextSeq      uint64
	maxSize      int
	lastAppendAt time.Time
}

// NewEventBuffer creates a new EventBuffer with the given maximum size.
func NewEventBuffer(maxSize int) *EventBuffer {
	if maxSize <= 0 {
		maxSize = 10000
	}
	return &EventBuffer{
		events:  make([]BufferedEvent, 0, 256),
		nextSeq: 1,
		maxSize: maxSize,
	}
}

// Append adds an event to the buffer and returns its assigned sequence number.
func (b *EventBuffer) Append(event json.RawMessage) uint64 {
	b.mu.Lock()
	defer b.mu.Unlock()

	seq := b.nextSeq
	b.nextSeq++
	b.lastAppendAt = time.Now()

	b.events = append(b.events, BufferedEvent{
		Seq:   seq,
		Event: event,
	})

	// Evict oldest events if over capacity.
	// Copy to a new slice so the old backing array can be GC'd.
	if len(b.events) > b.maxSize {
		excess := len(b.events) - b.maxSize
		kept := make([]BufferedEvent, b.maxSize)
		copy(kept, b.events[excess:])
		b.events = kept
	}

	return seq
}

// Since returns all events with seq > afterSeq.
// Returns nil if no events match.
func (b *EventBuffer) Since(afterSeq uint64) []BufferedEvent {
	b.mu.RLock()
	defer b.mu.RUnlock()

	for i, e := range b.events {
		if e.Seq > afterSeq {
			result := make([]BufferedEvent, len(b.events)-i)
			copy(result, b.events[i:])
			return result
		}
	}
	return nil
}

// LastSeq returns the highest sequence number in the buffer, or 0 if empty.
func (b *EventBuffer) LastSeq() uint64 {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if len(b.events) == 0 {
		return 0
	}
	return b.events[len(b.events)-1].Seq
}

// Len returns the current number of events in the buffer.
func (b *EventBuffer) Len() int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return len(b.events)
}

// LastAppendAt returns the time of the most recent Append call, or zero if empty.
func (b *EventBuffer) LastAppendAt() time.Time {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.lastAppendAt
}
