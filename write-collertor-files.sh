#!/bin/bash
# Run this from the root of k8s-causal-memory/
# It writes all Go source files for the collector.

set -e
echo "Writing collector Go files..."

# ── patterns/patterns.go ─────────────────────────────────────────────────────
cat > collector/patterns/patterns.go << 'EOF'
package patterns

// CausalPattern defines a named, multi-step causal chain that the
// collector encodes into captured events.
type CausalPattern struct {
	ID                 string        `json:"id"`
	Name               string        `json:"name"`
	Description        string        `json:"description"`
	Steps              []PatternStep `json:"steps"`
	RemediationActions []string      `json:"remediation_actions"`
}

// PatternStep defines one event in a causal chain.
type PatternStep struct {
	EventType   string `json:"event_type"`
	Role        string `json:"role"`       // trigger, precursor, effect, evidence, absence
	Optional    bool   `json:"optional"`
	WindowSecs  int    `json:"window_secs"`
	Description string `json:"description"`
}

// AllPatterns is the registry of all encoded causal patterns.
var AllPatterns = map[string]CausalPattern{
	PatternOOMKill:        OOMKillPattern,
	PatternConfigMapEnv:   ConfigMapEnvPattern,
	PatternConfigMapMount: ConfigMapMountPattern,
}
EOF

# ── patterns/oomkill.go ───────────────────────────────────────────────────────
cat > collector/patterns/oomkill.go << 'EOF'
package patterns

// PatternOOMKill is the causal pattern ID for OOMKill chains.
// Pattern: MemoryPressure → OOMKill → ContainerRestart → EvidenceRotation
//
// Empirically documented in:
// "When Kubernetes Forgets: The 90-Second Evidence Gap"
// https://opscart.com/when-kubernetes-forgets-the-90-second-evidence-gap/
const PatternOOMKill = "P001"

var OOMKillPattern = CausalPattern{
	ID:          PatternOOMKill,
	Name:        "OOMKill Causal Chain",
	Description: "Memory pressure leading to kernel OOMKill and evidence rotation",
	Steps: []PatternStep{
		{
			EventType:   "NodeMemoryPressure",
			Role:        "precursor",
			Optional:    true,
			WindowSecs:  300,
			Description: "Node memory pressure preceding OOMKill",
		},
		{
			EventType:   "OOMKill",
			Role:        "trigger",
			Optional:    false,
			WindowSecs:  0,
			Description: "Kernel OOM killer terminates container",
		},
		{
			EventType:   "OOMKillEvidence",
			Role:        "evidence",
			Optional:    true,
			WindowSecs:  90,
			Description: "LastTerminationState evidence before 90s rotation",
		},
		{
			EventType:   "ContainerTerminated",
			Role:        "effect",
			Optional:    false,
			WindowSecs:  10,
			Description: "Container restart following OOMKill",
		},
	},
	RemediationActions: []string{
		"increase_memory_limit",
		"add_vpa_recommendation",
		"alert_engineering",
	},
}
EOF

# ── patterns/configmap_env.go ─────────────────────────────────────────────────
cat > collector/patterns/configmap_env.go << 'EOF'
package patterns

// PatternConfigMapEnv is the causal pattern ID for ConfigMap env var
// silent misconfiguration.
// Pattern: ConfigMapChanged → PodNotRestarted → StaleConfigInEffect
//
// Reference: "When Kubernetes Restarts Your Pod"
// https://opscart.com/when-kubernetes-restarts-your-pod/
const PatternConfigMapEnv = "P002"

var ConfigMapEnvPattern = CausalPattern{
	ID:          PatternConfigMapEnv,
	Name:        "ConfigMap Env Var Silent Misconfiguration",
	Description: "ConfigMap update not propagated to pods consuming it as env vars",
	Steps: []PatternStep{
		{
			EventType:   "ConfigMapChanged",
			Role:        "trigger",
			Optional:    false,
			WindowSecs:  0,
			Description: "ConfigMap content changed",
		},
		{
			EventType:   "PodNotRestarted",
			Role:        "absence",
			Optional:    false,
			WindowSecs:  120,
			Description: "No pod restart observed for env var consumers",
		},
	},
	RemediationActions: []string{
		"rollout_restart_deployment",
		"alert_config_drift",
	},
}
EOF

# ── patterns/configmap_mount.go ───────────────────────────────────────────────
cat > collector/patterns/configmap_mount.go << 'EOF'
package patterns

// PatternConfigMapMount is the causal pattern ID for ConfigMap volume
// mount symlink swap propagation.
// Pattern: ConfigMapChanged → KubeletSymlinkSwap → inotifyFires → AppReloads
//
// Reference: "When Kubernetes Restarts Your Pod"
// https://opscart.com/when-kubernetes-restarts-your-pod/
const PatternConfigMapMount = "P003"

var ConfigMapMountPattern = CausalPattern{
	ID:          PatternConfigMapMount,
	Name:        "ConfigMap Volume Mount Symlink Swap",
	Description: "ConfigMap update propagated via kubelet atomic symlink swap",
	Steps: []PatternStep{
		{
			EventType:   "ConfigMapChanged",
			Role:        "trigger",
			Optional:    false,
			WindowSecs:  0,
			Description: "ConfigMap content changed",
		},
		{
			EventType:   "KubeletSync",
			Role:        "propagation",
			Optional:    true,
			WindowSecs:  90,
			Description: "Kubelet syncs ConfigMap via symlink swap",
		},
	},
	RemediationActions: []string{
		"verify_inotify_watch_pattern",
		"check_app_reload_logs",
	},
}
EOF

# ── emitter/json_emitter.go ───────────────────────────────────────────────────
cat > collector/emitter/json_emitter.go << 'EOF'
package emitter

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"
)

// CausalEvent is the structured record emitted by all watchers.
// This is the atomic unit of operational memory.
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

// Snapshot is a point-in-time capture of a Kubernetes object's full state.
// Enables "what was the state of X at time T?" — the core OMA query.
type Snapshot struct {
	ID           string                 `json:"id"`
	Timestamp    time.Time              `json:"timestamp"`
	ObjectKind   string                 `json:"object_kind"`
	ObjectName   string                 `json:"object_name"`
	Namespace    string                 `json:"namespace,omitempty"`
	TriggerEvent string                 `json:"trigger_event"`
	State        map[string]interface{} `json:"state"`
}

// JSONEmitter writes CausalEvents and Snapshots to JSONL files.
// The storage layer (Python) ingests these files to build the memory store.
type JSONEmitter struct {
	mu           sync.Mutex
	eventsFile   *os.File
	snapshotFile *os.File
}

// NewJSONEmitter creates an emitter writing to the given output directory.
func NewJSONEmitter(outputDir string) (*JSONEmitter, error) {
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create output dir: %w", err)
	}

	eventsPath := outputDir + "/events.jsonl"
	snapshotPath := outputDir + "/snapshots.jsonl"

	eventsFile, err := os.OpenFile(eventsPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return nil, fmt.Errorf("failed to open events file: %w", err)
	}

	snapshotFile, err := os.OpenFile(snapshotPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		eventsFile.Close()
		return nil, fmt.Errorf("failed to open snapshots file: %w", err)
	}

	fmt.Printf("[emitter] Writing events  → %s\n", eventsPath)
	fmt.Printf("[emitter] Writing snapshots → %s\n", snapshotPath)

	return &JSONEmitter{
		eventsFile:   eventsFile,
		snapshotFile: snapshotFile,
	}, nil
}

// Emit writes a CausalEvent to the events JSONL file. Thread-safe.
func (e *JSONEmitter) Emit(event CausalEvent) {
	e.mu.Lock()
	defer e.mu.Unlock()

	data, err := json.Marshal(event)
	if err != nil {
		fmt.Printf("[emitter] ERROR marshalling event: %v\n", err)
		return
	}
	if _, err := e.eventsFile.Write(append(data, '\n')); err != nil {
		fmt.Printf("[emitter] ERROR writing event: %v\n", err)
		return
	}
	fmt.Printf("[emitter] Event: type=%-22s pattern=%-5s pod=%s\n",
		event.EventType, event.PatternID, event.PodName)
}

// EmitSnapshot writes a Snapshot to the snapshots JSONL file. Thread-safe.
func (e *JSONEmitter) EmitSnapshot(snapshot Snapshot) {
	e.mu.Lock()
	defer e.mu.Unlock()

	data, err := json.Marshal(snapshot)
	if err != nil {
		fmt.Printf("[emitter] ERROR marshalling snapshot: %v\n", err)
		return
	}
	if _, err := e.snapshotFile.Write(append(data, '\n')); err != nil {
		fmt.Printf("[emitter] ERROR writing snapshot: %v\n", err)
		return
	}
	fmt.Printf("[emitter] Snapshot: kind=%-12s name=%s trigger=%s\n",
		snapshot.ObjectKind, snapshot.ObjectName, snapshot.TriggerEvent)
}

// Close flushes and closes the output files.
func (e *JSONEmitter) Close() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.eventsFile.Sync()
	e.eventsFile.Close()
	e.snapshotFile.Sync()
	e.snapshotFile.Close()
	fmt.Println("[emitter] Closed.")
}
EOF

# ── watcher/node_watcher.go ───────────────────────────────────────────────────
cat > collector/watcher/node_watcher.go << 'EOF'
package watcher

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"

	"github.com/opscart/k8s-causal-memory/collector/emitter"
)

// NodeWatcher watches node resource state and provides on-demand
// node snapshots to other watchers at the moment of significant events.
//
// Key insight: when an OOMKill occurs, we need the node memory state
// AT THAT MOMENT — not 5 minutes later when an engineer runs kubectl.
type NodeWatcher struct {
	client    kubernetes.Interface
	emitter   *emitter.JSONEmitter
	nodeCache map[string]*corev1.Node
}

// NodeSnapshot is the memory/resource state of a node at a point in time.
type NodeSnapshot struct {
	NodeName         string            `json:"node_name"`
	SnapshotTime     time.Time         `json:"snapshot_time"`
	Conditions       map[string]string `json:"conditions"`
	AllocatableMem   string            `json:"allocatable_memory"`
	AllocatableCPU   string            `json:"allocatable_cpu"`
	CapacityMem      string            `json:"capacity_memory"`
	CapacityCPU      string            `json:"capacity_cpu"`
	MemPressure      bool              `json:"memory_pressure"`
	DiskPressure     bool              `json:"disk_pressure"`
	PIDPressure      bool              `json:"pid_pressure"`
	KernelVersion    string            `json:"kernel_version"`
	KubeletVersion   string            `json:"kubelet_version"`
	ContainerRuntime string            `json:"container_runtime"`
}

// NewNodeWatcher creates a NodeWatcher.
func NewNodeWatcher(client kubernetes.Interface, e *emitter.JSONEmitter) *NodeWatcher {
	return &NodeWatcher{
		client:    client,
		emitter:   e,
		nodeCache: map[string]*corev1.Node{},
	}
}

// Watch starts the node watch loop. Blocks until ctx is cancelled.
func (nw *NodeWatcher) Watch(ctx context.Context) error {
	fmt.Println("[node_watcher] Starting node watch")

	if err := nw.primeCache(ctx); err != nil {
		fmt.Printf("[node_watcher] Warning: cache prime failed: %v\n", err)
	}

	watcher, err := nw.client.CoreV1().Nodes().Watch(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to start node watch: %w", err)
	}
	defer watcher.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case event, ok := <-watcher.ResultChan():
			if !ok {
				return nw.Watch(ctx)
			}
			nw.handleNodeEvent(event)
		}
	}
}

// SnapshotNode returns the current memory state of the named node.
// Called by PodWatcher at moment of OOMKill to capture node context
// before it changes.
func (nw *NodeWatcher) SnapshotNode(ctx context.Context, nodeName string) *NodeSnapshot {
	if nodeName == "" {
		return nil
	}
	if node, ok := nw.nodeCache[nodeName]; ok {
		return nw.buildSnapshot(node)
	}
	node, err := nw.client.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
	if err != nil {
		fmt.Printf("[node_watcher] Snapshot fetch failed for node=%s: %v\n", nodeName, err)
		return nil
	}
	nw.nodeCache[nodeName] = node
	return nw.buildSnapshot(node)
}

func (nw *NodeWatcher) handleNodeEvent(event watch.Event) {
	node, ok := event.Object.(*corev1.Node)
	if !ok {
		return
	}
	nw.nodeCache[node.Name] = node

	snapshot := nw.buildSnapshot(node)
	if snapshot.MemPressure {
		nw.emitter.Emit(emitter.CausalEvent{
			ID:        generateID(),
			Timestamp: time.Now(),
			EventType: "NodeMemoryPressure",
			PatternID: "P001",
			NodeName:  node.Name,
			Payload: map[string]interface{}{
				"node_snapshot":   snapshot,
				"event_type":      string(event.Type),
				"pressure_active": true,
			},
		})
		fmt.Printf("[node_watcher] MemoryPressure on node=%s\n", node.Name)
	}
}

func (nw *NodeWatcher) primeCache(ctx context.Context) error {
	nodes, err := nw.client.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return err
	}
	for i := range nodes.Items {
		nw.nodeCache[nodes.Items[i].Name] = &nodes.Items[i]
	}
	fmt.Printf("[node_watcher] Cache primed with %d nodes\n", len(nodes.Items))
	return nil
}

func (nw *NodeWatcher) buildSnapshot(node *corev1.Node) *NodeSnapshot {
	s := &NodeSnapshot{
		NodeName:     node.Name,
		SnapshotTime: time.Now(),
		Conditions:   map[string]string{},
	}
	for _, cond := range node.Status.Conditions {
		s.Conditions[string(cond.Type)] = string(cond.Status)
		switch cond.Type {
		case corev1.NodeMemoryPressure:
			s.MemPressure = cond.Status == corev1.ConditionTrue
		case corev1.NodeDiskPressure:
			s.DiskPressure = cond.Status == corev1.ConditionTrue
		case corev1.NodePIDPressure:
			s.PIDPressure = cond.Status == corev1.ConditionTrue
		}
	}
	if mem := node.Status.Allocatable.Memory(); mem != nil {
		s.AllocatableMem = mem.String()
	}
	if cpu := node.Status.Allocatable.Cpu(); cpu != nil {
		s.AllocatableCPU = cpu.String()
	}
	if mem := node.Status.Capacity.Memory(); mem != nil {
		s.CapacityMem = mem.String()
	}
	if cpu := node.Status.Capacity.Cpu(); cpu != nil {
		s.CapacityCPU = cpu.String()
	}
	s.KernelVersion = node.Status.NodeInfo.KernelVersion
	s.KubeletVersion = node.Status.NodeInfo.KubeletVersion
	s.ContainerRuntime = node.Status.NodeInfo.ContainerRuntimeVersion
	return s
}
EOF

# ── watcher/configmap_watcher.go ─────────────────────────────────────────────
cat > collector/watcher/configmap_watcher.go << 'EOF'
package watcher

import (
	"context"
	"crypto/sha256"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"

	"github.com/opscart/k8s-causal-memory/collector/emitter"
	"github.com/opscart/k8s-causal-memory/collector/patterns"
)

// ConfigMapWatcher tracks ConfigMap versions and captures changes
// with content hash — enabling "what version was in effect at time T?"
//
// Implements causal patterns P002 and P003.
// Reference: https://opscart.com/when-kubernetes-restarts-your-pod/
type ConfigMapWatcher struct {
	client       kubernetes.Interface
	namespace    string
	emitter      *emitter.JSONEmitter
	versionCache map[string]string // key: ns/name, value: content hash
}

// NewConfigMapWatcher creates a ConfigMapWatcher.
func NewConfigMapWatcher(
	client kubernetes.Interface,
	namespace string,
	e *emitter.JSONEmitter,
) *ConfigMapWatcher {
	return &ConfigMapWatcher{
		client:       client,
		namespace:    namespace,
		emitter:      e,
		versionCache: map[string]string{},
	}
}

// Watch starts the ConfigMap watch loop. Blocks until ctx is cancelled.
func (cw *ConfigMapWatcher) Watch(ctx context.Context) error {
	fmt.Printf("[configmap_watcher] Starting watch on namespace=%q\n", cw.namespace)

	if err := cw.primeCache(ctx); err != nil {
		fmt.Printf("[configmap_watcher] Warning: cache prime failed: %v\n", err)
	}

	watcher, err := cw.client.CoreV1().ConfigMaps(cw.namespace).Watch(
		ctx, metav1.ListOptions{},
	)
	if err != nil {
		return fmt.Errorf("failed to start configmap watch: %w", err)
	}
	defer watcher.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case event, ok := <-watcher.ResultChan():
			if !ok {
				return cw.Watch(ctx)
			}
			cw.handleEvent(event)
		}
	}
}

// GetContentHash returns the current content hash for a named ConfigMap.
func (cw *ConfigMapWatcher) GetContentHash(namespace, name string) string {
	if hash, ok := cw.versionCache[namespace+"/"+name]; ok {
		return hash
	}
	return "unknown"
}

func (cw *ConfigMapWatcher) handleEvent(event watch.Event) {
	cm, ok := event.Object.(*corev1.ConfigMap)
	if !ok {
		return
	}

	key := cm.Namespace + "/" + cm.Name
	newHash := contentHash(cm)

	switch event.Type {
	case watch.Added:
		cw.versionCache[key] = newHash

	case watch.Modified:
		oldHash, known := cw.versionCache[key]
		if known && oldHash == newHash {
			return // metadata-only change, skip
		}
		cw.captureChange(cm, oldHash, newHash, event.Type)
		cw.versionCache[key] = newHash

	case watch.Deleted:
		cw.captureChange(cm, cw.versionCache[key], "", event.Type)
		delete(cw.versionCache, key)
	}
}

func (cw *ConfigMapWatcher) captureChange(
	cm *corev1.ConfigMap,
	oldHash, newHash string,
	eventType watch.EventType,
) {
	payload := map[string]interface{}{
		"configmap_name":   cm.Name,
		"namespace":        cm.Namespace,
		"resource_version": cm.ResourceVersion,
		"old_content_hash": oldHash,
		"new_content_hash": newHash,
		"changed_keys":     extractChangedKeys(cm),
		"key_count":        len(cm.Data) + len(cm.BinaryData),
		"event_type":       string(eventType),
		"change_time":      time.Now(),
		// Which downstream patterns this change may trigger
		"potential_patterns": []string{
			patterns.PatternConfigMapEnv,
			patterns.PatternConfigMapMount,
		},
		// Values intentionally NOT captured — hash only for security
		"content_captured": false,
		"content_note":     "Content hash only — values not stored",
	}

	cw.emitter.Emit(emitter.CausalEvent{
		ID:        generateID(),
		Timestamp: time.Now(),
		EventType: "ConfigMapChanged",
		PatternID: "",
		Namespace: cm.Namespace,
		Payload:   payload,
	})

	fmt.Printf("[configmap_watcher] Changed: %s/%s keys=%v\n",
		cm.Namespace, cm.Name, extractChangedKeys(cm))
}

func (cw *ConfigMapWatcher) primeCache(ctx context.Context) error {
	cms, err := cw.client.CoreV1().ConfigMaps(cw.namespace).List(
		ctx, metav1.ListOptions{},
	)
	if err != nil {
		return err
	}
	for i := range cms.Items {
		cm := &cms.Items[i]
		cw.versionCache[cm.Namespace+"/"+cm.Name] = contentHash(cm)
	}
	fmt.Printf("[configmap_watcher] Cache primed with %d configmaps\n", len(cms.Items))
	return nil
}

func contentHash(cm *corev1.ConfigMap) string {
	h := sha256.New()
	for k, v := range cm.Data {
		h.Write([]byte(k + "=" + v + "\n"))
	}
	for k, v := range cm.BinaryData {
		h.Write([]byte(k))
		h.Write(v)
	}
	return fmt.Sprintf("%x", h.Sum(nil))[:16]
}

func extractChangedKeys(cm *corev1.ConfigMap) []string {
	keys := make([]string, 0, len(cm.Data)+len(cm.BinaryData))
	for k := range cm.Data {
		keys = append(keys, k)
	}
	for k := range cm.BinaryData {
		keys = append(keys, k+"(binary)")
	}
	return keys
}
EOF

# ── watcher/pod_watcher.go ────────────────────────────────────────────────────
cat > collector/watcher/pod_watcher.go << 'EOF'
package watcher

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"

	"github.com/opscart/k8s-causal-memory/collector/emitter"
	"github.com/opscart/k8s-causal-memory/collector/patterns"
)

// PodWatcher watches pod lifecycle events and captures decision context
// at the moment events occur — before evidence rotates.
//
// Reference: "When Kubernetes Forgets: The 90-Second Evidence Gap"
// https://opscart.com/when-kubernetes-forgets-the-90-second-evidence-gap/
type PodWatcher struct {
	client    kubernetes.Interface
	namespace string
	emitter   *emitter.JSONEmitter
	node      *NodeWatcher
}

// NewPodWatcher creates a PodWatcher. Pass namespace="" for all namespaces.
func NewPodWatcher(
	client kubernetes.Interface,
	namespace string,
	e *emitter.JSONEmitter,
	node *NodeWatcher,
) *PodWatcher {
	return &PodWatcher{
		client:    client,
		namespace: namespace,
		emitter:   e,
		node:      node,
	}
}

// Watch starts the watch loop. Blocks until ctx is cancelled.
func (pw *PodWatcher) Watch(ctx context.Context) error {
	fmt.Printf("[pod_watcher] Starting watch on namespace=%q\n", pw.namespace)

	watcher, err := pw.client.CoreV1().Pods(pw.namespace).Watch(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to start pod watch: %w", err)
	}
	defer watcher.Stop()

	for {
		select {
		case <-ctx.Done():
			fmt.Println("[pod_watcher] Stopped.")
			return nil
		case event, ok := <-watcher.ResultChan():
			if !ok {
				return pw.Watch(ctx)
			}
			pw.handleEvent(ctx, event)
		}
	}
}

func (pw *PodWatcher) handleEvent(ctx context.Context, event watch.Event) {
	pod, ok := event.Object.(*corev1.Pod)
	if !ok {
		return
	}
	switch event.Type {
	case watch.Modified:
		pw.inspectContainerStatuses(ctx, pod)
	case watch.Deleted:
		pw.captureSnapshot(pod, "PodDeleted")
	}
}

func (pw *PodWatcher) inspectContainerStatuses(ctx context.Context, pod *corev1.Pod) {
	for _, cs := range pod.Status.ContainerStatuses {
		if cs.State.Terminated != nil {
			pw.handleTerminated(ctx, pod, cs)
		}
		// LastTerminationState: the 90-second evidence window
		if cs.LastTerminationState.Terminated != nil {
			pw.handleLastTerminated(pod, cs)
		}
		if cs.State.Waiting != nil &&
			cs.State.Waiting.Reason == "CrashLoopBackOff" {
			pw.handleCrashLoop(pod, cs)
		}
	}
}

func (pw *PodWatcher) handleTerminated(
	ctx context.Context,
	pod *corev1.Pod,
	cs corev1.ContainerStatus,
) {
	term := cs.State.Terminated
	isOOMKill := term.Reason == "OOMKilled"
	nodeState := pw.node.SnapshotNode(ctx, pod.Spec.NodeName)

	eventType := "ContainerTerminated"
	patternID := ""
	if isOOMKill {
		eventType = "OOMKill"
		patternID = patterns.PatternOOMKill
	}

	payload := map[string]interface{}{
		"container_name":           cs.Name,
		"image":                    cs.Image,
		"restart_count":            cs.RestartCount,
		"reason":                   term.Reason,
		"exit_code":                term.ExitCode,
		"message":                  term.Message,
		"started":                  term.StartedAt.Time,
		"finished":                 term.FinishedAt.Time,
		"failure_duration_seconds": term.FinishedAt.Time.Sub(term.StartedAt.Time).Seconds(),
		"pod_phase":                string(pod.Status.Phase),
		"pod_ip":                   pod.Status.PodIP,
		"node_name":                pod.Spec.NodeName,
		"qos_class":                string(pod.Status.QOSClass),
		"resource_limits":          extractResourceLimits(pod, cs.Name),
		"resource_requests":        extractResourceRequests(pod, cs.Name),
		// Config refs in effect at moment of termination —
		// not captured by any existing observability tool
		"config_references":   extractConfigReferences(pod),
		"node_state":          nodeState,
		"is_oomkill":          isOOMKill,
		"evidence_expires_at": time.Now().Add(90 * time.Second),
	}

	pw.emitter.Emit(emitter.CausalEvent{
		ID:        generateID(),
		Timestamp: time.Now(),
		EventType: eventType,
		PatternID: patternID,
		PodName:   pod.Name,
		Namespace: pod.Namespace,
		NodeName:  pod.Spec.NodeName,
		PodUID:    string(pod.UID),
		Payload:   payload,
	})

	if isOOMKill {
		fmt.Printf("[pod_watcher] OOMKill: pod=%s ns=%s node=%s exit=%d\n",
			pod.Name, pod.Namespace, pod.Spec.NodeName, term.ExitCode)
	}
}

func (pw *PodWatcher) handleLastTerminated(pod *corev1.Pod, cs corev1.ContainerStatus) {
	lastTerm := cs.LastTerminationState.Terminated
	if lastTerm.Reason != "OOMKilled" {
		return
	}
	pw.emitter.Emit(emitter.CausalEvent{
		ID:        generateID(),
		Timestamp: time.Now(),
		EventType: "OOMKillEvidence",
		PatternID: patterns.PatternOOMKill,
		PodName:   pod.Name,
		Namespace: pod.Namespace,
		NodeName:  pod.Spec.NodeName,
		PodUID:    string(pod.UID),
		Payload: map[string]interface{}{
			"container_name":     cs.Name,
			"restart_count":      cs.RestartCount,
			"last_reason":        lastTerm.Reason,
			"last_exit_code":     lastTerm.ExitCode,
			"last_started":       lastTerm.StartedAt.Time,
			"last_finished":      lastTerm.FinishedAt.Time,
			"current_phase":      string(pod.Status.Phase),
			"evidence_source":    "LastTerminationState",
			"evidence_fragility": "high",
		},
	})
}

func (pw *PodWatcher) handleCrashLoop(pod *corev1.Pod, cs corev1.ContainerStatus) {
	pw.emitter.Emit(emitter.CausalEvent{
		ID:        generateID(),
		Timestamp: time.Now(),
		EventType: "CrashLoopBackOff",
		PatternID: "",
		PodName:   pod.Name,
		Namespace: pod.Namespace,
		NodeName:  pod.Spec.NodeName,
		PodUID:    string(pod.UID),
		Payload: map[string]interface{}{
			"container_name":    cs.Name,
			"restart_count":     cs.RestartCount,
			"wait_reason":       cs.State.Waiting.Reason,
			"wait_message":      cs.State.Waiting.Message,
			"node_name":         pod.Spec.NodeName,
			"qos_class":         string(pod.Status.QOSClass),
			"config_references": extractConfigReferences(pod),
		},
	})
	fmt.Printf("[pod_watcher] CrashLoop: pod=%s restarts=%d\n",
		pod.Name, cs.RestartCount)
}

func (pw *PodWatcher) captureSnapshot(pod *corev1.Pod, reason string) {
	pw.emitter.EmitSnapshot(emitter.Snapshot{
		ID:           generateID(),
		Timestamp:    time.Now(),
		ObjectKind:   "Pod",
		ObjectName:   pod.Name,
		Namespace:    pod.Namespace,
		TriggerEvent: reason,
		State: map[string]interface{}{
			"uid":               string(pod.UID),
			"phase":             string(pod.Status.Phase),
			"node_name":         pod.Spec.NodeName,
			"pod_ip":            pod.Status.PodIP,
			"qos_class":         string(pod.Status.QOSClass),
			"restart_policy":    string(pod.Spec.RestartPolicy),
			"resource_limits":   extractAllResourceLimits(pod),
			"config_references": extractConfigReferences(pod),
			"labels":            pod.Labels,
			"annotations":       pod.Annotations,
		},
	})
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func extractConfigReferences(pod *corev1.Pod) map[string]interface{} {
	cmSet := map[string]bool{}
	secSet := map[string]bool{}
	for _, c := range pod.Spec.Containers {
		for _, ef := range c.EnvFrom {
			if ef.ConfigMapRef != nil {
				cmSet[ef.ConfigMapRef.Name] = true
			}
			if ef.SecretRef != nil {
				secSet[ef.SecretRef.Name] = true
			}
		}
		for _, env := range c.Env {
			if env.ValueFrom != nil {
				if env.ValueFrom.ConfigMapKeyRef != nil {
					cmSet[env.ValueFrom.ConfigMapKeyRef.Name] = true
				}
				if env.ValueFrom.SecretKeyRef != nil {
					secSet[env.ValueFrom.SecretKeyRef.Name] = true
				}
			}
		}
	}
	for _, vol := range pod.Spec.Volumes {
		if vol.ConfigMap != nil {
			cmSet[vol.ConfigMap.Name] = true
		}
		if vol.Secret != nil {
			secSet[vol.Secret.SecretName] = true
		}
	}
	cms := make([]string, 0, len(cmSet))
	for k := range cmSet {
		cms = append(cms, k)
	}
	secs := make([]string, 0, len(secSet))
	for k := range secSet {
		secs = append(secs, k)
	}
	return map[string]interface{}{"configmaps": cms, "secrets": secs}
}

func extractResourceLimits(pod *corev1.Pod, containerName string) map[string]string {
	for _, c := range pod.Spec.Containers {
		if c.Name == containerName {
			m := map[string]string{}
			if v := c.Resources.Limits.Cpu(); v != nil {
				m["cpu"] = v.String()
			}
			if v := c.Resources.Limits.Memory(); v != nil {
				m["memory"] = v.String()
			}
			return m
		}
	}
	return map[string]string{}
}

func extractResourceRequests(pod *corev1.Pod, containerName string) map[string]string {
	for _, c := range pod.Spec.Containers {
		if c.Name == containerName {
			m := map[string]string{}
			if v := c.Resources.Requests.Cpu(); v != nil {
				m["cpu"] = v.String()
			}
			if v := c.Resources.Requests.Memory(); v != nil {
				m["memory"] = v.String()
			}
			return m
		}
	}
	return map[string]string{}
}

func extractAllResourceLimits(pod *corev1.Pod) map[string]map[string]string {
	all := map[string]map[string]string{}
	for _, c := range pod.Spec.Containers {
		all[c.Name] = extractResourceLimits(pod, c.Name)
	}
	return all
}

func generateID() string {
	return fmt.Sprintf("%d", time.Now().UnixNano())
}
EOF

# ── main.go ───────────────────────────────────────────────────────────────────
cat > collector/main.go << 'EOF'
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"

	"github.com/opscart/k8s-causal-memory/collector/emitter"
	"github.com/opscart/k8s-causal-memory/collector/watcher"
)

func main() {
	var (
		kubeconfig = flag.String("kubeconfig", "", "Path to kubeconfig")
		namespace  = flag.String("namespace", "", "Namespace to watch (default: all)")
		outputDir  = flag.String("output", "./output", "Directory for JSONL output")
	)
	flag.Parse()

	fmt.Println("========================================")
	fmt.Println(" k8s-causal-memory collector")
	fmt.Println(" Operational Memory Architecture (OMA)")
	fmt.Println(" github.com/opscart/k8s-causal-memory")
	fmt.Println("========================================")

	client, err := buildClient(*kubeconfig)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to build client: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("[main] Kubernetes client connected")

	emit, err := emitter.NewJSONEmitter(*outputDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to initialize emitter: %v\n", err)
		os.Exit(1)
	}
	defer emit.Close()

	nodeW := watcher.NewNodeWatcher(client, emit)
	podW := watcher.NewPodWatcher(client, *namespace, emit, nodeW)
	cmW := watcher.NewConfigMapWatcher(client, *namespace, emit)

	ctx, cancel := signal.NotifyContext(context.Background(),
		syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	fmt.Printf("[main] Watching namespace=%q | output=%s\n", *namespace, *outputDir)
	fmt.Println("[main] Press Ctrl+C to stop")
	fmt.Println("----------------------------------------")

	errCh := make(chan error, 3)
	go func() { errCh <- nodeW.Watch(ctx) }()
	go func() { errCh <- podW.Watch(ctx) }()
	go func() { errCh <- cmW.Watch(ctx) }()

	select {
	case <-ctx.Done():
		fmt.Println("\n[main] Shutting down...")
	case err := <-errCh:
		if err != nil {
			fmt.Fprintf(os.Stderr, "[main] Watcher error: %v\n", err)
			cancel()
		}
	}

	fmt.Println("[main] Collector stopped. Events written to:", *outputDir)
}

func buildClient(kubeconfigPath string) (kubernetes.Interface, error) {
	var config *rest.Config
	var err error

	if kubeconfigPath != "" {
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfigPath)
	} else if kubeenv := os.Getenv("KUBECONFIG"); kubeenv != "" {
		config, err = clientcmd.BuildConfigFromFlags("", kubeenv)
	} else {
		config, err = rest.InClusterConfig()
		if err != nil {
			config, err = clientcmd.BuildConfigFromFlags("",
				os.Getenv("HOME")+"/.kube/config")
		}
	}
	if err != nil {
		return nil, fmt.Errorf("failed to build kubeconfig: %w", err)
	}
	return kubernetes.NewForConfig(config)
}
EOF

echo ""
echo "============================================================"
echo " All Go files written successfully."
echo " Now run:"
echo "   cd collector"
echo "   go mod tidy"
echo "   go build -o bin/collector ./..."
echo "============================================================"