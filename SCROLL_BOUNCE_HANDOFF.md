# 마우스 스크롤 튐 — 핸드오프 (2026-08-31)

> 이어받는 세션/사람을 위한 문서. "왜/실패이력"은 `SCROLL_BOUNCE_FIX.md`, 여긴 **현재 상태 · 재현 레시피 · 계측 스니펫 · 남은 한계**.

## 한 줄 상태

노치 마우스 휠 "위로 톡" 튐 방지. **현행 = v10 "정착창 검증 디바운서"**(`init.lua` §[7]) — 방향 상태·질량 모델 전면 폐기, 판별축은 **인접성 하나**(같은 방향=통과 / 역방향 & 직전 통과 틱과 gap≥`guardMs`120ms=즉시 통과 / 인접 역틱만 `holdMs`100ms 정착창 보류→복귀 시 폐기·미복귀 시 무손실 post). v8.1/v9의 지배-질량 모델은 2026-09-01 트레이스로 반증·폐기(사람 입력 55라인 유실 + 9~13라인 덤프 — `SCROLL_BOUNCE_FIX.md` v10 항목). **per-tick 분리는 정보 부재로 불가함이 실측 증명됨** — 근본 소멸은 마우스 교체뿐.

**핵심 실측 (v10의 근거)**: 사람의 진짜 반전은 직전 틱과 205~532ms 떨어져 오고(트레이스 13건 전수), 튐은 4ms 간격·복귀 28~90ms로 항상 인접. 같은 방향 버스트 gap(354~928ms)과 반전 gap이 **겹치므로** 속도/질량류(칼만 velocity-gating, IMM 포함)는 구조적으로 오분류 — 축 자체가 틀렸었다.

**✅ 검증 (2026-09-01)**: 결정론 오라클 5/5 + 유저 트레이스 재생(`v10_replay.py` + `trace-2026-09-01-v9-alternating.log`): 유실 55→18라인, 진짜 반전 13건 전부 지연 0.

**v7→v8 배경 (2026-08-31, 실사용 트레이스 2회)**:
1. v6는 방향 전환 전부를 gapFlip/grace revert로 **즉시 통과**(suppress 0회) — 짧은 버스트+250~600ms 휴지 패턴에선 사실상 무필터 (트레이스1, 68틱).
2. v7(보류 100ms+타이머 post)은 두 신사실로 반증 (트레이스2, 98행):
   - **스퓨리어스가 가속 붙은 역방향 클러스터로도 옴** (예 `+2,+3,+6`=+11) → 카운트·단독 타이머로 진짜 반전과 구분 불가, post돼 11줄 역점프.
   - 방향 상태가 "마지막 확정 1비트"라 오확정 시 **역-잠금**(진짜 틱이 absorb로 씹히고 스퓨리어스가 통과) = "방향 랜덤".
3. v8(하드 윈도우 300ms)은 "창 소진=제스처 끝" 등식이 틀림 — **같은 방향 연속 스크롤도 버스트 간 gap 354~928ms**(트레이스1 실측) → 갈기는 도중 창이 비고 그 틈의 스퓨리어스 1틱이 timerFlip → "갈겨도 반대로" 회귀. → v8.1 지수 감쇠로 교체.

**✅ 검증 (2026-08-31)**: 오라클 5/5 (경계 튐 흡수 / 소진 후 반전+echo / 미드스트림 클러스터 흡수 / **버스트 gap 스퓨리어스 보류 유지**(회귀 케이스) / 무휴지 지속 반전 무손실) + 유저 실사용 "된듯".

## 파일 지도

| 파일 | 역할 |
|------|------|
| `~/.hammerspoon/init.lua` §[7] | 현행 로직 v10. 코어 `scrollProcessDeltas(l,fp,pt[,now])` + `scrollTimerCheck([now])` + `scrollDecideReset()` |
| `~/.hammerspoon/SCROLL_BOUNCE_FIX.md` | v1→v10 이력·정정·근본한계 |
| `~/.hammerspoon/v10_replay.py` + `trace-2026-09-01-v9-alternating.log` | 실사용 트레이스 재생 시뮬 — 튜닝/회귀 검증용 |
| `~/.hammerspoon/scroll_harness.py` | (v6까지의) 방향·gap 시퀀스 시뮬 — v8.1 로직과는 불일치, 참고용 |

## 현행 로직 (v10) 요약

- 상태는 `lastDir`(마지막 통과 틱 방향) + `lastPassAt`뿐. 질량·지배 방향 없음.
- **같은 방향 틱 → 즉시 통과.**
- **역방향 틱, 직전 통과 틱과 gap ≥ guardMs(120) → 즉시 통과** (사람 반전 — 지연 0, `guardPassed` 카운트).
- **역방향 틱, gap < guardMs → 정착창 보류** (delta 0화, 버퍼 적립 + `e:copy()` 보관):
  - holdMs(100) 내 원방향 복귀 → 보류분 폐기(`absorb`, 튐 흡수 — 실측 복귀 28~90ms).
  - 복귀 없이 holdMs 경과 → 타이머가 버퍼를 post(`timerFlips`, 무손실, 지연 ≤100ms). 틱 도착 시점 백스톱(`flips`): 같은 방향이면 합산 방출, 반대면 방출+현재 틱 재보류(`flipHold`).
- **post 재진입 echo 가드**: 직전 post delta와 일치하면 무가공 통과.
- 트랙패드(연속 pixel scroll)는 그대로 통과. 억제는 삭제(return true) 무효 → delta 0화(setProperty).
- **의도된 잔여(버그 아님)**: 직전 틱과 ≥120ms 떨어진 gap-스퓨리어스는 즉시 통과(1~3라인 blip) — "방향 정확성 > 튐 억제" 우선순위의 선택.

## 튜닝 노브

- `guardMs`(120): 이보다 gap이 크면 역방향 즉시 통과. **내리면** 반전 반응↑·인접 튐 통과 위험↑. 실측 마진: 사람 반전 최소 gap 205ms vs 튐 인접 ≤90ms — 120은 그 사이.
- `holdMs`(100): 인접 역틱 정착창. 복귀 실측 28~90ms + 여유. 내리면 인접 빠른 반전 지연↓·튐 흡수 실패 위험↑.

## ⚠️ 검증 제약 (재현 시 반드시 인지)

1. **결정론 오라클 = 코어 직접 호출** (nowSeconds 주입, 실 이벤트 불요):
   ```bash
   osascript -e 'tell application "Hammerspoon" to execute lua code "
   scrollDecideReset()
   local _,_,_,a = scrollProcessDeltas(1,10,11, 0.00)
   local _,_,_,b = scrollProcessDeltas(-1,-10,-11, 0.40)   -- 라이트 스크롤 뒤 역틱
   local _,_,_,c = scrollProcessDeltas(1,10,11, 0.48)      -- 90ms 내 원방향 복귀
   scrollDecideReset(); return a .. \" \" .. b .. \" \" .. c
   "'
   # 기대: pass holdStart absorb  (튐 흡수)
   ```
   타이머 경로는 `scrollTimerCheck(nowSeconds)` 직접 호출로 시뮬 (반환 4번째 값 "flip"/"holding"/"idle").
2. **합성 post는 앱에 도달하고 tap에도 재진입한다** (둘 다 2026-08-31 실측 — 2026-08-18의 "post 무효" 결론은 폐기). end-to-end 주입 테스트도 이제 가능하나, echo 가드가 자기 post를 무시하므로 주입 검증 시 delta를 echo와 다르게 할 것.
3. 실제 체감(반전 지연·튐 잔존)은 실 마우스로만 최종 판정.

## 재현/진단 레시피 (실 스크롤 트레이스)

튐이 다시 새면(추측 패치 금지 — 이 문제는 측정이 전부):

```bash
osascript -e 'tell application "Hammerspoon" to execute lua code "
local logf=\"/tmp/hs-v8-trace.log\"
local f=io.open(logf,\"w\"); f:write(\"# v8 trace\\n\"); f:close()
local function wlog(s) local ff=io.open(logf,\"a\"); ff:write(string.format(\"%.4f %s\\n\", hs.timer.secondsSinceEpoch(), s)); ff:close() end
if not _v8pOrig then _v8pOrig = scrollProcessDeltas end
function scrollProcessDeltas(l,fp,pt,now)
  local oL,oF,oP,d = _v8pOrig(l,fp,pt,now)
  wlog(string.format(\"tick in=%d,%.2f,%d out=%d,%.2f,%d -> %s\", l,fp,pt,oL,oF,oP,d))
  return oL,oF,oP,d
end
if not _v8tOrig then _v8tOrig = scrollTimerCheck end
function scrollTimerCheck(now)
  local a,b,c,st = _v8tOrig(now)
  if st == \"flip\" then wlog(string.format(\"TIMERFLIP out=%d,%.2f,%d\", a,b,c)) end
  return a,b,c,st
end
return \"armed\""'
# → 재현 → 분석 → 정리: hs.reload() + rm -f /tmp/hs-v8-trace.log
```

분석 관점: `-> flip`/`TIMERFLIP` 직후 반대 방향 틱이 바로 오면 오판 flip. `absorbed` 카운터(`scrollStats`)가 흡수량.

## 측정으로 확정된 사실 (재도출 금지 — 이미 증명됨)

1. **튐 ↔ 진짜 반전은 per-tick 신호로 분리 불가** [GT]: magnitude·fp·타이밍 분포 전 구간 겹침. 노치 휠은 phase 메타데이터 없음(전부 0). 같은 delta의 튐/정상 틱 = 이벤트 수준 동일 바이트.
2. **스퓨리어스는 mag-1 단독 틱뿐 아니라 가속 클러스터(합 11까지 관측)로도 온다** [GT 2026-08-31] → 카운트 기반(flipTicks) 판별 폐기.
3. **같은 방향 연속 스크롤의 버스트 간 gap은 354~928ms** [GT] → "N ms 침묵 = 제스처 끝" 하드 컷오프는 성립 안 함(v5 gapFlip·v8 하드윈도우가 이걸로 죽음). 감쇠 질량만 유효.
4. **오판 복귀 틱은 28~90ms 내 도착** [GT] → holdMs=100 보류로 경계 튐 흡수 가능.
5. **newScrollEvent/copy post는 앱 도달 + tap 재진입** [GT 2026-08-31] (2026-08-18 "post 무효"는 반전).
6. **하드웨어**: 튐 = 마우스 엔코더 스퓨리어스(4ms 간격 역틱 = 사람 불가 속도). **다른 마우스면 원천 소멸.**

## 남은 한계 (환원 불가)

1. **제스처 "마지막" 틱이 튐이고 후속 틱이 없으면** 질량 소진 시점(~1s 뒤)에 늦은 역점프 1회 — 단독 의도 반전과 동일 바이트라 정보 부재.
2. (v10) 반전 지연은 인접(<120ms) 반전만 ≤100ms — 그 외 전부 0. 단, 인접 반전 후 100ms 내 원방향 복귀하는 "빠른 왕복 위글"(<220ms)은 튐과 동일 시그니처라 흡수됨(정보 부재).
3. 소프트웨어는 사후 필터일 뿐 — 근본 소멸은 마우스 교체.

## 마무리 시 정리 (진단 후 반드시)

```bash
osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"'   # 진단 래퍼 제거
rm -f /tmp/hs-*trace*.log
# 확인: scrollDebouncer:isEnabled()==true, type(scrollProcessDeltas)=="function", _v8pOrig==nil
```
