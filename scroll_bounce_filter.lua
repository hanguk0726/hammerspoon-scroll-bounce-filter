--- [7] 스크롤 반대로 튐 방지 — v10 "정착창 검증 디바운서 (settling-window glitch filter)"
-- 이력 v1~v9와 실측 근거는 ~/.hammerspoon/SCROLL_BOUNCE_FIX.md / SCROLL_BOUNCE_HANDOFF.md.
-- v10 배경 (2026-09-01, v9 실사용 트레이스 110행): 빠른 교대 스크롤에서 v8.1/v9의
--   "지배 질량 + 보류" 모델이 사람 입력을 대량 훼손함을 실측 —
--   ① absorb가 보류된 진짜 반전 버스트를 통째 폐기 (16초 재현에서 55라인 유실, 최대 +14)
--   ② flip이 보류분을 한 번에 덤프 (9~13라인 점프 5회).
--   근본 원인: 같은 방향 버스트 gap(354~928ms)과 사람 반전 gap(205~532ms)이 겹쳐,
--   속도/질량 시정수를 어느 쪽에 맞춰도 반대쪽이 오분류됨 (칼만류 velocity-gating의 구조 한계).
-- v10 원리 (엔코더 글리치 필터링 도메인의 표준 기법 — integrating/verifying debouncer):
--   바운스는 기계적 리바운드라 **항상 실 모션에 인접**(4ms 간격, 복귀 28~90ms). 사람 반전은
--   직전 틱과 205~532ms 떨어짐(트레이스 13건 전수). 판별축 = 인접성 하나.
--   · 같은 방향 → 즉시 통과.
--   · 역방향 & 직전 통과 틱과 gap ≥ guardMs(120) → 즉시 통과 (사람 반전 — 지연 0).
--   · 역방향 & gap < guardMs → 정착창 보류(0화, 버퍼). holdMs(100) 내 원방향 복귀 → 폐기(튐).
--     복귀 없이 holdMs 경과 → 타이머가 버퍼를 post (사람 빠른 반전, 지연 ≤100ms, 무손실).
-- 같은 트레이스 재생 실측: 유실 55→18라인(잔여 4건은 측정된 튐 시그니처와 동일 형태),
--   진짜 반전 13건 전부 즉시 통과, 보류 방출 지연 ≤100ms.
-- 정직한 트레이드오프: 직전 틱과 ≥guardMs 떨어져 도착하는 gap-스퓨리어스는 즉시 통과됨
--   (1~3라인 blip). 유저 우선순위 "방향 정확성 > 튐 억제"에 따른 의도된 수용 —
--   이걸 막으려던 질량 기계가 사람 입력을 먹는 비용이 더 컸다(위 실측).
-- 억제는 삭제(return true)가 이 환경서 무효 → delta 0화(setProperty)로.
-- 트랙패드(연속 pixel scroll)는 건드리지 않는다.
local eventtap = hs.eventtap
local event = hs.eventtap.event
local props = event.properties

local guardMs = 120  -- 직전 통과 틱과의 gap이 이 이상이면 역방향도 즉시 통과(사람 반전, 실측 205ms~)
local holdMs  = 100  -- 인접 역틱 정착창 — 이 안에 원방향 복귀 시 튐으로 폐기(실측 복귀 28~90ms)

local lastDir = 0            -- 마지막으로 통과시킨 틱의 방향
local lastPassAt = nil       -- 마지막 통과 시각
local holdDir = 0
local holdStartAt = nil
local holdTicks = 0
local bufDa1, bufFp, bufPt = 0, 0, 0
local holdTimer = nil        -- hs.timer 참조 유지 필수(미보관 시 GC로 미발화)
local heldEventCopy = nil    -- 보류 틱 원본 copy — 타이머 post 시 delta만 바꿔 재사용
local echoL, echoF, echoP, echoUntil = nil, nil, nil, 0

-- 진단: passed/guardPassed(gap 즉시 반전)/held/absorbed(튐 폐기 틱수)/timerFlips(보류 방출)/flips(백스톱 방출)/echoes
scrollStats = { passed = 0, guardPassed = 0, held = 0, absorbed = 0, flips = 0, timerFlips = 0, echoes = 0 }

local function signDir(v)
    if v > 0 then return 1 elseif v < 0 then return -1 else return 0 end
end

local function clearHold()
    holdDir = 0; holdStartAt = nil
    holdTicks = 0
    bufDa1, bufFp, bufPt = 0, 0, 0
end

function scrollDecideReset()
    lastDir = 0; lastPassAt = nil
    clearHold()
    if holdTimer then holdTimer:stop(); holdTimer = nil end
    heldEventCopy = nil
    echoL, echoF, echoP, echoUntil = nil, nil, nil, 0
    scrollStats = { passed = 0, guardPassed = 0, held = 0, absorbed = 0, flips = 0, timerFlips = 0, echoes = 0 }
end

-- 타이머 검사(결정론 코어): 보류 + holdMs 경과(원방향 미복귀) → 보류 버퍼 방출(post 대상).
-- 반환: l,f,p,"flip" | nil,nil,nil,"holding" | nil,nil,nil,"idle"
function scrollTimerCheck(nowSeconds)
    local now = nowSeconds or hs.timer.secondsSinceEpoch()
    if holdDir == 0 then return nil, nil, nil, "idle" end
    if (now - holdStartAt) * 1000 >= holdMs then
        local l, f, p = bufDa1, bufFp, bufPt
        lastDir = holdDir; lastPassAt = now
        clearHold()
        scrollStats.timerFlips = scrollStats.timerFlips + 1
        echoL, echoF, echoP, echoUntil = l, f, p, now + 0.05
        return l, f, p, "flip"
    end
    return nil, nil, nil, "holding"
end

-- delta 변환 코어 (결정론 테스트 — nowSeconds 주입).
-- decision: "pass" | "echo" | "holdStart" | "hold" | "absorb" | "flip"(백스톱 합산 방출) | "flipHold"
function scrollProcessDeltas(lineDelta, fpDelta, ptDelta, nowSeconds)
    local now = nowSeconds or hs.timer.secondsSinceEpoch()

    -- echo 가드: 방금 post한 보류 방출의 재진입 → 무가공 통과
    if now < echoUntil and lineDelta == echoL and fpDelta == echoF and ptDelta == echoP then
        echoL, echoF, echoP, echoUntil = nil, nil, nil, 0
        scrollStats.echoes = scrollStats.echoes + 1
        return lineDelta, fpDelta, ptDelta, "echo"
    end

    local sv = lineDelta
    if sv == 0 then sv = fpDelta end
    if sv == 0 then sv = ptDelta end
    local dir = signDir(sv)
    if dir == 0 then
        return lineDelta, fpDelta, ptDelta, "pass"
    end

    if holdDir ~= 0 then
        if (now - holdStartAt) * 1000 >= holdMs then
            -- 정착창 만기(타이머 레이스 백스톱): 보류 = 사람 반전 확정
            local bl, bf, bp = bufDa1, bufFp, bufPt
            local bDir = holdDir
            clearHold()
            if dir == bDir then
                -- 같은 방향 계속 → 버퍼를 현재 틱에 합쳐 방출(무손실)
                lastDir = dir; lastPassAt = now
                scrollStats.flips = scrollStats.flips + 1
                scrollStats.passed = scrollStats.passed + 1
                return bl + lineDelta, bf + fpDelta, bp + ptDelta, "flip"
            else
                -- 반대 틱 도착: 확정 버퍼를 방출하고 현재 틱을 새로 보류
                lastDir = bDir; lastPassAt = now
                holdDir = dir; holdStartAt = now; holdTicks = 1
                bufDa1, bufFp, bufPt = lineDelta, fpDelta, ptDelta
                scrollStats.flips = scrollStats.flips + 1
                scrollStats.held = scrollStats.held + 1
                return bl, bf, bp, "flipHold"
            end
        end
        if dir ~= holdDir then
            -- 정착창 내 원방향 복귀 → 보류분은 튐: 폐기
            scrollStats.absorbed = scrollStats.absorbed + holdTicks
            clearHold()
            lastDir = dir; lastPassAt = now
            scrollStats.passed = scrollStats.passed + 1
            return lineDelta, fpDelta, ptDelta, "absorb"
        end
        -- 역방향 지속 → 버퍼 적립
        holdTicks = holdTicks + 1
        bufDa1 = bufDa1 + lineDelta
        bufFp  = bufFp  + fpDelta
        bufPt  = bufPt  + ptDelta
        scrollStats.held = scrollStats.held + 1
        return 0, 0, 0, "hold"
    end

    if lastDir == 0 or dir == lastDir then
        lastDir = dir; lastPassAt = now
        scrollStats.passed = scrollStats.passed + 1
        return lineDelta, fpDelta, ptDelta, "pass"
    end

    -- 역방향: 직전 통과 틱과 충분히 떨어져 있으면 사람 반전 — 즉시 통과
    if (now - lastPassAt) * 1000 >= guardMs then
        lastDir = dir; lastPassAt = now
        scrollStats.guardPassed = scrollStats.guardPassed + 1
        scrollStats.passed = scrollStats.passed + 1
        return lineDelta, fpDelta, ptDelta, "pass"
    end

    -- 인접 역틱: 튐 의심 — 정착창 보류
    holdDir = dir; holdStartAt = now; holdTicks = 1
    bufDa1, bufFp, bufPt = lineDelta, fpDelta, ptDelta
    scrollStats.held = scrollStats.held + 1
    return 0, 0, 0, "holdStart"
end

scrollDebouncer = eventtap.new(
    { event.types.scrollWheel },
    function(e)
        -- 트랙패드 등 연속 pixel scroll은 원본 그대로 통과.
        if e:getProperty(props.scrollWheelEventIsContinuous) ~= 0 then
            return false
        end

        local lineDelta = e:getProperty(props.scrollWheelEventDeltaAxis1)
        local fpDelta   = e:getProperty(props.scrollWheelEventFixedPtDeltaAxis1)
        local ptDelta   = e:getProperty(props.scrollWheelEventPointDeltaAxis1)
        if lineDelta == 0 and fpDelta == 0 and ptDelta == 0 then
            return false  -- 세로 스크롤 성분 없음(가로 등) → 무시
        end

        local outDa1, outFp, outPt, decision = scrollProcessDeltas(lineDelta, fpDelta, ptDelta)

        if decision == "holdStart" or decision == "hold" or decision == "flipHold" then
            heldEventCopy = e:copy()
            if decision ~= "hold" then
                if holdTimer then holdTimer:stop() end
                local function timerCheck()
                    holdTimer = nil
                    local fl, ff, fp2, status = scrollTimerCheck()
                    if status == "flip" then
                        if heldEventCopy then
                            heldEventCopy:setProperty(props.scrollWheelEventDeltaAxis1, fl)
                            heldEventCopy:setProperty(props.scrollWheelEventFixedPtDeltaAxis1, ff)
                            heldEventCopy:setProperty(props.scrollWheelEventPointDeltaAxis1, fp2)
                            heldEventCopy:post()
                        end
                        heldEventCopy = nil
                    elseif status == "holding" then
                        -- 타이머가 정착창보다 일찍 발화(드묾) → 재검사
                        holdTimer = hs.timer.doAfter(0.02, timerCheck)
                    else
                        heldEventCopy = nil
                    end
                end
                holdTimer = hs.timer.doAfter(holdMs / 1000, timerCheck)
            end
        elseif decision == "absorb" or decision == "flip" then
            if holdTimer then holdTimer:stop(); holdTimer = nil end
            heldEventCopy = nil
        end

        if outDa1 ~= lineDelta or outFp ~= fpDelta or outPt ~= ptDelta then
            -- 삭제(return true)는 이 환경서 무효이므로 delta를 직접 수정한다.
            e:setProperty(props.scrollWheelEventDeltaAxis1, outDa1)
            e:setProperty(props.scrollWheelEventFixedPtDeltaAxis1, outFp)
            e:setProperty(props.scrollWheelEventPointDeltaAxis1, outPt)
        end
        return false
    end
):start()
