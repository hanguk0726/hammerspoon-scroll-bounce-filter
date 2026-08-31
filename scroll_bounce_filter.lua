--- [7] 스크롤 반대로 튐 방지 — v8 "window 지배 방향 수렴 (dominant-direction window)"
-- 이력 v1~v7과 실측 근거는 ~/.hammerspoon/SCROLL_BOUNCE_FIX.md / SCROLL_BOUNCE_HANDOFF.md.
-- v8 배경 (2026-08-31, v7 실사용 트레이스 98행): 두 신사실이 v7을 반증.
--   ① 스퓨리어스가 mag-1 단독 틱이 아니라 "가속 붙은 역방향 클러스터"(예 +2,+3,+6=+11)로도
--      온다 → 카운트(flipTicks)·단독 타이머 방출로는 진짜 반전과 구분 불가, 그대로 post되어
--      11줄 역점프. ② v7의 방향 상태는 "마지막 확정 1비트"라 한 번 오확정되면 이후 진짜
--      틱이 absorb로 씹히고 스퓨리어스가 통과하는 역-잠금(lock-in)이 생김 = "방향 랜덤".
-- v8 원리(유저 제안): 방향을 1비트가 아니라 **최근 질량(|delta| 합, 지수 감쇠)의 다수결**로.
--   · 지배 방향 틱 → 즉시 통과 + 창에 적립.
--   · 역방향 틱 → 보류(0화, 버퍼 적립). 지배쪽 틱이 다시 오면 보류분 폐기(absorb, 튐 흡수).
--   · 진짜 반전 확정 2경로: (a) 창 소진(휴지·스트림 종료 후 holdMs 경과) → flip,
--     (b) 미드스트림 — 역방향 질량 > massRatio × 창 질량 && 역방향 지속 ≥ spanMs → flip.
--   · flip 시 보류 delta를 원본 이벤트 copy에 실어 post(도달 실측 2026-08-31 확인) 또는
--     현재 틱에 얹어 방출. 오확정이 나도 창 다수결이라 다음 실 틱들이 즉시 되받아
--     자기교정 — lock-in 구조 소멸.
-- 신사실(2026-08-31 실측, 기존 프로브 반전): post한 이벤트는 tap에 **재진입한다**(~3ms).
--   → echo 가드(직전 post delta와 일치 시 무가공 통과)로 이중 적립 차단.
-- 트레이드오프(정직): 진짜 반전 첫 반응이 ~holdMs(휴지 후) 또는 창 소진까지(~windowMs,
--   무휴지 반전) 지연. 잔여 한계: 스트림 "마지막" 틱이 클러스터 튐이고 후속 틱이 없으면
--   창 소진 시점에 늦은 역점프 1회(후속 정보 부재 — 환원 불가).
-- 억제는 삭제(return true)가 이 환경서 무효 → delta 0화(setProperty)로.
-- 트랙패드(연속 pixel scroll)는 건드리지 않는다.
local eventtap = hs.eventtap
local event = hs.eventtap.event
local props = event.properties

-- v8.1 (2026-08-31): 하드 윈도우(300ms 컷오프) → 지수 감쇠 질량. 실측(트레이스1)상
--   같은 방향 연속 스크롤도 버스트 간 gap이 354~928ms라 하드 컷오프 창은 제스처 "도중"에
--   비어버림 → 그 틈의 스퓨리어스 1틱이 timerFlip으로 역방향 post ("갈겨도 반대로" 회귀).
--   감쇠 질량은 활발한 스크롤 뒤 소진까지 ~1.2s 침묵이 필요해 버스트 간 gap에 안 비고,
--   진짜 반전은 문턱(ratio×감쇠질량)이 같이 내려가므로 미드스트림 경로로 확정된다.
local tauMs     = 350   -- 지배 질량 감쇠 시정수. mass·e^(-Δt/τ)
local drainEps  = 1.0   -- 감쇠 질량이 이 밑이면 "소진"(제스처 끝) 판정
local holdMs    = 100   -- 소진 상태의 역방향 보류(경계 튐 흡수, 실측 복귀 28~90ms)
local spanMs    = 150   -- 미드스트림 flip에 요구하는 역방향 지속 시간(클러스터는 ~30ms라 미달)
local massRatio = 2.0   -- 미드스트림 flip: 보류 질량 > ratio × 감쇠 질량

local committedDir = 0
local domMass, domAt = 0, nil   -- 지배 방향 감쇠 질량(역방향은 hold 버퍼에)
local holdDir = 0
local holdStartAt, holdLastAt = nil, nil
local holdTicks, holdMass = 0, 0
local bufDa1, bufFp, bufPt = 0, 0, 0
local holdTimer = nil        -- hs.timer 참조 유지 필수(미보관 시 GC로 미발화)
local heldEventCopy = nil    -- 보류 틱 원본 copy — flip post 시 delta만 바꿔 재사용
local echoL, echoF, echoP, echoUntil = nil, nil, nil, 0

-- 진단: passed/held/absorbed(튐 폐기 틱수)/flips(미드스트림)/timerFlips(창 소진)/echoes
scrollStats = { passed = 0, held = 0, absorbed = 0, flips = 0, timerFlips = 0, echoes = 0 }

local function signDir(v)
    if v > 0 then return 1 elseif v < 0 then return -1 else return 0 end
end

local function domMassAt(now)
    if domAt == nil then return 0 end
    return domMass * math.exp(-(now - domAt) * 1000 / tauMs)
end

local function addDomMass(now, mag)
    domMass = domMassAt(now) + mag
    domAt = now
end

local function clearHold()
    holdDir = 0; holdStartAt = nil; holdLastAt = nil
    holdTicks = 0; holdMass = 0
    bufDa1, bufFp, bufPt = 0, 0, 0
end

-- flip 확정: 보류 방향을 지배로, 지배 질량은 보류 질량으로 재시작. 보류 delta 반환.
local function doFlip(now)
    committedDir = holdDir
    domMass = holdMass; domAt = now
    local l, f, p = bufDa1, bufFp, bufPt
    clearHold()
    return l, f, p
end

function scrollDecideReset()
    committedDir = 0
    domMass = 0; domAt = nil
    clearHold()
    if holdTimer then holdTimer:stop(); holdTimer = nil end
    heldEventCopy = nil
    echoL, echoF, echoP, echoUntil = nil, nil, nil, 0
    scrollStats = { passed = 0, held = 0, absorbed = 0, flips = 0, timerFlips = 0, echoes = 0 }
end

-- 타이머 검사(결정론 코어): 보류 중 + 질량 소진 + holdMs 경과 → flip, 보류 delta 반환.
-- 반환: l,f,p,"flip" (post 대상) | nil,"holding"(재검사 필요) | nil,"idle"
function scrollTimerCheck(nowSeconds)
    local now = nowSeconds or hs.timer.secondsSinceEpoch()
    if holdDir == 0 then return nil, nil, nil, "idle" end
    if domMassAt(now) < drainEps and (now - holdStartAt) * 1000 >= holdMs then
        local l, f, p = doFlip(now)
        scrollStats.timerFlips = scrollStats.timerFlips + 1
        -- 재진입 echo 가드 등록(post는 프로덕션 몫)
        echoL, echoF, echoP, echoUntil = l, f, p, now + 0.05
        return l, f, p, "flip"
    end
    return nil, nil, nil, "holding"
end

-- delta 변환 코어 (결정론 테스트 — nowSeconds 주입).
-- 반환: outLine, outFp, outPt, decision
--   decision: "pass" | "echo" | "holdStart" | "hold" | "absorb" | "flip"
function scrollProcessDeltas(lineDelta, fpDelta, ptDelta, nowSeconds)
    local now = nowSeconds or hs.timer.secondsSinceEpoch()

    -- echo 가드: 방금 post한 flip 이벤트의 재진입 → 무가공 통과(창 이중 적립 금지)
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
    local mag = lineDelta ~= 0 and math.abs(lineDelta) or 1

    -- 첫 스크롤: 방향 확정.
    if committedDir == 0 then
        committedDir = dir
        addDomMass(now, mag)
        scrollStats.passed = scrollStats.passed + 1
        return lineDelta, fpDelta, ptDelta, "pass"
    end

    if dir == committedDir then
        -- 지배 방향: 보류 중이었다면 보류분은 튐 → 폐기(화면 무반응).
        local decision = "pass"
        if holdDir ~= 0 then
            scrollStats.absorbed = scrollStats.absorbed + holdTicks
            clearHold()
            decision = "absorb"
        end
        addDomMass(now, mag)
        scrollStats.passed = scrollStats.passed + 1
        return lineDelta, fpDelta, ptDelta, decision
    end

    -- 역방향: 보류 적립.
    local decision = (holdDir == 0) and "holdStart" or "hold"
    if holdDir == 0 then
        holdDir = dir; holdStartAt = now
    end
    holdLastAt = now
    holdTicks = holdTicks + 1
    holdMass = holdMass + mag
    bufDa1 = bufDa1 + lineDelta
    bufFp  = bufFp  + fpDelta
    bufPt  = bufPt  + ptDelta

    local wm = domMassAt(now)
    -- (a) 질량 소진 + holdMs 경과 (타이머 지연 백스톱: 틱 도착 시점에도 판정)
    if wm < drainEps and (now - holdStartAt) * 1000 >= holdMs then
        local oL, oF, oP = doFlip(now)
        scrollStats.timerFlips = scrollStats.timerFlips + 1
        scrollStats.passed = scrollStats.passed + 1
        return oL, oF, oP, "flip"
    end
    -- (b) 미드스트림: 질량 우세 + 지속 시간
    if wm >= drainEps and holdMass > massRatio * wm and (holdLastAt - holdStartAt) * 1000 >= spanMs then
        local oL, oF, oP = doFlip(now)
        scrollStats.flips = scrollStats.flips + 1
        scrollStats.passed = scrollStats.passed + 1
        return oL, oF, oP, "flip"
    end

    scrollStats.held = scrollStats.held + 1
    return 0, 0, 0, decision
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

        if decision == "holdStart" or decision == "hold" then
            heldEventCopy = e:copy()
            if decision == "holdStart" then
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
                        -- 창이 아직 안 비었음(미드스트림 보류) → 창 소진 때까지 재검사
                        holdTimer = hs.timer.doAfter(0.05, timerCheck)
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
