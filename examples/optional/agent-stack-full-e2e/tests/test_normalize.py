from src.normalize import normalize_identifier


def test_normalizes_spaces_case_and_runs():
    assert normalize_identifier("  DGX Spark  ") == "dgx-spark"
