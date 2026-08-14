#!/usr/bin/env python3
"""Scroll bounce v5 결정·버퍼 하네스.

init.lua §[7]의 gap-gating + flipTicks + 누적-방출 상태 머신을 포팅한다.
실제 배포 Lua 검증은 scrollProcessDeltas(..., nowSeconds) 직접 호출이 기준이고,
이 파일은 임계값 튜닝과 시나리오 회귀를 빠르게 확인하는 보조 오라클이다.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Result:
    delta: int
    decision: str


class ScrollFilter:
    def __init__(self, flip_ticks: int = 4, intentional_gap_ms: int = 150):
        self.flip_ticks = flip_ticks
        self.intentional_gap_ms = intentional_gap_ms
        self.committed = 0
        self.reverse_run = 0
        self.buffer = 0

    def process(self, delta: int, gap_ms: int | None = None) -> Result:
        direction = (delta > 0) - (delta < 0)
        if direction == 0:
            return Result(delta, "pass")

        if self.committed == 0:
            self.committed = direction
            return Result(delta, "pass")

        if direction == self.committed:
            self.reverse_run = 0
            self.buffer = 0
            return Result(delta, "pass")

        if gap_ms is not None and gap_ms >= self.intentional_gap_ms:
            self.committed = direction
            self.reverse_run = 0
            self.buffer = 0
            return Result(delta, "gapFlip")

        self.reverse_run += 1
        if self.reverse_run >= self.flip_ticks:
            self.committed = direction
            self.reverse_run = 0
            output = delta + self.buffer
            self.buffer = 0
            return Result(output, "flip")

        self.buffer += delta
        return Result(0, "suppress")


def run(name: str, samples: list[tuple[int, int | None]], expected: list[Result]) -> None:
    actual_filter = ScrollFilter()
    actual = [actual_filter.process(delta, gap_ms) for delta, gap_ms in samples]
    assert actual == expected, f"{name}\nexpected={expected}\nactual={actual}"
    print(f"PASS {name}")


if __name__ == "__main__":
    run(
        "dense bounce <=3 ticks is suppressed",
        [(-1, None), (1, 30), (1, 30), (1, 30), (-1, 30)],
        [
            Result(-1, "pass"),
            Result(0, "suppress"),
            Result(0, "suppress"),
            Result(0, "suppress"),
            Result(-1, "pass"),
        ],
    )
    run(
        "dense reversal releases buffered distance",
        [(-1, None), (1, 30), (1, 30), (1, 30), (1, 30)],
        [
            Result(-1, "pass"),
            Result(0, "suppress"),
            Result(0, "suppress"),
            Result(0, "suppress"),
            Result(4, "flip"),
        ],
    )
    run(
        "paused reversal passes immediately",
        [(-1, None), (1, 250)],
        [Result(-1, "pass"), Result(1, "gapFlip")],
    )
    run(
        "stale buffer is discarded at gap boundary",
        [(-1, None), (1, 30), (1, 270)],
        [Result(-1, "pass"), Result(0, "suppress"), Result(1, "gapFlip")],
    )
    run(
        "sub-threshold gap preserves v4 path",
        [(-1, None), (1, 149)],
        [Result(-1, "pass"), Result(0, "suppress")],
    )
    print("5/5 scenarios passed")
