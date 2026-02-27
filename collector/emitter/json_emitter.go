package emitter

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"
)

type CausalEvent struct {
	ID        string                 `json:"id"`
	Timestamp time.Time              `json:"timestamp"`
	EventType string                 `json:"event_type"`
	PatternID string                 `json:"pattern_id,omitempty"`
	PodName   string                 `json:"pod_name,omitempty"`
	Namespace string                 `json:"namespace,omitempty"`
	NodeName  string                 `json:"node_name,omitempty"`
	PodUID    string                 `json:"pod_uid,omitempty"`
	Payload   map[string]interface{} `json:"payload"`
}

type Snapshot struct {
	ID           string                 `json:"id"`
	Timestamp    time.Time              `json:"timestamp"`
	ObjectKind   string                 `json:"object_kind"`
	ObjectName   string                 `json:"object_name"`
	Namespace    string                 `json:"namespace,omitempty"`
	TriggerEvent string                 `json:"trigger_event"`
	State        map[string]interface{} `json:"state"`
}

type JSONEmitter struct {
	mu           sync.Mutex
	eventsFile   *os.File
	snapshotFile *os.File
}

func NewJSONEmitter(outputDir string) (*JSONEmitter, error) {
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create output dir: %w", err)
	}
	eventsFile, err := os.OpenFile(outputDir+"/events.jsonl", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return nil, fmt.Errorf("failed to open events file: %w", err)
	}
	snapshotFile, err := os.OpenFile(outputDir+"/snapshots.jsonl", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		eventsFile.Close()
		return nil, fmt.Errorf("failed to open snapshots file: %w", err)
	}
	fmt.Printf("[emitter] events    → %s/events.jsonl\n", outputDir)
	fmt.Printf("[emitter] snapshots → %s/snapshots.jsonl\n", outputDir)
	return &JSONEmitter{eventsFile: eventsFile, snapshotFile: snapshotFile}, nil
}

func (e *JSONEmitter) Emit(event CausalEvent) {
	e.mu.Lock()
	defer e.mu.Unlock()
	data, err := json.Marshal(event)
	if err != nil {
		fmt.Printf("[emitter] ERROR: %v\n", err)
		return
	}
	e.eventsFile.Write(append(data, '\n'))
	fmt.Printf("[emitter] %-22s pattern=%-5s pod=%s\n", event.EventType, event.PatternID, event.PodName)
}

func (e *JSONEmitter) EmitSnapshot(snapshot Snapshot) {
	e.mu.Lock()
	defer e.mu.Unlock()
	data, err := json.Marshal(snapshot)
	if err != nil {
		fmt.Printf("[emitter] ERROR: %v\n", err)
		return
	}
	e.snapshotFile.Write(append(data, '\n'))
	fmt.Printf("[emitter] snapshot  %-12s name=%s trigger=%s\n", snapshot.ObjectKind, snapshot.ObjectName, snapshot.TriggerEvent)
}

func (e *JSONEmitter) Close() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.eventsFile.Sync()
	e.eventsFile.Close()
	e.snapshotFile.Sync()
	e.snapshotFile.Close()
	fmt.Println("[emitter] Closed.")
}
