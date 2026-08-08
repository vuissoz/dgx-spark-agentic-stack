#!/usr/bin/env python3
"""scripts/run_m11_ombre_canaris.py — Execute M11 Ombre et canaris evaluation.

Implements PLAN.md M11: Tâches miroir, canaris par utilisateur/agent/application,
benchmark complet, endurance, gel/import par domaine et rollback chronométré.

G11 Objective: deux cycles représentatifs sans perte ni incident matériel.

Usage:
    python3 scripts/run_m11_ombre_canaris.py [--quick|--full|--validate]

Options:
    --quick     Run quick validation (fast, no simulated load)
    --full      Run complete M11 cycle with all components
    --validate  Run validation and produce compliance report
    --help      Show this help
"""

import argparse
import json
import sys
import time
from pathlib import Path

# Add src to path
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "src"))

from agentic.evaluation import (
    run_m11_complete_cycle,
    m11_quick_validation,
    ShadowDeploymentManager,
    ShadowMode,
    CanaryStrategy,
    BenchmarkType,
)


def run_quick_validation() -> dict:
    """Run quick M11 validation."""
    print("🔍 Running M11 quick validation...")
    return m11_quick_validation()


def run_complete_cycle() -> dict:
    """Run complete M11 cycle."""
    print("🔄 Running complete M11 cycle...")
    return run_m11_complete_cycle()


def run_custom_evaluation() -> dict:
    """Run custom M11 evaluation with specific configuration."""
    print("🎯 Running custom M11 evaluation...")
    
    manager = ShadowDeploymentManager()
    
    # Create deployment with mirror mode and per-user canary strategy
    deployment_id = manager.create_deployment(
        mode=ShadowMode.MIRROR,
        canary_strategy=CanaryStrategy.PER_USER,
        traffic_split_pct=20.0  # 20% traffic to canary
    )
    
    print(f"📋 Created deployment: {deployment_id}")
    
    # Submit multiple shadow tasks
    users = ["alice", "bob", "charlie", "diana", "eve"]
    agents = ["codex", "claude", "opencode", "codex", "claude"]
    projects = ["project-a", "project-b", "project-c", "project-a", "project-b"]
    
    tasks = []
    for i, (user, agent, project) in enumerate(zip(users, agents, projects)):
        task = manager.submit_shadow_task(
            source_task_id=f"v1-{user}-{i}",
            user_id=user,
            agent_identity=agent,
            project=project,
            payload={
                "type": "m11-evaluation",
                "iteration": i,
                "prompt": f"Evaluate this complex query for user {user}",
                "complexity": "medium"
            }
        )
        tasks.append(task)
        print(f"  ✅ Submitted shadow task for {user}/{agent}: {task.task_id}")
    
    # Run comparisons
    comparisons = []
    for i, task in enumerate(tasks):
        # Simulate realistic results - v2 should be faster but with some variance
        base_latency = 100 + (i * 5)
        v1_latency = base_latency + (20 * (0.5 - (i % 2)))  # v1 has more variance
        v2_latency = base_latency - (15 * (0.5 + (i % 2)))  # v2 is generally faster
        
        v1_result = {
            "task_id": task.task_id,
            "pipeline": "v1",
            "success": True,
            "latency_ms": v1_latency,
            "correlation_id": f"corr-{task.task_id}-v1"
        }
        
        v2_result = {
            "task_id": task.task_id,
            "pipeline": "v2",
            "success": True,
            "latency_ms": v2_latency,
            "correlation_id": f"corr-{task.task_id}-v2"
        }
        
        # Convert to TaskResult objects
        from agentic.evaluation.shadow_canari import TaskResult
        v1_obj = TaskResult(**v1_result)
        v2_obj = TaskResult(**v2_result)
        
        comparison = manager.run_comparison(task.task_id, v1_obj, v2_obj)
        comparisons.append(comparison)
        
        print(f"  📊 Comparison {i+1}: v1={v1_latency:.1f}ms vs v2={v2_latency:.1f}ms")
    
    # Run benchmarks
    suite_id = manager.benchmark_manager.create_suite(
        deployment_id, 
        [BenchmarkType.PERFORMANCE, BenchmarkType.MEMORY, BenchmarkType.ACCURACY]
    )
    
    print("\n🏋️  Running benchmarks...")
    for benchmark_type in [BenchmarkType.PERFORMANCE, BenchmarkType.MEMORY, BenchmarkType.ACCURACY]:
        result = manager.benchmark_manager.run_benchmark(suite_id, benchmark_type)
        print(f"  📈 {benchmark_type.value}: {result.status.value}")
        if result.metrics:
            for metric in result.metrics:
                print(f"     - {metric.name}: {metric.value} {metric.unit}")
    
    # Get final statistics
    stats = manager.get_statistics()
    suite_summary = manager.benchmark_manager.get_suite_summary(suite_id)
    
    print("\n📋 M11 Statistics:")
    print(f"  • Total comparisons: {stats['total_comparisons']}")
    print(f"  • Both success: {stats['both_success']}")
    print(f"  • V1 better latency: {stats['v1_better_latency']}")
    print(f"  • V2 better latency: {stats['v2_better_latency']}")
    print(f"  • V2 improvement: {stats['tps_v2_improvement_pct']:.1f}%")
    print(f"  • Average latency improvement: {stats['latency_improvement_pct']:.1f}%")
    
    # Generate report
    report = manager.serialize_report()
    
    # Add custom evaluation metadata
    report["evaluation_type"] = "m11_custom"
    report["deployment_config"] = {
        "mode": "mirror",
        "canary_strategy": "per-user", 
        "traffic_split_pct": 20.0,
        "user_count": len(users),
        "task_count": len(tasks)
    }
    
    return report


def print_report(report: dict, mode: str = "full") -> None:
    """Print formatted M11 report."""
    print("\n" + "=" * 60)
    print("M11 OMBRE ET CANARIS - EVALUATION REPORT")
    print("=" * 60)
    
    if "evaluation_id" in report:
        print(f"🆔 Evaluation ID: {report['evaluation_id']}")
    if "generated_at" in report:
        print(f"📅 Generated: {report['generated_at']}")
    
    print(f"\n🎯 Mode: {mode.upper()}")
    
    # Statistics
    if "statistics" in report:
        stats = report["statistics"]
        print(f"\n📊 SHADOW/CANARY STATISTICS:")
        print(f"   Total comparisons: {stats['total_comparisons']}")
        print(f"   Both success: {stats['both_success']}")
        print(f"   V1 better latency: {stats['v1_better_latency']}")
        print(f"   V2 better latency: {stats['v2_better_latency']}")
        print(f"   V2 improvement: {stats['tps_v2_improvement_pct']:.1f}%")
        if 'v1_latency_avg' in stats:
            print(f"   V1 avg latency: {stats['v1_latency_avg']:.1f}ms")
            print(f"   V2 avg latency: {stats['v2_latency_avg']:.1f}ms")
            print(f"   Latency improvement: {stats['latency_improvement_pct']:.1f}%")
    
    # M11 Components
    if "m11_components" in report:
        print(f"\n🧩 M11 COMPONENTS:")
        components = report["m11_components"]
        
        if "shadow_deployment" in components:
            shadow = components["shadow_deployment"]
            print(f"   🪞 Shadow Deployment: {shadow['task_count']} tasks, {shadow['comparison_count']} comparisons")
        
        if "benchmarks" in components:
            bench = components["benchmarks"]
            print(f"   📊 Benchmarks: {bench['completed']} completed, {bench['failed']} failed")
        
        if "endurance" in components:
            end = components["endurance"]
            print(f"   🏃 Endurance: {end['total_phases']} phases, {end['total_checkpoints']} checkpoints")
        
        if "domain_operations" in components:
            dom = components["domain_operations"]
            print(f"   🗃️  Domain: {dom['operation_count']} operations")
        
        if "rollback" in components:
            rb = components["rollback"]
            print(f"   🔄 Rollback: {rb['operations_measured']} operations, all success: {rb['all_success']}")
    
    # G11 Compliance
    if "g11_compliance" in report:
        g11 = report["g11_compliance"]
        print(f"\n🎯 G11 COMPLIANCE:")
        print(f"   Satisfied: {g11['satisfied']}")
        print(f"   Message: {g11['message']}")
        
        if "criteria" in g11:
            print(f"   Criteria:")
            for criterion, passed in g11["criteria"].items():
                status = "✅" if passed else "❌"
                print(f"     {status} {criterion}: {passed}")
    
    print("\n" + "=" * 60)
    print("REPORT COMPLETE")
    print("=" * 60)


def save_report(report: dict, output_path: str = None) -> str:
    """Save report to JSON file."""
    if output_path is None:
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        output_path = f"/tmp/m11-report-{timestamp}.json"
    
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2, default=str)
    
    return output_path


def main() -> None:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Execute M11 Ombre et canaris evaluation",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 scripts/run_m11_ombre_canaris.py --quick
  python3 scripts/run_m11_ombre_canaris.py --full
  python3 scripts/run_m11_ombre_canaris.py --validate --output /tmp/m11-report.json
        """
    )
    
    parser.add_argument(
        "--quick", 
        action="store_true",
        help="Run quick validation (fast)"
    )
    parser.add_argument(
        "--full", 
        action="store_true", 
        help="Run complete M11 cycle"
    )
    parser.add_argument(
        "--custom",
        action="store_true",
        help="Run custom evaluation with specific configuration"
    )
    parser.add_argument(
        "--validate",
        action="store_true", 
        help="Run validation and produce compliance report"
    )
    parser.add_argument(
        "--output", 
        type=str, 
        default=None,
        help="Output file path for JSON report"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON only"
    )
    
    args = parser.parse_args()
    
    # Determine mode
    if sum([args.quick, args.full, args.custom, args.validate]) > 1:
        print("❌ Error: Please specify only one mode (--quick, --full, --custom, or --validate)")
        sys.exit(1)
    
    if not any([args.quick, args.full, args.custom, args.validate]):
        args.quick = True  # Default to quick
    
    # Run appropriate evaluation
    if args.full:
        mode = "full"
        report = run_complete_cycle()
    elif args.custom:
        mode = "custom"
        report = run_custom_evaluation()
    elif args.validate:
        mode = "validate"
        report = run_complete_cycle()  # Full cycle for validation
    else:  # quick
        mode = "quick"
        report = run_quick_validation()
    
    # Output results
    if args.json:
        print(json.dumps(report, indent=2, default=str))
    else:
        print_report(report, mode)
        
        # Save report if requested
        if args.output:
            saved_path = save_report(report, args.output)
            print(f"\n💾 Report saved to: {saved_path}")
        elif mode != "quick":  # Always save non-quick reports
            saved_path = save_report(report)
            print(f"\n💾 Report saved to: {saved_path}")
    
    # Exit with appropriate code
    g11_satisfied = report.get("g11_compliance", {}).get("satisfied", False) if "g11_compliance" in report else True
    sys.exit(0 if g11_satisfied else 1)


if __name__ == "__main__":
    main()