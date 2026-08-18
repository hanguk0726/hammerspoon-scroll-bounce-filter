#!/usr/bin/env python3
"""Scroll bounce v6 결정·버퍼 하네스.

init.lua §[7]의 gap-gating + flipTicks + 누적-지연방출 + 잠정확정(grace) 상태 머신을 포팅한다.
실제 배포 Lua 검증은 scrollProcessDeltas(..., nowSeconds) 직접 호출이 기준이고,
이 파일은 임계값 튜닝과 시나리오 회귀를 빠르게 확인하는 보조 오라클이다.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Result:
    delta: int
    decision: str


class ScrollFilter:
    def __init__(
        self,
        flip_ticks: int = 4,
        intentional_gap_ms: int = 150,
        flip_grace_ms: int = 200,
    ):
        self.flip_ticks = flip_ticks
        self.intentional_gap_ms = intentional_gap_ms
        self.flip_grace_ms = flip_grace_ms
        self.committed = 0
        self.reverse_run = 0
        self.buffer = 0
        self.grace_left_ms = 0
        self.pending_dump = False

    def process(self, delta: int, gap_ms: int | None = None) -> Result:
        direction = (delta > 0) - (delta < 0)
        if direction == 0:
            return Result(delta, "pass")

        # v6 잠정 시계: 틱 사이 gap만큼 소모 (Lua scrollDecide 선두와 동일 순서).
        if self.grace_left_ms > 0 and gap_ms is not None:
            self.grace_left_ms -= gap_ms

        if self.committed == 0:
            self.committed = direction
            self.grace_left_ms = 0
            return Result(delta, "pass")

        if direction == self.committed:
            self.reverse_run = 0
            if self.pending_dump:
                # flip 확정 증거: 보류분을 이 틱에 얹어 방출. 단 stale(휴지 후)이면 폐기.
                self.pending_dump = False
                if gap_ms is None or gap_ms < self.intentional_gap_ms:
                    output = delta + self.buffer
                    self.buffer = 0
                    return Result(output, "pass")
            self.buffer = 0
            return Result(delta, "pass")

        # v6 잠정 기간 내 반박: 억제 없이 즉시 방향 복귀 + 통과. 보류분 폐기.
        if self.grace_left_ms > 0:
            self.committed = direction
            self.reverse_run = 0
            self.buffer = 0
            self.pending_dump = False
            return Result(delta, "revert")

        if gap_ms is not None and gap_ms >= self.intentional_gap_ms:
            self.committed = direction
            self.reverse_run = 0
            self.buffer = 0
            self.pending_dump = False
            self.grace_left_ms = self.flip_grace_ms
            return Result(delta, "gapFlip")

        self.reverse_run += 1
        if self.reverse_run >= self.flip_ticks:
            # v6: 몰아방출을 확정틱으로 연기 — 이번 틱은 자기 delta만.
            self.committed = direction
            self.reverse_run = 0
            self.grace_left_ms = self.flip_grace_ms
            self.pending_dump = True
            return Result(delta, "flip")

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
        "dense reversal: flip emits own tick, next tick releases buffer (v6 deferred dump)",
        [(-1, None), (1, 30), (1, 30), (1, 30), (1, 30), (1, 30)],
        [
            Result(-1, "pass"),
            Result(0, "suppress"),
            Result(0, "suppress"),
            Result(0, "suppress"),
            Result(1, "flip"),
            Result(4, "pass"),
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
    run(
        "spurious first tick after pause: revert instead of eating real ticks (v6)",
        [(-1, None), (1, 250), (-1, 40), (-1, 40)],
        [
            Result(-1, "pass"),
            Result(1, "gapFlip"),
            Result(-1, "revert"),
            Result(-1, "pass"),
        ],
    )
    run(
        "wrong flip (4-tick bounce): revert kills reverse jump, buffer discarded (v6)",
        [(-1, None), (1, 30), (1, 30), (1, 30), (1, 30), (-1, 30), (-1, 30)],
        [
            Result(-1, "pass"),
            Result(0, "suppress"),
            Result(0, "suppress"),
            Result(0, "suppress"),
            Result(1, "flip"),
            Result(-1, "revert"),
            Result(-1, "pass"),
        ],
    )
    run(
        "bounce right after real gapFlip: wiggle but nothing eaten (v6)",
        [(-1, None), (1, 300), (-1, 40), (1, 40), (1, 40)],
        [
            Result(-1, "pass"),
            Result(1, "gapFlip"),
            Result(-1, "revert"),
            Result(1, "revert"),
            Result(1, "pass"),
        ],
    )
    run(
        "pending dump goes stale after pause: discarded, no late jump (v6)",
        [(-1, None), (1, 30), (1, 30), (1, 30), (1, 30), (1, 200)],
        [
            Result(-1, "pass"),
            Result(0, "suppress"),
            Result(0, "suppress"),
            Result(0, "suppress"),
            Result(1, "flip"),
            Result(1, "pass"),
        ],
    )
    print("9/9 scenarios passed")
