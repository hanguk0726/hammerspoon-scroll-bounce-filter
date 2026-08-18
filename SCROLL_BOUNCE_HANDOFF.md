# 마우스 스크롤 튐 — 핸드오프 (2026-08-18)

> 이어받는 세션/사람을 위한 문서. "왜/실패이력"은 `SCROLL_BOUNCE_FIX.md`, 여긴 **현재 상태 · 재현 레시피 · 계측 스니펫 · 남은 한계**.

## 한 줄 상태

노치 마우스 휠 "위로 톡" 튐 방지. **현행 = v6**(v5 + 잠정 확정 grace 200ms + flip 버퍼 지연 방출), `init.lua` §[7]. **per-tick 분리는 정보 부재로 불가함이 실측 증명됨** — 근본 소멸은 마우스 교체뿐.

**v6 배경 (2026-08-18, 실사용 트레이스 2240틱)**: 유저 "여전히 하자 많다(반대로 튐·안 먹힘·점프)" → decide-trace 실측으로 v5 설계 구멍 2개 확정:
1. **gapFlip 오판**: 튐이 제스처 **시작** 틱에서도 발생 — gapFlip 324회 중 52회(16%) 오판(스퓨리어스-첫틱형 34 / 진짜반전-후-튐형 8 / 모호 12), 방향이 거꾸로 확정돼 **유저 진짜 틱 82개가 suppress로 씹힘**("안 먹힘"의 진원).
2. **flip 오판 + 몰아방출**: flip 11회 중 7회가 튐 — 그 순간 버퍼 dump가 **역방향 4~5틱 점프**("점프"의 진원).

**v6 처방**: ① gapFlip/flip 직후 `flipGraceMs=200ms` 잠정 기간 — 반대 틱은 억제 없이 즉시 복귀+통과(`revert` 결정, 방향=잠정 기간 내 마지막 틱). ② flip 순간 dump 금지 — `pendingDump`로 보류, 다음 같은 방향 틱(확정 증거)에 얹어 방출, revert면 폐기.

**✅ 검증 완료 (2026-08-18)**: 오라클 5/5 일치 — O1 `pass×5 suppress×2 pass×4`(기존 억제 보존), O2 `pass gapFlip delta=1`, O3 `pass(-1) gapFlip(1) revert(-1) pass(-1)`(씹힘 제거), O4 `suppress×3 flip(out=1) pass(out=4)`(지연 방출 무손실), O5 `flip(out=1) revert(out=-1) pass(out=-1)`(오판 flip 점프 소멸+버퍼 폐기). 클린 프로덕션(`isEnabled=true`, wrapper=nil, stats 리셋). 잔여 = 실사용 체감 판정.

## 파일 지도

| 파일 | 역할 |
|------|------|
| `~/.hammerspoon/init.lua` §[7] (`--- [7] 스크롤 반대로 튐 방지`) | 현행 로직. `scrollDecide(dir[,mag[,gapMs]])` + 배포 함수 `scrollProcessDeltas(...[,nowSeconds])` |
| `~/.hammerspoon/SCROLL_BOUNCE_FIX.md` | v1→v5 이력·정정·근본한계 |
| `~/.hammerspoon/scroll_harness.py` | 방향·gap 시퀀스 + 결정·버퍼 시뮬(재사용) |
| `~/.hammerspoon/SCROLL_BOUNCE_HANDOFF.md` | 이 문서 |

## 현행 로직 (v6) 요약

- 방향 sticky(`committedDir`). 같은 방향 틱 → 통과 + `reverseRun` 리셋.
- 마지막 휠 틱 뒤 **150ms 이상 휴지 후 역방향** → `gapFlip`, 즉시 방향 전환·첫 틱 통과 + **잠정(grace 200ms) 개시**. 이전 보류 버퍼는 폐기.
- **잠정 기간(`graceLeftMs`, gapFlip/flip 직후 200ms — 틱 간 gap만큼 감산)**: 반대 틱이 오면 억제하지 않고 **즉시 방향 복귀+통과**(`revert`). 방향은 잠정 기간 내 마지막 틱을 따른다. → 시작틱 스퓨리어스로 인한 씹힘 제거.
- 역방향 틱(잠정 아님): 연속 `flipTicks(=4)` 모이기 전엔 튐으로 **억제**(delta 0화), 이상이면 진짜 반전(`flip`, 잠정 개시).
- **누적-지연방출**: 억제 틱의 delta(3성분)를 버퍼에 쌓고 — 원방향 복귀(pass)면 폐기(튐 흡수), `flip`이면 **즉시 dump하지 않고 `pendingDump` 보류** → 다음 같은 방향 틱에 얹어 방출(무손실 따라잡기), revert/gapFlip/150ms+ 휴지면 폐기. → 오판 flip의 역방향 점프 소멸.
- 트랙패드(연속 pixel scroll)는 건드리지 않음(`IsContinuous ~= 0` → 통과).

## 튜닝 노브

- `flipTicks`(현 4): 반전 확정에 필요한 연속 역방향 틱. **올리면** 더 긴 튐도 억제하나 진짜 반전 지연↑(무손실이라 저크만 커짐). 잔여 4틱 튐이 거슬리면 5.
- `intentionalReverseGapMs`(현 150): 휴지 반전 즉시 확정 경계. 실측 튐 26~57ms와 의도적 휴지 반전 250ms+ 사이 값. 낮추면 튐 오판 위험↑, 높이면 즉시 반전 혜택↓.
- `flipGraceMs`(현 200, v6): flip/gapFlip 후 잠정 기간. 올리면 오판 복구 창↑이나 진짜 연속 지그재그 조작에서 방향이 더 오래 유동적. 실측 오판 반박 틱은 flip 후 9~62ms에 옴 — 200이면 충분.
- 억제=0화지 삭제(`return true`) 아님 — 이 환경에선 삭제가 무효(실측). setProperty만 먹힘.
- v6 비용(정직): 정확히 flipTicks틱 반전 후 즉시 멈추면 보류분(≤3틱) 유실(지연 방출의 트레이드오프 — 오판 점프 소멸과 맞바꿈).

## ⚠️ 검증 제약 (재현 시 반드시 인지)

**`hs.eventtap.event.newScrollEvent:post()` 로 만든 합성 이벤트는 eventtap에 도달하지 않는다** (프로브 실측: 6 post → 0 관측). 따라서 이벤트 주입식 end-to-end 테스트 **불가**. 두 우회로만 유효:

1. **결정 함수 직접 호출**(결정 로직 오라클, 결정론):
   ```bash
   osascript -e 'tell application "Hammerspoon" to execute lua code "
   scrollDecideReset()
   local seq = {-1,-1,-1,-1,-1, 1,1, -1,-1,-1,-1}   -- down×5, 2틱 up튐, down 재개
   local r={}; for _,d in ipairs(seq) do r[#r+1]=scrollDecide(d,1) end
   scrollDecideReset(); return table.concat(r,\" \")
   "'
   # 기대: pass×5 suppress suppress pass×4  (2틱 튐 억제)
   ```
2. **delta·버퍼 직접 호출**(배포 함수 자체, 결정론):
   ```bash
   osascript -e 'tell application "Hammerspoon" to execute lua code "
   scrollDecideReset()
   local _,_,_,a=scrollProcessDeltas(-1,-10,-11,0.00)
   local d,_,_,b=scrollProcessDeltas(1,10,11,0.25)
   return string.format(\"%s %s delta=%d\",a,b,d)
   "'
   # 기대: pass gapFlip delta=1
   ```
   합성 event post 없이 `nowSeconds`를 주입해 누적-방출·stale 버퍼 폐기까지 검증 가능. 실제 화면 체감만 실 마우스로 최종 판정.

## 재현/진단 레시피 (실 스크롤 트레이스)

튐이 다시 새면 이 순서로 실측한다(추측 패치 금지 — 이 문제는 측정이 전부).

### A. 결정 트레이스 (dir/mag/gap → 판정)
```bash
osascript -e 'tell application "Hammerspoon" to execute lua code "
scrollDecideReset(); scrollStats={passed=0,droppedBounce=0,flips=0,gapFlips=0}
local logf=\"/tmp/hs-decide-trace.log\"; local f=io.open(logf,\"w\"); f:write(\"# t dir mag gap -> dec\\n\"); f:close()
if not _scrollDecideOrig then _scrollDecideOrig=scrollDecide end
function scrollDecide(dir,mag,gapMs)
  local d=_scrollDecideOrig(dir,mag,gapMs)
  local ff=io.open(logf,\"a\"); ff:write(string.format(\"%.4f dir=%+d mag=%d gap=%s -> %s\\n\",hs.timer.secondsSinceEpoch(),dir,mag,tostring(gapMs),d)); ff:close()
  return d
end
return \"armed\""'
# → 유저에게 재현 요청 → 분석: 역방향인데 pass/flip된 run 길이 확인
# → 정리: hs.reload() (래퍼 제거됨)
```

### B. 전속성 raw 트레이스 (미시도 축 확인용)
로거를 디버서보다 **먼저** 등록해야 raw. `scrollDebouncer:stop()` 후 로거 start, 다시 `scrollDebouncer:start()`.
캡처 축: `dA1 fp pt scrollWheelEventScrollPhase MomentumPhase ScrollCount InstantMouser`.
(스니펫은 SCROLL_BOUNCE_FIX.md 검증 섹션 또는 git 히스토리 참조 — 이번 세션 `/tmp/hs-rich-trace.log` 생성 코드.)

### 분석 관점 (파이썬)
- dir 부호에 `+` 있으니 정규식 `dir=([+-]?\d+)`.
- 역방향 run 그룹화 → 각 run 길이 + 통과여부. `flipTicks` 이상 통과 run이 짧으면(되돌아감) 튐 누수.

## 측정으로 확정된 사실 (재도출 금지 — 이미 증명됨)

1. **튐 ↔ 진짜 반전은 per-tick 신호로 분리 불가** [GT]:
   - magnitude·fixedPt·활성-stream 틱 간격 분포 전 구간 겹침. 진짜 저속반전 첫틱 `fp=0.10` = mag-1 튐 첫틱 `fp=0.10` (동일).
   - **노치 마우스 휠은 phase 메타데이터가 없음**: `ScrollPhase/MomentumPhase/ScrollCount/InstantMouser` 50틱 전부 `0`(트랙패드 전용). → 같은 delta의 튐/정상 틱은 **이벤트 수준에서 동일 바이트** → 어떤 함수도 분리 불가(정보 부재, heuristic 부족 아님).
2. **유일 판별자 = 시퀀스(run 길이 + gap)**. run 길이 분포는 연속(1~52틱, 깔끔한 간격 없음). 이 마우스 튐은 **최대 4틱**까지 옴(초기 ≤2 가정 초과).
3. **v2(가속-서명) 접근은 틀렸다** — "튐=magnitude≥2 청크" 전제가 실측 반증됨(저속 시작 튐 `+1,+1,+3` 존재). magnitude 폐기가 정답이었다.
4. **causal 필터의 물리적 트레이드오프**: 지속 확인엔 틱을 흘려야 하고, 흘린 게 튐이면 그게 보이는 튐 → 튐억제 ↔ 반전지연 맞바꿈 불가피. 누적-방출은 이를 "지연"으로만 남기고 "거리손실"은 제거.

## 해결된 실마리와 남은 한계

1. **gap-gating 구현됨(v5)**: 150ms 이상 휴지 반전 지연 제거. 자동 시나리오 5/5 통과. 단, 실제 화면 체감은 실 마우스로 최종 확인 필요.
2. **남은 한계**: 멈칫 없는 즉발 반전은 여전히 버퍼 대상이며, 4틱 이상 지속되는 하드웨어 튐은 진짜 반전과 구분 불가.
3. **하드웨어**: 튐 = 마우스 엔코더 스퓨리어스 역틱(근거: 4ms 간격 역틱 = 사람 불가 속도). **다른 마우스면 원천 소멸.** 소프트웨어는 사후 필터일 뿐.

## 마무리 시 정리 (진단 후 반드시)

```bash
osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"'   # 진단 래퍼/탭 제거 → 클린 프로덕션 복원
rm -f /tmp/hs-*trace*.log /tmp/hs-scroll*.log
# 확인: scrollDebouncer:isEnabled()==true, type(scrollProcessDeltas)=="function", _scrollDecideOrig==nil
```
