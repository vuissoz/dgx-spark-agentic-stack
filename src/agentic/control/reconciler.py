#!/usr/bin/env python3
"""src/agentic/control/reconciler.py — Desired/Observed State Reconciler (§3.1).

This reconciler bridges the outbox pattern from worker.py to actual state reconciliation:
- Reads completed/failed entries from the outbox
- Compares desired_state (PostgreSQL/manifest) vs observed_state (Docker/live)
- Applies drift fixes or reports anomalies
- Idempotent operations with correlation identifiers

Conforms to PLAN.md §3.1 monolithe modulaire de control and §4 sources de verite.
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Optional


@dataclass
class StateSnapshot:
    """Represents the desired or observed state of a service/component."""
    component_id: str
    desired: bool          # Is this what we want?
    observed: bool         # What is actually running/healthy?
    metadata: dict[str, Any] = field(default_factory=dict)
    last_check: float = field(default_factory=time.time)


@dataclass
class DriftReport:
    """Report of desired vs observed state drift."""
    component_id: str
    expected_state: bool
    actual_state: bool
    action_taken: str      # "no_action", "reconciled", "escalated", "failed"
    details: str = ""


class StateReconciler:
    """Desired/Observed state reconciler for control plane (§3.1).

    This is the core logic that reads from PostgreSQL outbox (via worker.outbox),
    compares desired configuration against live Docker/runtime state, and applies
    corrective actions or escalates anomalies.
    """

    def __init__(self):
        self.desired_state: dict[str, StateSnapshot] = {}  # component_id → desired config
        self.observed_state: dict[str, StateSnapshot] = {}  # component_id → live state
        self.drift_history: list[DriftReport] = []
        self.reconciliation_fn: Optional[Callable[[str], bool]] = None  # user-provided reconciler

    def register_desired(self, component_id: str, desired: bool, metadata: dict[str, Any] | None = None) -> None:
        """Register the desired state for a component."""
        self.desired_state[component_id] = StateSnapshot(
            component_id=component_id,
            desired=desired,
            observed=True,  # Will be updated on next reconcile cycle
            metadata=metadata or {},
        )

    def update_observed(self, component_id: str, observed: bool, metadata: dict[str, Any] | None = None) -> None:
        """Update the observed (live) state for a component."""
        self.observed_state[component_id] = StateSnapshot(
            component_id=component_id,
            desired=True,  # Default to desired unless explicitly set
            observed=observed,
            metadata=metadata or {},
        )

    def check_drift(self) -> list[DriftReport]:
        """Compare desired vs observed state and return drift reports."""
        reports = []
        
        for component_id, desired in self.desired_state.items():
            observed = self.observed_state.get(component_id)
            
            if not observed:
                # Component has no observed state — treat as drift
                report = DriftReport(
                    component_id=component_id,
                    expected_state=True,  # If desired is registered, we expect it
                    actual_state=False,
                    action_taken="escalated",
                    details=f"Observed state missing for {component_id}",
                )
            elif desired.desired != observed.observed:
                report = DriftReport(
                    component_id=component_id,
                    expected_state=desired.desired,
                    actual_state=observed.observed,
                    action_taken="pending",
                    details=f"Desired={desired.desired}, Observed={observed.observed}",
                )
            else:
                # No drift
                continue
            
            reports.append(report)
        
        return reports

    async def reconcile(self, timeout_seconds: float = 30.0) -> list[DriftReport]:
        """Run a full reconciliation cycle.

        Reads outbox entries, updates observed state, checks for drift,
        and applies corrective actions (or escalates if manual intervention needed).
        """
        import time as _time
        
        start_time = _time.time()
        drift_reports = self.check_drift()
        
        for report in drift_reports:
            if report.action_taken == "pending":
                # Try to auto-reconcile if a reconciler function is registered
                if self.reconciliation_fn:
                    try:
                        success = self.reconciliation_fn(report.component_id)
                        report.action_taken = "reconciled" if success else "failed"
                    except Exception as e:
                        report.action_taken = "failed"
                        report.details = str(e)
                else:
                    report.action_taken = "escalated"
            
            self.drift_history.append(report)
        
        return drift_reports

    def register_reconciler(self, fn: Callable[[str], bool]) -> None:
        """Register a custom reconciliation function."""
        self.reconciliation_fn = fn


# ── Integration with Worker Outbox (§3.1) ───────────────────────────

class OutboxReconciler(StateReconciler):
    """Reconciler that reads from TaskWorker outbox and applies state corrections."""

    def __init__(self, worker_outbox=None):
        super().__init__()
        self.worker_outbox = worker_outbox  # TaskOutbox instance from worker.py

    async def reconcile_from_outbox(self) -> list[DriftReport]:
        """Pull completed entries from outbox and reconcile observed state."""
        if not self.worker_outbox:
            return []

        completed_entries = self.worker_outbox.pull_completed()
        
        for entry in completed_entries:
            task_id = entry.get("task_id", "")
            status = entry.get("status", "")
            
            # Map task status to component observed state
            if status == "completed":
                self.update_observed(task_id, observed=True, metadata={"result": entry.get("result")})
            elif status == "failed":
                self.update_observed(task_id, observed=False, metadata={"error": entry.get("result", {}).get("error")})

        # Clear processed entries
        correlation_ids = {e.get("correlation_id") for e in completed_entries}
        if correlation_ids:
            self.worker_outbox.clear_processed(correlation_ids)

        return await self.reconcile()


# ── CLI entry point ────────────────────────────────────────────────

def main() -> int:
    import argparse
    import json

    parser = argparse.ArgumentParser(description="State Reconciler — drift detection and correction")
    parser.add_argument("--action", choices=["status", "drift", "reconcile"], default="status")
    args = parser.parse_args()

    reconciler = StateReconciler()

    # Register sample desired state
    for comp in ["ollama-gate", "codex", "hermes", "comfyui"]:
        reconciler.register_desired(comp, desired=True, metadata={"type": "agent_or_service"})

    # Simulate observed state (one drift: comfyui is down)
    reconciler.update_observed("ollama-gate", observed=True)
    reconciler.update_observed("codex", observed=True)
    reconciler.update_observed("hermes", observed=True)
    reconciler.update_observed("comfyui", observed=False, metadata={"reason": "container crashed"})

    if args.action == "status":
        result = {
            "desired_components": len(reconciler.desired_state),
            "observed_components": len(reconciler.observed_state),
            "healthy_count": sum(1 for o in reconciler.observed_state.values() if o.observed),
        }
    elif args.action == "drift":
        drift = reconciler.check_drift()
        result = {
            "drifts_found": len(drift),
            "reports": [d.__dict__ for d in drift],
        }
    elif args.action == "reconcile":
        # Simulate auto-reconciliation by fixing comfyui
        def fix_comfyui(comp_id: str) -> bool:
            if comp_id == "comfyui":
                reconciler.update_observed(comp_id, observed=True, metadata={"reason": "auto-restarted"})
                return True
            return False
        
        reconciler.register_reconciler(fix_comfyui)
        drift = asyncio.run(reconciler.reconcile())
        result = {
            "drifts_found_before": len(drift),
            "after_reconciliation": [d.__dict__ for d in reconciler.drift_history],
        }

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
