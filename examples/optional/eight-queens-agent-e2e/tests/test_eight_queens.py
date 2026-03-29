from __future__ import annotations

from eight_queens import solve_eight_queens


def test_solution_shape() -> None:
    solution = solve_eight_queens()
    assert isinstance(solution, list)
    assert len(solution) == 8
    assert all(isinstance(item, int) for item in solution)
    assert all(0 <= item < 8 for item in solution)


def test_solution_has_unique_columns() -> None:
    solution = solve_eight_queens()
    assert len(set(solution)) == 8


def test_solution_has_no_diagonal_conflicts() -> None:
    solution = solve_eight_queens()
    for row_a, col_a in enumerate(solution):
        for row_b, col_b in enumerate(solution):
            if row_a >= row_b:
                continue
            assert abs(row_a - row_b) != abs(col_a - col_b)

