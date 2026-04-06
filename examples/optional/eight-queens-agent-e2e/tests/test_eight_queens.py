from __future__ import annotations

from eight_queens import solve_eight_queens


def expected_solutions() -> list[tuple[int, ...]]:
    solutions: list[tuple[int, ...]] = []
    placement: list[int] = []

    def backtrack(row: int) -> None:
        if row == 8:
            solutions.append(tuple(placement))
            return

        for col in range(8):
            if col in placement:
                continue
            if any(abs(prev_row - row) == abs(prev_col - col) for prev_row, prev_col in enumerate(placement)):
                continue
            placement.append(col)
            backtrack(row + 1)
            placement.pop()

    backtrack(0)
    return solutions


EXPECTED_SOLUTIONS = expected_solutions()


def test_solution_shape() -> None:
    solutions = solve_eight_queens()
    assert isinstance(solutions, list)
    assert len(solutions) == 92
    assert solutions == sorted(solutions)
    assert all(isinstance(solution, tuple) for solution in solutions)
    assert all(len(solution) == 8 for solution in solutions)
    assert all(isinstance(col, int) for solution in solutions for col in solution)
    assert all(0 <= col < 8 for solution in solutions for col in solution)


def test_solutions_are_unique_and_complete() -> None:
    solutions = solve_eight_queens()
    assert len(set(solutions)) == 92
    assert solutions == EXPECTED_SOLUTIONS


def test_every_solution_is_valid() -> None:
    for solution in solve_eight_queens():
        assert len(set(solution)) == 8
        for row_a, col_a in enumerate(solution):
            for row_b, col_b in enumerate(solution):
                if row_a >= row_b:
                    continue
                assert abs(row_a - row_b) != abs(col_a - col_b)
