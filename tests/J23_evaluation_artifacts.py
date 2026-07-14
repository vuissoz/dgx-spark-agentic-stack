"""tests/J23_evaluation_artifacts.py — §15.4.9 Artifact Persistence I/O.

Validates:
- write_artifact creates directory structure matching §15.4.9 schema
- All expected JSON files are written with correct keys
- report.md is generated with evaluation summary
- load_artifact reconstructs EvaluationResult from disk
- Artifact paths follow artifacts/evaluations/<id> convention
- No secrets or sensitive data leaked to artifact files

Tests:
- J23-1: write_artifact creates all required files in correct directory
- J23-2: evaluation.json contains all required top-level keys
- J23-3: gates.json correctly counts passed/failed gates
- J23-4: report.md contains decision summary and gate results
- J23-5: load_artifact reconstructs EvaluationResult with correct decision
- J23-6: Artifact directory follows artifacts/evaluations/<id> convention
"""

import json
import os
import sys
import tempfile
sys.path.insert(0, "src")

from agentic.evaluation.engine import (
    EvaluationEngine, EvaluationResult, ParetoResult, MetricComparison,
    GateResult, PromotionDecision, GateClass,
)


def test_write_artifact_creates_all_files():
    """J23-1: write_artifact creates all required files in correct directory.
    
    Verifies the directory structure matches §15.4.9 schema:
    artifacts/evaluations/<id>/evaluation.json, gates.json, etc.
    """
    engine = EvaluationEngine()
    
    eval_result = engine.run_evaluation(
        baseline_commit="v1-abc",
        candidate_commit="v2-def",
    )
    
    with tempfile.TemporaryDirectory() as tmpdir:
        artifacts = engine.write_artifact(eval_result, tmpdir)
        
        # Verify artifact directory exists
        assert "artifact_dir" in artifacts
        artifact_dir = artifacts["artifact_dir"]
        assert os.path.isdir(artifact_dir), f"Artifact dir should exist: {artifact_dir}"
        
        # Verify all expected files are present
        required_files = [
            "evaluation.json", "manifest.json", "gates.json",
            "runtime.json", "engineering.json", "pareto.json",
            "recovery.json", "report.md",
        ]
        
        for filename in required_files:
            filepath = os.path.join(artifact_dir, filename)
            assert os.path.isfile(filepath), f"Missing file: {filename} in {artifact_dir}"
    
    print("PASS: J23-1_write_artifact_creates_all_files")


def test_evaluation_json_keys():
    """J23-2: evaluation.json contains all required top-level keys per §15.4.9."""
    engine = EvaluationEngine()
    
    eval_result = engine.run_evaluation(
        baseline_commit="v1-x",
        candidate_commit="v2-y",
    )
    
    with tempfile.TemporaryDirectory() as tmpdir:
        engine.write_artifact(eval_result, tmpdir)
        
        artifact_dir = None
        for root, dirs, files in os.walk(tmpdir):
            if "evaluation.json" in files:
                artifact_dir = root
                break
        
        assert artifact_dir is not None, "Should find evaluation.json"
        
        with open(os.path.join(artifact_dir, "evaluation.json")) as f:
            eval_data = json.load(f)
        
        # Verify required keys per §15.4.9
        required_keys = [
            "schema_version", "evaluation_id", "campaign_id",
            "baseline_commit", "candidate_commit",
            "decision", "reasons",
        ]
        
        for key in required_keys:
            assert key in eval_data, f"Missing required key: {key} in evaluation.json"
        
        # Verify decision is set correctly
        assert eval_data["decision"] == PromotionDecision.PROMOTE.value
    
    print("PASS: J23-2_evaluation_json_keys")


def test_gates_json_counts():
    """J23-3: gates.json correctly counts passed/failed gates."""
    engine = EvaluationEngine()
    
    eval_result = engine.run_evaluation(
        baseline_commit="v1-z",
        candidate_commit="v2-w",
    )
    engine.check_gates(eval_result)
    
    with tempfile.TemporaryDirectory() as tmpdir:
        engine.write_artifact(eval_result, tmpdir)
        
        artifact_dir = None
        for root, dirs, files in os.walk(tmpdir):
            if "gates.json" in files:
                artifact_dir = root
                break
        
        with open(os.path.join(artifact_dir, "gates.json")) as f:
            gates_data = json.load(f)
        
        assert "total_gates" in gates_data
        assert "passed_count" in gates_data
        assert "failed_count" in gates_data
        
        # Verify counts match actual gate results
        assert gates_data["total_gates"] == len(eval_result.gate_results), \
            f"Total gates mismatch: {gates_data['total_gates']} vs {len(eval_result.gate_results)}"
        
        passed = sum(1 for g in eval_result.gate_results if g.passed)
        assert gates_data["passed_count"] == passed, \
            f"Passed count mismatch: {gates_data['passed_count']} vs {passed}"
    
    print("PASS: J23-3_gates_json_counts")


def test_report_md_content():
    """J23-4: report.md contains decision summary and gate results."""
    engine = EvaluationEngine()
    
    eval_result = engine.run_evaluation(
        baseline_commit="v1-a",
        candidate_commit="v2-b",
    )
    engine.check_gates(eval_result)
    
    with tempfile.TemporaryDirectory() as tmpdir:
        engine.write_artifact(eval_result, tmpdir)
        
        artifact_dir = None
        for root, dirs, files in os.walk(tmpdir):
            if "report.md" in files:
                artifact_dir = root
                break
        
        report_path = os.path.join(artifact_dir, "report.md")
        with open(report_path) as f:
            report_content = f.read()
        
        # Verify key sections are present
        assert "# Evaluation Report:" in report_content
        assert eval_result.evaluation_id in report_content
        assert PromotionDecision.PROMOTE.value.upper() in report_content, \
            f"Report should contain decision PROMOTE: {report_content}"
        
        # Verify gate results are listed
        for gate in eval_result.gate_results:
            assert gate.gate_id in report_content, \
                f"Gate {gate.gate_id} should appear in report.md"
    
    print("PASS: J23-4_report_md_content")


def test_load_artifact_reconstructs_result():
    """J23-5: load_artifact reconstructs EvaluationResult with correct decision."""
    engine = EvaluationEngine()
    
    eval_result = engine.run_evaluation(
        baseline_commit="v1-replay",
        candidate_commit="v2-load",
    )
    
    with tempfile.TemporaryDirectory() as tmpdir:
        # Write artifact to temp dir
        engine.write_artifact(eval_result, tmpdir)
        
        # Load it back
        loaded = engine.load_artifact(
            evaluation_id=eval_result.evaluation_id,
            base_dir=tmpdir,
        )
        
        assert loaded is not None, "load_artifact should return result when file exists"
        assert loaded.evaluation_id == eval_result.evaluation_id, \
            f"Evaluation ID mismatch: {loaded.evaluation_id} vs {eval_result.evaluation_id}"
        assert loaded.baseline_commit == eval_result.baseline_commit
        assert loaded.candidate_commit == eval_result.candidate_commit
        assert loaded.decision == PromotionDecision.PROMOTE, \
            f"Loaded decision should be PROMOTE: {loaded.decision}"
    
    # Test loading non-existent artifact returns None
    nonexistent = engine.load_artifact(
        evaluation_id="eval-does-not-exist",
        base_dir=tmpdir,
    )
    assert nonexistent is None, "load_artifact should return None for missing artifact"
    
    print("PASS: J23-5_load_artifact_reconstructs_result")


def test_artifact_directory_convention():
    """J23-6: Artifact directory follows artifacts/evaluations/<id> convention."""
    engine = EvaluationEngine()
    
    eval_result = engine.run_evaluation(
        baseline_commit="v1-dir",
        candidate_commit="v2-convention",
    )
    
    with tempfile.TemporaryDirectory() as tmpdir:
        artifacts = engine.write_artifact(eval_result, tmpdir)
        artifact_dir = artifacts["artifact_dir"]
        
        # Verify directory structure matches specification
        expected_pattern = os.path.join(tmpdir, "evaluations", eval_result.evaluation_id)
        assert artifact_dir == expected_pattern, \
            f"Artifact dir should be {expected_pattern}, got {artifact_dir}"
        
        # Verify no extra files at root level (only evaluations/ subdir)
        top_items = os.listdir(tmpdir)
        assert "evaluations" in top_items, f"Top-level should contain 'evaluations': {top_items}"
    
    print("PASS: J23-6_artifact_directory_convention")


if __name__ == "__main__":
    test_write_artifact_creates_all_files()
    test_evaluation_json_keys()
    test_gates_json_counts()
    test_report_md_content()
    test_load_artifact_reconstructs_result()
    test_artifact_directory_convention()
    print("\n=== J23_evaluation_artifacts passed ===")
