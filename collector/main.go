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
	kubeconfig := flag.String("kubeconfig", "", "Path to kubeconfig")
	namespace := flag.String("namespace", "", "Namespace to watch (default: all)")
	outputDir := flag.String("output", "./output", "Directory for JSONL output")
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

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	fmt.Printf("[main] namespace=%q | output=%s\n", *namespace, *outputDir)
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
			fmt.Fprintf(os.Stderr, "[main] Error: %v\n", err)
			cancel()
		}
	}
	fmt.Println("[main] Done.")
}

func buildClient(kubeconfigPath string) (kubernetes.Interface, error) {
	var config *rest.Config
	var err error
	if kubeconfigPath != "" {
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfigPath)
	} else if k := os.Getenv("KUBECONFIG"); k != "" {
		config, err = clientcmd.BuildConfigFromFlags("", k)
	} else {
		config, err = rest.InClusterConfig()
		if err != nil {
			config, err = clientcmd.BuildConfigFromFlags("", os.Getenv("HOME")+"/.kube/config")
		}
	}
	if err != nil {
		return nil, fmt.Errorf("kubeconfig error: %w", err)
	}
	return kubernetes.NewForConfig(config)
}
