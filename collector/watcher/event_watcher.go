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

// EventWatcher captures Kubernetes scheduler Events before kube-apiserver
// prunes them at the 1-hour TTL / 1000-event cluster limit.
//
// Evidence Horizon H2: scheduler placement decisions (which nodes were
// rejected and why) exist only as transient Event objects. Once pruned,
// the causal link between a pod's placement and its subsequent failure
// is permanently severed.
type EventWatcher struct {
	client    kubernetes.Interface
	namespace string
	emitter   *emitter.JSONEmitter
}

func NewEventWatcher(client kubernetes.Interface, namespace string, e *emitter.JSONEmitter) *EventWatcher {
	return &EventWatcher{client: client, namespace: namespace, emitter: e}
}

func (ew *EventWatcher) Watch(ctx context.Context) error {
	fmt.Printf("[event_watcher] Starting namespace=%q\n", ew.namespace)
	// Note: source.component is NOT a supported field selector in the
	// Kubernetes watch API. We watch all events and filter in handleEvent.
	w, err := ew.client.CoreV1().Events(ew.namespace).Watch(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("event watch failed: %w", err)
	}
	defer w.Stop()

	for {
		select {
		case <-ctx.Done():
			fmt.Println("[event_watcher] Stopped.")
			return nil
		case evt, ok := <-w.ResultChan():
			if !ok {
				return ew.Watch(ctx)
			}
			if evt.Type == watch.Added || evt.Type == watch.Modified {
				ew.handleEvent(evt)
			}
		}
	}
}

func (ew *EventWatcher) handleEvent(evt watch.Event) {
	k8sEvent, ok := evt.Object.(*corev1.Event)
	if !ok {
		return
	}

	// Filter to scheduler events only — source.component check done here
	// because the watch API does not support it as a field selector.
	if k8sEvent.Source.Component != "default-scheduler" {
		return
	}

	reason := k8sEvent.Reason
	if reason != "FailedScheduling" && reason != "Scheduled" && reason != "Preempting" {
		return
	}

	age := time.Since(k8sEvent.FirstTimestamp.Time)

	ew.emitter.Emit(emitter.CausalEvent{
		ID:        generateID(),
		Timestamp: time.Now(),
		EventType: "SchedulerEvent",
		PatternID: patterns.PatternScheduler,
		PodName:   k8sEvent.InvolvedObject.Name,
		Namespace: k8sEvent.Namespace,
		NodeName:  k8sEvent.Source.Host,
		Payload: map[string]interface{}{
			"reason":           reason,
			"message":          k8sEvent.Message,
			"first_timestamp":  k8sEvent.FirstTimestamp.UTC().Format(time.RFC3339Nano),
			"last_timestamp":   k8sEvent.LastTimestamp.UTC().Format(time.RFC3339Nano),
			"count":            k8sEvent.Count,
			"age_seconds":      age.Seconds(),
			"pruning_risk":     schedulerPruningRisk(age),
			"source_host":      k8sEvent.Source.Host,
			"resource_version": k8sEvent.ResourceVersion,
			"event_uid":        string(k8sEvent.UID),
			"horizon":          "H2",
			"evidence_expires": k8sEvent.FirstTimestamp.Add(60 * time.Minute).UTC().Format(time.RFC3339Nano),
		},
	})

	fmt.Printf("[event_watcher] %s pod=%s ns=%s age=%.0fs risk=%s\n",
		reason,
		k8sEvent.InvolvedObject.Name,
		k8sEvent.Namespace,
		age.Seconds(),
		schedulerPruningRisk(age),
	)
}

// schedulerPruningRisk classifies how close the event is to the
// kube-apiserver 1-hour TTL boundary (--event-ttl default: 1h0m0s).
func schedulerPruningRisk(age time.Duration) string {
	switch {
	case age >= 55*time.Minute:
		return "CRITICAL"
	case age >= 45*time.Minute:
		return "HIGH"
	case age >= 30*time.Minute:
		return "MEDIUM"
	default:
		return "LOW"
	}
}
