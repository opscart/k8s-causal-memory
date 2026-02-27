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

type ConfigMapWatcher struct {
	client       kubernetes.Interface
	namespace    string
	emitter      *emitter.JSONEmitter
	versionCache map[string]string
}

func NewConfigMapWatcher(client kubernetes.Interface, namespace string, e *emitter.JSONEmitter) *ConfigMapWatcher {
	return &ConfigMapWatcher{client: client, namespace: namespace, emitter: e, versionCache: map[string]string{}}
}

func (cw *ConfigMapWatcher) Watch(ctx context.Context) error {
	fmt.Printf("[configmap_watcher] Starting namespace=%q\n", cw.namespace)
	if err := cw.primeCache(ctx); err != nil {
		fmt.Printf("[configmap_watcher] cache prime failed: %v\n", err)
	}
	w, err := cw.client.CoreV1().ConfigMaps(cw.namespace).Watch(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("configmap watch failed: %w", err)
	}
	defer w.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case event, ok := <-w.ResultChan():
			if !ok {
				return cw.Watch(ctx)
			}
			cw.handleEvent(event)
		}
	}
}

func (cw *ConfigMapWatcher) GetContentHash(namespace, name string) string {
	if h, ok := cw.versionCache[namespace+"/"+name]; ok {
		return h
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
			return
		}
		cw.captureChange(cm, oldHash, newHash, event.Type)
		cw.versionCache[key] = newHash
	case watch.Deleted:
		cw.captureChange(cm, cw.versionCache[key], "", event.Type)
		delete(cw.versionCache, key)
	}
}

func (cw *ConfigMapWatcher) captureChange(cm *corev1.ConfigMap, oldHash, newHash string, eventType watch.EventType) {
	cw.emitter.Emit(emitter.CausalEvent{
		ID:        generateID(),
		Timestamp: time.Now(),
		EventType: "ConfigMapChanged",
		Namespace: cm.Namespace,
		Payload: map[string]interface{}{
			"configmap_name":     cm.Name,
			"namespace":          cm.Namespace,
			"resource_version":   cm.ResourceVersion,
			"old_content_hash":   oldHash,
			"new_content_hash":   newHash,
			"changed_keys":       extractChangedKeys(cm),
			"key_count":          len(cm.Data) + len(cm.BinaryData),
			"event_type":         string(eventType),
			"potential_patterns": []string{patterns.PatternConfigMapEnv, patterns.PatternConfigMapMount},
			"content_captured":   false,
		},
	})
	fmt.Printf("[configmap_watcher] Changed: %s/%s\n", cm.Namespace, cm.Name)
}

func (cw *ConfigMapWatcher) primeCache(ctx context.Context) error {
	cms, err := cw.client.CoreV1().ConfigMaps(cw.namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return err
	}
	for i := range cms.Items {
		cm := &cms.Items[i]
		cw.versionCache[cm.Namespace+"/"+cm.Name] = contentHash(cm)
	}
	fmt.Printf("[configmap_watcher] Cache primed: %d configmaps\n", len(cms.Items))
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
