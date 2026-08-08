"""src/agentic/evaluation/ — v2 Evaluation Framework.

Implements:
- §15.4 Evaluation Engine with gates, Pareto frontier, campaign state machine
- M11 Shadow deployment & canary analysis (Ombre et canaris)
- Complete benchmark suites, endurance testing, domain freeze/import

Conforms to PLAN.md §15.4, M11.
"""

from agentic.evaluation.engine import (
    EvaluationEngine,
    EvaluationResult,
    CampaignStateTracker,
    PromotionDecision,
    CampaignState,
    GateClass,
    GateResult,
    MetricComparison,
    ParetoResult,
)

from agentic.evaluation.shadow_canari import (
    # Core M11 classes
    ShadowDeploymentManager,
    ShadowMode,
    CanaryStrategy,
    
    # Data classes
    ShadowTask,
    TaskResult,
    ShadowComparison,
    ShadowDeploymentState,
    RollbackChronometry,
    
    # Benchmark classes
    BenchmarkManager,
    BenchmarkType,
    BenchmarkStatus,
    BenchmarkMetric,
    BenchmarkResult,
    BenchmarkSuite,
    
    # Endurance classes
    EnduranceManager,
    EnduranceMode,
    EnduranceTest,
    EndurancePhase,
    EnduranceCheckpoint,
    
    # Domain classes
    DomainManager,
    DomainFreezeMode,
    DomainState,
    DomainFreezeOperation,
    DomainIsolationConfig,
    
    # Managers
    RollbackTester,
    
    # Functions
    run_m11_complete_cycle,
    m11_validation_stub,
    m11_quick_validation,
)

__all__ = [
    # Evaluation Engine
    "EvaluationEngine",
    "EvaluationResult", 
    "CampaignStateTracker",
    "PromotionDecision",
    "CampaignState",
    "GateClass",
    "GateResult",
    "MetricComparison", 
    "ParetoResult",
    
    # M11 Shadow/Canary
    "ShadowDeploymentManager",
    "ShadowMode",
    "CanaryStrategy",
    "ShadowTask",
    "TaskResult", 
    "ShadowComparison",
    "ShadowDeploymentState",
    "RollbackChronometry",
    
    # M11 Benchmark
    "BenchmarkManager",
    "BenchmarkType",
    "BenchmarkStatus", 
    "BenchmarkMetric",
    "BenchmarkResult",
    "BenchmarkSuite",
    
    # M11 Endurance
    "EnduranceManager",
    "EnduranceMode",
    "EnduranceTest",
    "EndurancePhase",
    "EnduranceCheckpoint",
    
    # M11 Domain
    "DomainManager",
    "DomainFreezeMode",
    "DomainState",
    "DomainFreezeOperation", 
    "DomainIsolationConfig",
    
    # M11 Managers
    "RollbackTester",
    
    # M11 Functions
    "run_m11_complete_cycle",
    "m11_validation_stub", 
    "m11_quick_validation",
]
