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

type NodeWatcher struct {
	client    kubernetes.Interface
	emitter   *emitter.JSONEmitter
	nodeCache map[string]*corev1.Node
}

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

func NewNodeWatcher(client kubernetes.Interface, e *emitter.JSONEmitter) *NodeWatcher {
	return &NodeWatcher{client: client, emitter: e, nodeCache: map[string]*corev1.Node{}}
}

func (nw *NodeWatcher) Watch(ctx context.Context) error {
	fmt.Println("[node_watcher] Starting")
	if err := nw.primeCache(ctx); err != nil {
		fmt.Printf("[node_watcher] cache prime failed: %v\n", err)
	}
	w, err := nw.client.CoreV1().Nodes().Watch(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("node watch failed: %w", err)
	}
	defer w.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case event, ok := <-w.ResultChan():
			if !ok {
				return nw.Watch(ctx)
			}
			nw.handleNodeEvent(event)
		}
	}
}

func (nw *NodeWatcher) SnapshotNode(ctx context.Context, nodeName string) *NodeSnapshot {
	if nodeName == "" {
		return nil
	}
	if node, ok := nw.nodeCache[nodeName]; ok {
		return nw.buildSnapshot(node)
	}
	node, err := nw.client.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
	if err != nil {
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
	s := nw.buildSnapshot(node)
	if s.MemPressure {
		nw.emitter.Emit(emitter.CausalEvent{
			ID:        generateID(),
			Timestamp: time.Now(),
			EventType: "NodeMemoryPressure",
			PatternID: "P001",
			NodeName:  node.Name,
			Payload:   map[string]interface{}{"node_snapshot": s, "pressure_active": true},
		})
		fmt.Printf("[node_watcher] MemoryPressure: node=%s\n", node.Name)
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
	fmt.Printf("[node_watcher] Cache primed: %d nodes\n", len(nodes.Items))
	return nil
}

func (nw *NodeWatcher) buildSnapshot(node *corev1.Node) *NodeSnapshot {
	s := &NodeSnapshot{NodeName: node.Name, SnapshotTime: time.Now(), Conditions: map[string]string{}}
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
	if v := node.Status.Allocatable.Memory(); v != nil {
		s.AllocatableMem = v.String()
	}
	if v := node.Status.Allocatable.Cpu(); v != nil {
		s.AllocatableCPU = v.String()
	}
	if v := node.Status.Capacity.Memory(); v != nil {
		s.CapacityMem = v.String()
	}
	if v := node.Status.Capacity.Cpu(); v != nil {
		s.CapacityCPU = v.String()
	}
	s.KernelVersion = node.Status.NodeInfo.KernelVersion
	s.KubeletVersion = node.Status.NodeInfo.KubeletVersion
	s.ContainerRuntime = node.Status.NodeInfo.ContainerRuntimeVersion
	return s
}
