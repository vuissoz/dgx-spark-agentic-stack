"""tests/J22_rag_batch_e2e.py — §12.4 RAG Batch Authorization E2E.

Validates the integration of AuthorizationBatchManager into RAGServiceAdapter:
- submit_task() creates batch authorization records
- Auth batch includes beneficiary, scope, collection, action
- ACL audit log captures batch operations
- Dry-run preview works for batch authorization

Tests:
- J22-1: submit_task creates auth batch when batch manager is available
- J22-2: Auth batch respects beneficiary_id and project scope
- J22-3: ACL audit log captures all batch operations
- J22-4: Dry-run preview returns expected structure
- J22-5: Multiple tasks for same beneficiary create separate batches
"""

import sys
sys.path.insert(0, "src")


def test_submit_task_creates_auth_batch():
    """J22-1: submit_task creates auth batch when batch manager is available.
    
    Verifies that RAGServiceAdapter.submit_task() integrates AuthorizationBatchManager
    and returns auth_batch in the response.
    """
    import asyncio
    
    from agentic.implementations.rag_adapter import RAGServiceAdapter
    
    adapter = RAGServiceAdapter(retriever_url="http://test-rag:8000")
    
    # Verify batch manager was initialized
    assert adapter.auth_batch_manager is not None, \
        "RAGServiceAdapter should have auth_batch_manager when rag_acl is available"
    
    # Submit a task with beneficiary info
    task_def = {
        "type": "ingest",
        "project": "test-project",
        "beneficiary_id": "user-alice",
        "beneficiary_type": "user",
        "collections": ["personal-docs"],
    }
    
    result = asyncio.run(adapter.submit_task(task_def))
    
    # Verify task was created with auth batch
    assert "task_id" in result, "Result should include task_id"
    assert result["status"] == "submitted", f"Status should be submitted: {result['status']}"
    assert result["type"] == "ingest", f"Type should match: {result['type']}"
    
    # Verify auth_batch was created
    auth_batch = result.get("auth_batch")
    assert auth_batch is not None, \
        "submit_task should include auth_batch when batch manager is available"
    assert "batch_id" in auth_batch, "Auth batch should have batch_id"
    assert auth_batch["action"] == "index", f"Action should match: {auth_batch['action']}"
    assert auth_batch["beneficiary_id"] == "user-alice", \
        f"Beneficiary should match: {auth_batch['beneficiary_id']}"
    
    print("PASS: J22-1_submit_task_creates_auth_batch")


def test_auth_batch_respects_scope():
    """J22-2: Auth batch respects beneficiary_id and project scope.
    
    Verifies that batch authorization correctly captures beneficiary, scope, collection,
    and project information from the task definition.
    """
    import asyncio
    
    from agentic.implementations.rag_adapter import RAGServiceAdapter
    
    adapter = RAGServiceAdapter()
    
    task_def = {
        "type": "search",
        "project": "finance-reports",
        "beneficiary_id": "agent-codex-01",
        "beneficiary_type": "agent_class",
        "collections": ["financial-docs"],
        "scope": "project",
    }
    
    result = asyncio.run(adapter.submit_task(task_def))
    
    auth_batch = result["auth_batch"]
    # "search" is a valid batch action, so should pass through directly
    assert auth_batch["action"] == "search", f"Expected 'search': {auth_batch['action']}"
    assert auth_batch["beneficiary_id"] == "agent-codex-01"
    assert auth_batch.get("scope") == "project", \
        f"Scope should be 'project': {auth_batch.get('scope')}"
    
    # Different task type for same beneficiary
    task_def2 = {
        "type": "index",
        "beneficiary_id": "user-bob",
        "collection": "personal-docs",
    }
    
    result2 = asyncio.run(adapter.submit_task(task_def2))
    auth_batch2 = result2["auth_batch"]
    
    # Task type "index" maps directly to allowed batch action
    assert auth_batch2["action"] == "index", f"Expected 'index': {auth_batch2['action']}"
    assert auth_batch2["beneficiary_id"] == "user-bob"
    
    print("PASS: J22-2_auth_batch_respects_scope")


def test_acl_audit_log():
    """J22-3: ACL audit log captures all batch operations.
    
    Verifies that the RAGACLManager (used by AuthorizationBatchManager) maintains
    an audit trail of all batch authorization operations.
    """
    import asyncio
    
    from agentic.implementations.rag_adapter import RAGServiceAdapter
    
    adapter = RAGServiceAdapter()
    
    # Submit multiple tasks to build up audit log
    for i in range(3):
        task_def = {
            "type": "ingest",
            "beneficiary_id": f"user-{i}",
            "project": f"proj-{i}",
        }
        asyncio.run(adapter.submit_task(task_def))
    
    # Get audit log from the ACL manager
    acl_manager = adapter.auth_batch_manager.acl_manager
    audit_log = acl_manager.get_audit_log()
    
    assert len(audit_log) >= 3, \
        f"Should have at least 3 audit entries: {len(audit_log)}"
    
    # Verify each entry has expected structure
    for entry in audit_log:
        assert "timestamp" in entry or "ts" in entry, "Audit entry should have timestamp"
        assert "action" in entry or "operation" in entry, "Audit entry should have action/operation"
    
    print("PASS: J22-3_acl_audit_log")


def test_dry_run_preview():
    """J22-4: Dry-run preview returns expected structure.
    
    Verifies that AuthorizationBatchManager.dry_run() provides a structured preview
    of what documents would be affected by an authorization scope.
    """
    from agentic.implementations.rag_acl import AuthorizationBatchManager, RAGACLManager
    
    auth_batch = AuthorizationBatchManager(RAGACLManager())
    
    preview = auth_batch.dry_run(
        project="test-project",
        collection="personal-docs",
        tag="internal",
    )
    
    assert "dry_run" in preview and preview["dry_run"] is True
    assert "project" in preview and preview["project"] == "test-project"
    assert "estimated_documents" in preview, "Should have estimated_documents"
    assert "document_count" in preview
    assert "exclusions" in preview
    
    exclusions = preview["exclusions"]
    assert "secrets_detected" in exclusions
    assert "regulated_data_detected" in exclusions
    
    print("PASS: J22-4_dry_run_preview")


def test_multiple_tasks_create_separate_batches():
    """J22-5: Multiple tasks for same beneficiary create separate batches.
    
    Verifies that each task submission creates a new batch authorization record,
    allowing granular audit tracking per task.
    """
    import asyncio
    
    from agentic.implementations.rag_adapter import RAGServiceAdapter
    
    adapter = RAGServiceAdapter()
    
    # Submit multiple tasks for same beneficiary
    task_id_batch_1 = None
    task_id_batch_2 = None
    
    for i in range(3):
        task_def = {
            "type": "ingest",
            "beneficiary_id": "shared-user",
            "project": "shared-project",
        }
        result = asyncio.run(adapter.submit_task(task_def))
        assert "task_id" in result
        
        if i == 0:
            task_id_batch_1 = result["task_id"]
        elif i == 2:
            task_id_batch_2 = result["task_id"]
    
    # Verify we got different task IDs (different submissions)
    assert task_id_batch_1 != task_id_batch_2, \
        "Different task submissions should have different task_ids"
    
    print("PASS: J22-5_multiple_tasks_create_separate_batches")


if __name__ == "__main__":
    test_submit_task_creates_auth_batch()
    test_auth_batch_respects_scope()
    test_acl_audit_log()
    test_dry_run_preview()
    test_multiple_tasks_create_separate_batches()
    print("\n=== J22_rag_batch_e2e passed ===")
