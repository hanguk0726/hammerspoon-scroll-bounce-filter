# hammerspoon-scroll-bounce-filter

노치(단계식) 마우스 휠의 스퓨리어스 역틱("아래로 굴리는데 순간 위로 톡" 튐)을 [Hammerspoon](https://www.hammerspoon.org/) eventtap으로 억제하는 필터. **v6** — run-길이 임계 + gap-게이팅 + 누적-지연방출(변위 무손실) + 잠정확정(grace).

## 왜 이 구조인가

실측(260틱 fp-trace)으로 확정된 제약: 튐 틱과 진짜 반전 틱은 **이벤트 수준에서 바이트 동일**(magnitude·fixedPt·타이밍·phase 메타 전 축 분포 겹침 — 노치 휠은 phase 메타데이터가 전부 0). 즉 per-tick 분류는 정보 부재로 불가능하고, 유일 판별자는 **시퀀스**(역방향 run 길이 + 휴지 gap)뿐이다.

이 제약 하에서의 최적 구조 = 순차검정(sequential detection) 형태:

- **run-길이 임계** (`flipTicks=4`): 역방향 틱이 연속 4개 모이기 전엔 튐으로 억제, 이상이면 진짜 반전. run 길이의 우도비 단조성(튐 ≤4틱, 반전은 지속) 하에서 임계 규칙이 최강력 검정 (Karlin–Rubin).
- **gap-게이팅** (`150ms`): 마지막 틱 후 150ms 이상 휴지 뒤 시작한 역방향은 의도적 반전으로 즉시 확정 — 이 축은 이봉 분포(튐 진입 gap 26~57ms vs 의도 반전 250ms+)라 즉시 판정 가능.
- **누적-지연방출** (v6): 억제한 틱의 delta를 버퍼에 쌓았다가 — 원방향 복귀면 폐기(튐 흡수), 반전 확정(flip)이면 **즉시 쏘지 않고 다음 같은 방향 틱(확정 증거)에 얹어 방출**, 반박(revert)이면 폐기 — 진짜 반전의 **변위 무손실** + 오판 flip의 역방향 점프 소멸. 탐지 지연 비용을 "거리 손실"에서 "반전 순간 저크"로 옮긴다.
- **잠정확정 grace** (v6, `flipGraceMs=200`): 실사용 2240틱 추가 실측의 신사실 — **튐은 제스처 시작 틱에서도 난다**(gapFlip 324회 중 52회 오판 → 유저 진짜 틱 82개가 억제로 씹힘). 처방: gapFlip/flip 직후 200ms 동안 반대 틱을 억제하지 않고 즉시 방향 복귀+통과(`revert`). 방향은 잠정 기간 내 마지막 틱을 따른다. 오판을 없애는 게 아니라(per-tick 분리 불가는 그대로) **오판의 비용**(씹힘·역방향 점프)을 없앤다.

튐 억제 ↔ 반전 지연의 트레이드오프는 causal 필터의 물리적 필연 (Lorden 하한). 근본 소멸은 마우스(엔코더) 교체뿐이다.

## 파일

| 파일 | 내용 |
|------|------|
| `scroll_bounce_filter.lua` | 필터 본체 (init.lua에 붙여넣거나 `dofile`로 로드) |
| `scroll_harness.py` | 결정·버퍼 상태머신 파이썬 포팅 — 시나리오 회귀 9종 (`python3 scroll_harness.py`) |
| `SCROLL_BOUNCE_FIX.md` | v1→v6 도달 경로, 실패 이력 7시도, 측정으로 확정된 사실 |
| `SCROLL_BOUNCE_HANDOFF.md` | 현재 상태 · 재현 레시피 · 결정론 검증 스니펫 |

## 사용

`scroll_bounce_filter.lua` 내용을 `~/.hammerspoon/init.lua`에 추가하고 Hammerspoon reload. 트랙패드(연속 pixel scroll)는 건드리지 않는다.

검증 (합성 이벤트 주입이 이 환경에선 불가하므로 결정 함수 직접 호출):

```bash
osascript -e 'tell application "Hammerspoon" to execute lua code "
scrollDecideReset()
local seq = {-1,-1,-1,-1,-1, 1,1, -1,-1,-1,-1}
local r={}; for _,d in ipairs(seq) do r[#r+1]=scrollDecide(d,1) end
scrollDecideReset(); return table.concat(r,\" \")
"'
# 기대: pass×5 suppress suppress pass×4  (2틱 튐 억제)
```

## 튜닝

- `flipTicks` (4): 올리면 더 긴 튐 억제, 반전 저크 증가. 잔여 4틱 튐이 거슬리면 5.
- `intentionalReverseGapMs` (150): 낮추면 튐 오판 위험↑, 높이면 즉시 반전 혜택↓.
- `flipGraceMs` (200, v6): flip/gapFlip 후 잠정 기간. 실측 오판 반박 틱은 9~62ms에 옴 — 200이면 충분. 올리면 연속 지그재그 조작에서 방향이 더 오래 유동적.
