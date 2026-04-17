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

// EphemeralWatcher captures ephemeral container termination state before the
// H3 evidence horizon fires.
//
// Evidence Horizon H3: The Kubernetes API spec explicitly excludes ephemeral
// containers from the LastTerminationState mechanism. EphemeralContainerStatus
// has no lastState field (contrast with ContainerStatus which does). When a
// kubectl debug session exits, the platform retains no termination record —
// no exit code, no duration, no target container context.
//
// API boundary (documented, not an OMA limitation):
// stdout/stderr content is NOT capturable via the Kubernetes API.
// OMA captures state metadata only: exit_code, duration, target_container,
// node placement. Log content is accessible only via kubectl logs while running.
type EphemeralWatcher struct {
	client    kubernetes.Interface
	namespace string
	emitter   *emitter.JSONEmitter

	// lastSeen tracks the last-known termination state per ephemeral container
	// to avoid double-firing on repeated Modified events for the same exit.
	// Key: "<namespace>/<pod>/<container-name>"
	lastSeen map[string]bool // true = terminated already captured
}

func NewEphemeralWatcher(client kubernetes.Interface, namespace string, e *emitter.JSONEmitter) *EphemeralWatcher {
	return &EphemeralWatcher{
		client:    client,
		namespace: namespace,
		emitter:   e,
		lastSeen:  make(map[string]bool),
	}
}

func (ew *EphemeralWatcher) Watch(ctx context.Context) error {
	fmt.Printf("[ephemeral_watcher] Starting namespace=%q\n", ew.namespace)
	w, err := ew.client.CoreV1().Pods(ew.namespace).Watch(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("ephemeral pod watch failed: %w", err)
	}
	defer w.Stop()

	for {
		select {
		case <-ctx.Done():
			fmt.Println("[ephemeral_watcher] Stopped.")
			return nil
		case evt, ok := <-w.ResultChan():
			if !ok {
				return ew.Watch(ctx)
			}
			if evt.Type == watch.Modified {
				pod, ok := evt.Object.(*corev1.Pod)
				if ok {
					ew.checkEphemeralStatuses(pod)
				}
			}
		}
	}
}

func (ew *EphemeralWatcher) checkEphemeralStatuses(pod *corev1.Pod) {
	for _, status := range pod.Status.EphemeralContainerStatuses {
		if status.State.Terminated == nil {
			continue
		}

		key := fmt.Sprintf("%s/%s/%s", pod.Namespace, pod.Name, status.Name)
		if ew.lastSeen[key] {
			continue // already captured this termination
		}
		ew.lastSeen[key] = true

		ew.captureTermination(pod, status)
	}
}

func (ew *EphemeralWatcher) captureTermination(pod *corev1.Pod, status corev1.ContainerStatus) {
	term := status.State.Terminated

	// Find the matching EphemeralContainer spec to get target container name.
	targetContainer := ""
	for _, ec := range pod.Spec.EphemeralContainers {
		if ec.Name == status.Name {
			targetContainer = ec.TargetContainerName
			break
		}
	}

	var durationSeconds float64
	if !term.StartedAt.IsZero() && !term.FinishedAt.IsZero() {
		durationSeconds = term.FinishedAt.Sub(term.StartedAt.Time).Seconds()
	}

	exitClass := classifyEphemeralExit(term.ExitCode, term.Reason)

	ew.emitter.Emit(emitter.CausalEvent{
		ID:        generateID(),
		Timestamp: time.Now(),
		EventType: "EphemeralContainerTerminated",
		PatternID: patterns.PatternEphemeral,
		PodName:   pod.Name,
		Namespace: pod.Namespace,
		NodeName:  pod.Spec.NodeName,
		PodUID:    string(pod.UID),
		Payload: map[string]interface{}{
			"container_name":    status.Name,
			"image":             status.Image,
			"image_id":          status.ImageID,
			"container_id":      status.ContainerID,
			"target_container":  targetContainer,
			"exit_code":         term.ExitCode,
			"reason":            term.Reason,
			"exit_class":        exitClass,
			"started_at":        term.StartedAt.UTC().Format(time.RFC3339Nano),
			"finished_at":       term.FinishedAt.UTC().Format(time.RFC3339Nano),
			"duration_seconds":  durationSeconds,
			"pod_phase":         string(pod.Status.Phase),
			"pod_restart_count": ephemeralTotalRestarts(pod),
			// Documented API boundary — not an OMA limitation
			"log_content":       "NOT_CAPTURABLE_VIA_API",
			"log_boundary_note": "stdout/stderr only accessible via kubectl logs while container is running",
			"horizon":           "H3",
			"spec_exclusion":    "EphemeralContainerStatus.lastState excluded by Kubernetes API spec",
		},
	})

	fmt.Printf("[ephemeral_watcher] P005: pod=%s/%s container=%s exit_code=%d duration=%.1fs class=%s\n",
		pod.Namespace, pod.Name, status.Name,
		term.ExitCode, durationSeconds, exitClass,
	)
}

func classifyEphemeralExit(code int32, reason string) string {
	switch {
	case code == 0:
		return "CLEAN"
	case reason == "OOMKilled":
		return "OOM"
	case code == 137:
		return "SIGKILL"
	case code == 143:
		return "SIGTERM"
	case code > 0:
		return "ERROR"
	default:
		return "UNKNOWN"
	}
}

func ephemeralTotalRestarts(pod *corev1.Pod) int32 {
	var total int32
	for _, cs := range pod.Status.ContainerStatuses {
		total += cs.RestartCount
	}
	return total
}
