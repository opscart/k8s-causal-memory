package patterns

// PatternOOMKill: MemoryPressure → OOMKill → ContainerRestart → EvidenceRotation
// Empirically documented: https://opscart.com/when-kubernetes-forgets-the-90-second-evidence-gap/
const PatternOOMKill = "P001"

var OOMKillPattern = CausalPattern{
	ID:          PatternOOMKill,
	Name:        "OOMKill Causal Chain",
	Description: "Memory pressure leading to kernel OOMKill and evidence rotation",
	Steps: []PatternStep{
		{EventType: "NodeMemoryPressure", Role: "precursor", Optional: true, WindowSecs: 300, Description: "Node memory pressure preceding OOMKill"},
		{EventType: "OOMKill", Role: "trigger", Optional: false, WindowSecs: 0, Description: "Kernel OOM killer terminates container"},
		{EventType: "OOMKillEvidence", Role: "evidence", Optional: true, WindowSecs: 90, Description: "LastTerminationState evidence before 90s rotation"},
		{EventType: "ContainerTerminated", Role: "effect", Optional: false, WindowSecs: 10, Description: "Container restart following OOMKill"},
	},
	RemediationActions: []string{"increase_memory_limit", "add_vpa_recommendation", "alert_engineering"},
}
