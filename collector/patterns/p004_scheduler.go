package patterns

// PatternScheduler: FailedScheduling → Scheduled → (OOMKill cross-pattern via P001)
// Evidence Horizon H2: kube-apiserver prunes Events at 1hr TTL / 1000 cluster events.
// Scheduler placement decisions are stored only as transient Event objects. Once pruned,
// the causal link between placement and a downstream failure is permanently severed.
const PatternScheduler = "P004"

var SchedulerPattern = CausalPattern{
	ID:          PatternScheduler,
	Name:        "Scheduler Decision Provenance",
	Description: "Scheduler placement decisions pruned before downstream failure root cause analysis",
	Steps: []PatternStep{
		{
			EventType:   "SchedulerEvent",
			Role:        "precursor",
			Optional:    true,
			WindowSecs:  3600,
			Description: "FailedScheduling events: node rejection reasons before 1hr TTL",
		},
		{
			EventType:   "SchedulerEvent",
			Role:        "trigger",
			Optional:    false,
			WindowSecs:  0,
			Description: "Scheduled event: final placement decision captured",
		},
		{
			EventType:   "OOMKill",
			Role:        "effect",
			Optional:    true,
			WindowSecs:  86400,
			Description: "Cross-pattern P004→P001: OOMKill on the placed node",
		},
	},
	RemediationActions: []string{
		"review_node_resource_headroom",
		"adjust_resource_requests",
		"check_node_taints_and_tolerations",
	},
}

func init() {
	AllPatterns[PatternScheduler] = SchedulerPattern
}
