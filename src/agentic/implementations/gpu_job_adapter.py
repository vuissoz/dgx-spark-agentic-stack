#!/usr/bin/env python3
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any

@dataclass(frozen=True)
class GPUJobSpec:
    job_id: str
    workflow: dict[str, Any] = field(default_factory=dict)
    model_name: str = ""
    priority: str = "normal"

class GPUJobAdapter:
    def __init__(self, project="agentic-dev", max_concurrent=2):
        self.project = project
        self.max_concurrent = max_concurrent
        self._jobs = {}
        self._results = {}
        self._running_count = 0

    async def admit_job(self, job_spec: GPUJobSpec) -> dict[str, Any]:
        if self._running_count >= self.max_concurrent:
            return {"admitted": False, "reason": f"Max jobs ({self.max_concurrent}) reached"}
        return {"admitted": True}

    async def observe_job(self, job_id: str) -> dict[str, Any]:
        result = self._results.get(job_id)
        if not result:
            return {"error": f"Job {job_id} not found", "status_code": 404}
        return {"job_id": job_id, "status": result.status}

    async def cancel_job(self, job_id: str) -> bool:
        if job_id not in self._results:
            return False
        self._results[job_id].status = "cancelled"
        self._running_count = max(0, self._running_count - 1)
        return True

if __name__ == "__main__":
    print("GPUJobAdapter loaded")
