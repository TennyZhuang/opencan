package proxy

import (
	"encoding/json"
	"sync"

	"github.com/gammazero/deque"
)

// BufferedEvent is a notification event with a sequence number.
type BufferedEvent struct {
	Seq   uint64          `json:"seq"`
	Event json.RawMessage `json:"event"`
}

// EventBuffer is a thread-safe ring buffer that stores JSON-RPC notifications
// with monotonically increasing sequence numbers.
type EventBuffer struct {
	mu      sync.RWMutex
	events  deque.Deque[BufferedEvent]
	nextSeq uint64
	maxSize int
}

// NewEventBuffer creates a new EventBuffer with the given maximum size.
func NewEventBuffer(maxSize int) *EventBuffer {
	if maxSize <= 0 {
		maxSize = 10000
	}
	var events deque.Deque[BufferedEvent]
	events.SetBaseCap(min(maxSize, 256))
	return &EventBuffer{
		events:  events,
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

	b.events.PushBack(BufferedEvent{
		Seq:   seq,
		Event: event,
	})

	// Evict oldest events if over capacity.
	for b.events.Len() > b.maxSize {
		b.events.PopFront()
	}

	return seq
}

// Since returns all events with seq > afterSeq.
// Returns nil if no events match.
func (b *EventBuffer) Since(afterSeq uint64) []BufferedEvent {
	b.mu.RLock()
	defer b.mu.RUnlock()

	n := b.events.Len()
	start := -1
	for i := 0; i < n; i++ {
		if b.events.At(i).Seq > afterSeq {
			start = i
			break
		}
	}
	if start >= 0 {
		result := make([]BufferedEvent, 0, n-start)
		for i := start; i < n; i++ {
			result = append(result, b.events.At(i))
		}
		return result
	}
	return nil
}

// LastSeq returns the highest sequence number in the buffer, or 0 if empty.
func (b *EventBuffer) LastSeq() uint64 {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if b.events.Len() == 0 {
		return 0
	}
	return b.events.Back().Seq
}

// Len returns the current number of events in the buffer.
func (b *EventBuffer) Len() int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.events.Len()
}
