--- [7] 스크롤 반대로 튐 방지 (gap-gating + 연속 역방향 카운트 + 누적-방출)
-- 실측(2026-07-30 + 2026-08-14 재조사): "아래로 굴리는데 순간 위로 톡" =
--   한 방향 스트림 속 짧은 역방향 run(스퓨리어스). 진짜 반전은 길게 지속.
-- 판별 로직 v3 (통합 run 카운터, magnitude 무시):
--   v2(가속-서명)는 틀린 전제였다 — 실측(260틱 fp-trace) 결과 튐과 진짜 반전은
--   magnitude·fp·타이밍 어느 축으로도 안 갈린다(분포 전 구간 겹침). 유일하게
--   신뢰할 성질은 run 길이뿐이고 그것도 연속 분포다. 이 마우스 튐은 최대 4틱까지 옴.
--   · 역방향이 연속 flipTicks(=4)개 모이기 전엔 튐으로 보고 억제(delta 0화).
--   · flipTicks개 이상 연속이면 진짜 반전 → 방향 전환 후 통과.
--   · 같은 방향 틱이 오면 run 리셋(→ 짧은 튐 run은 원방향 복귀 시 흡수).
-- v4 (누적-방출): 억제 틱을 0화(손실) 대신 버퍼에 쌓았다가 반전 확정 시 몰아 방출 →
--   진짜 반전 거리 무손실(첫 flipTicks-1틱이 사라지지 않고 확정틱에 따라잡음).
-- v5 (gap-gating): 마지막 휠 틱 뒤 150ms 이상 멈춘 후 시작한 역방향은 의도적 반전으로
--   즉시 확정. 멈칫 없는 반전/튐은 기존 v4로 판정해 튐 억제 정확도를 낮추지 않는다.
--   긴 gap 전의 보류 버퍼는 새 제스처에 섞지 않고 폐기한다.
-- 트레이드오프(정직): flipTicks가 클수록 튐 억제↑, 반전 순간 저크(따라잡는 점프)↑.
--   4 = ≤3틱 튐 억제(대다수), 잔여 = 드문 4틱 튐. 여전히 새면 5로.
-- 억제는 삭제(return true)가 이 환경서 무효 → delta 0화(setProperty). 방향은 sticky.
-- 트랙패드(연속 pixel scroll)는 건드리지 않는다. 상세: ~/.hammerspoon/SCROLL_BOUNCE_FIX.md
local eventtap = hs.eventtap
local event = hs.eventtap.event
local props = event.properties

-- 방향을 뒤집는 데 필요한 "연속 역방향" 틱 수. 근거: 260틱 fp-trace 실측 + scroll_harness.py.
-- 활성 run 내부 간격은 판별에 쓰지 않고, 150ms 이상 휴지만 제스처 경계로 쓴다. magnitude도 안 씀.
local flipTicks = 4
local intentionalReverseGapMs = 150

local committedDir = 0
local reverseRun = 0   -- 연속 역방향 틱 수
local lastWheelAt = nil

-- 누적-방출(v4) 버퍼: 억제한 역방향 틱의 delta를 0화(손실) 대신 여기 쌓는다.
--   · 튐이 원방향으로 되돌아가면(pass) 버퍼 폐기(움직임 0 — 튐 흡수).
--   · 반전 확정(flip)이면 버퍼를 그 틱에 몰아 더해 방출 → 진짜 반전 거리 무손실.
-- 트레이드오프: 손실 대신 반전 순간 "톡 튀며 따라잡는" 저크(최대 flipTicks-1틱 분).
local bufDa1, bufFp, bufPt = 0, 0, 0

-- 진단 카운터(동작 무관): 통과/억제된튐/반전확정. `scrollStats`로 조회.
scrollStats = { passed = 0, droppedBounce = 0, flips = 0, gapFlips = 0 }

local function signDir(v)
    if v > 0 then return 1 elseif v < 0 then return -1 else return 0 end
end

-- 결정 함수 (결정론 테스트 가능).
-- (dir[, mag[, gapMs]]) → "pass" | "flip" | "gapFlip" | "suppress". mag는 미사용(호환).
-- 전역 노출 이유: 이 환경선 newScrollEvent:post()가 eventtap에 도달하지 않아
--   (프로브 실측 6 post→0 관측) 이벤트 주입 검증이 불가하다. 결정은 이 함수,
--   delta/버퍼까지는 scrollProcessDeltas(..., nowSeconds) 직접 호출로 검증한다.
function scrollDecide(dir, mag, gapMs)
    -- 첫 스크롤: 방향 확정.
    if committedDir == 0 then
        committedDir = dir; reverseRun = 0
        return "pass"
    end
    -- 확정 방향과 같음: 통과 + 역방향 run 리셋.
    if dir == committedDir then
        reverseRun = 0
        return "pass"
    end
    -- 충분히 멈춘 뒤 시작한 역방향은 새 의도적 제스처로 보고 첫 틱부터 통과.
    if gapMs ~= nil and gapMs >= intentionalReverseGapMs then
        committedDir = dir; reverseRun = 0
        return "gapFlip"
    end
    -- 역방향: 연속 flipTicks개 모이면 진짜 반전 → 방향 전환 후 통과.
    reverseRun = reverseRun + 1
    if reverseRun >= flipTicks then
        committedDir = dir; reverseRun = 0
        return "flip"
    end
    return "suppress"  -- 미확정 역방향(튐 후보)
end

function scrollDecideReset()
    committedDir = 0; reverseRun = 0
    lastWheelAt = nil
    bufDa1, bufFp, bufPt = 0, 0, 0
end

-- 배포 콜백이 그대로 사용하는 delta 변환 함수. nowSeconds 주입 시 결정론 검증 가능.
-- 반환: lineDelta, fixedPtDelta, pointDelta, decision
function scrollProcessDeltas(lineDelta, fpDelta, ptDelta, nowSeconds)
    local now = nowSeconds or hs.timer.secondsSinceEpoch()
    local gapMs = lastWheelAt and ((now - lastWheelAt) * 1000) or nil
    lastWheelAt = now

    local sv = lineDelta
    if sv == 0 then sv = fpDelta end
    if sv == 0 then sv = ptDelta end
    local dir = signDir(sv)
    if dir == 0 then
        return lineDelta, fpDelta, ptDelta, "pass"
    end
    local mag = lineDelta ~= 0 and (lineDelta < 0 and -lineDelta or lineDelta) or 1
    local decision = scrollDecide(dir, mag, gapMs)

    if decision == "suppress" then
        -- 튐 후보: delta는 보류하고 이번 이벤트는 0화한다.
        bufDa1 = bufDa1 + lineDelta
        bufFp  = bufFp  + fpDelta
        bufPt  = bufPt  + ptDelta
        scrollStats.droppedBounce = scrollStats.droppedBounce + 1
        return 0, 0, 0, decision
    end

    if decision == "flip" then
        -- 밀착 반전 확정: 보류했던 반전 delta까지 함께 방출한다.
        local outDa1, outFp, outPt = lineDelta + bufDa1, fpDelta + bufFp, ptDelta + bufPt
        bufDa1, bufFp, bufPt = 0, 0, 0
        scrollStats.flips = scrollStats.flips + 1
        scrollStats.passed = scrollStats.passed + 1
        return outDa1, outFp, outPt, decision
    end

    -- pass: 보류분은 튐. gapFlip: 보류분은 이전 제스처의 stale delta. 둘 다 폐기한다.
    bufDa1, bufFp, bufPt = 0, 0, 0
    if decision == "gapFlip" then
        scrollStats.flips = scrollStats.flips + 1
        scrollStats.gapFlips = (scrollStats.gapFlips or 0) + 1
    end
    scrollStats.passed = scrollStats.passed + 1
    return lineDelta, fpDelta, ptDelta, decision
end

scrollDebouncer = eventtap.new(
    { event.types.scrollWheel },
    function(e)
        -- 트랙패드 등 연속 pixel scroll은 원본 그대로 통과.
        if e:getProperty(props.scrollWheelEventIsContinuous) ~= 0 then
            return false
        end

        -- delta 3성분 모두 확보(누적-방출에 3성분 다 필요).
        local lineDelta = e:getProperty(props.scrollWheelEventDeltaAxis1)
        local fpDelta   = e:getProperty(props.scrollWheelEventFixedPtDeltaAxis1)
        local ptDelta   = e:getProperty(props.scrollWheelEventPointDeltaAxis1)
        if lineDelta == 0 and fpDelta == 0 and ptDelta == 0 then
            return false  -- 세로 스크롤 성분 없음(가로 등) → 무시
        end

        local outDa1, outFp, outPt, decision = scrollProcessDeltas(lineDelta, fpDelta, ptDelta)
        if decision == "suppress" or decision == "flip" then
            -- 삭제(return true)는 이 환경서 무효이므로 delta를 직접 수정한다.
            e:setProperty(props.scrollWheelEventDeltaAxis1, outDa1)
            e:setProperty(props.scrollWheelEventFixedPtDeltaAxis1, outFp)
            e:setProperty(props.scrollWheelEventPointDeltaAxis1, outPt)
        end
        return false
    end
):start()
