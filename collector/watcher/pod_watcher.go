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

type PodWatcher struct {
	client    kubernetes.Interface
	namespace string
	emitter   *emitter.JSONEmitter
	node      *NodeWatcher
}

func NewPodWatcher(client kubernetes.Interface, namespace string, e *emitter.JSONEmitter, node *NodeWatcher) *PodWatcher {
	return &PodWatcher{client: client, namespace: namespace, emitter: e, node: node}
}

func (pw *PodWatcher) Watch(ctx context.Context) error {
	fmt.Printf("[pod_watcher] Starting namespace=%q\n", pw.namespace)
	w, err := pw.client.CoreV1().Pods(pw.namespace).Watch(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("pod watch failed: %w", err)
	}
	defer w.Stop()
	for {
		select {
		case <-ctx.Done():
			fmt.Println("[pod_watcher] Stopped.")
			return nil
		case event, ok := <-w.ResultChan():
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
		if cs.LastTerminationState.Terminated != nil {
			pw.handleLastTerminated(pod, cs)
		}
		if cs.State.Waiting != nil && cs.State.Waiting.Reason == "CrashLoopBackOff" {
			pw.handleCrashLoop(pod, cs)
		}
	}
}

func (pw *PodWatcher) handleTerminated(ctx context.Context, pod *corev1.Pod, cs corev1.ContainerStatus) {
	term := cs.State.Terminated
	isOOMKill := term.Reason == "OOMKilled"
	nodeState := pw.node.SnapshotNode(ctx, pod.Spec.NodeName)

	eventType := "ContainerTerminated"
	patternID := ""
	if isOOMKill {
		eventType = "OOMKill"
		patternID = patterns.PatternOOMKill
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
		Payload: map[string]interface{}{
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
			"node_name":                pod.Spec.NodeName,
			"qos_class":                string(pod.Status.QOSClass),
			"resource_limits":          extractResourceLimits(pod, cs.Name),
			"resource_requests":        extractResourceRequests(pod, cs.Name),
			"config_references":        extractConfigReferences(pod),
			"node_state":               nodeState,
			"is_oomkill":               isOOMKill,
			"evidence_expires_at":      time.Now().Add(90 * time.Second),
		},
	})

	if isOOMKill {
		fmt.Printf("[pod_watcher] OOMKill: pod=%s ns=%s exit=%d\n", pod.Name, pod.Namespace, term.ExitCode)
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
		PodName:   pod.Name,
		Namespace: pod.Namespace,
		NodeName:  pod.Spec.NodeName,
		PodUID:    string(pod.UID),
		Payload: map[string]interface{}{
			"container_name":    cs.Name,
			"restart_count":     cs.RestartCount,
			"wait_reason":       cs.State.Waiting.Reason,
			"config_references": extractConfigReferences(pod),
		},
	})
	fmt.Printf("[pod_watcher] CrashLoop: pod=%s restarts=%d\n", pod.Name, cs.RestartCount)
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
			"qos_class":         string(pod.Status.QOSClass),
			"resource_limits":   extractAllResourceLimits(pod),
			"config_references": extractConfigReferences(pod),
			"labels":            pod.Labels,
		},
	})
}

func extractConfigReferences(pod *corev1.Pod) map[string]interface{} {
	cmSet, secSet := map[string]bool{}, map[string]bool{}
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

func extractResourceLimits(pod *corev1.Pod, name string) map[string]string {
	for _, c := range pod.Spec.Containers {
		if c.Name == name {
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

func extractResourceRequests(pod *corev1.Pod, name string) map[string]string {
	for _, c := range pod.Spec.Containers {
		if c.Name == name {
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
