-- door_ctrl.lua - train door control computer (two independent door inputs)
-- Runs on a dedicated computer next to the doors (one per door section).
-- Intended deployment: one controller near the cab (or commanded remotely by
-- an ATC/LKJ host), so there is a single issuing authority - no arbitration
-- between issuing roles is required.
--
-- Behaviour:
--   * A rising edge (pulse) on SIDE_IN_L toggles the LEFT door; a rising edge
--     on SIDE_IN_R toggles the RIGHT door. Each door state is held
--     continuously on its own output.
--   * The action is broadcast on rednet: every door controller on the consist
--     follows, so one button opens/closes that side on all cars (collective
--     control). Commands without "only" affect both sides.
--   * Door state is broadcast periodically (heartbeat) for monitoring.
--
-- Redstone:
--   input : SIDE_IN_L     left door pulse  (rising edge toggles)
--   input : SIDE_IN_R     right door pulse (rising edge toggles)
--   output: SIDE_OUT_L    left door  (continuous signal while open)
--   output: SIDE_OUT_R    right door (continuous signal while open)
--   modem : SIDE_MODEM    wireless modem (rednet)
--
-- Rednet protocol "loco-door" (reserved for LKJ integration later):
--   cmd   { kind="cmd", action="open"|"close"|"toggle", only="left"|"right"|nil, from=label }
--           -> any controller executes (nil only = both sides)
--   state { kind="state", openL=<bool>, openR=<bool>, label=name, t=clock }
--           -> receivers record only (no forwarding => no loops)
--   Future LKJ: send {kind="cmd", action="open", only="right"}, or add a
--   "lock" action so doors cannot open while the train moves.
--
-- Sides follow the consist orientation (mu_config.lua): "left" means the
-- A-side (left when facing the 1st end / train head). A car with its 2nd end
-- forward swaps left/right, so the same command opens the platform side on
-- every car. The sender is the orientation reference; reversed cars flip.

local SIDE_IN_L    = "right"   -- left door pulse input
local SIDE_IN_R    = "left"    -- right door pulse input
local SIDE_OUT_L   = "front"   -- left door output (continuous while open)
local SIDE_OUT_R   = "back"    -- right door output
local SIDE_MODEM   = "top"     -- wireless modem side
local PROTOCOL     = "loco-door"

local doorL        = false
local doorR        = false
local lastInL      = false
local lastInR      = false
local lastStateTx  = 0

-- Door controllers identify as "<car label>_door" so computer labels stay
-- unique (a cab and its door controller share the mu_config car label). If
-- the label lacks the suffix, append it at runtime: broadcasts then identify
-- this as the door controller of that car.
local rawLabel = os.getComputerLabel() or ("CC#" .. os.getComputerID())
local locoName = rawLabel:match("_door$") and rawLabel or (rawLabel .. "_door")

-- Reuse mu_config.lua for consist orientation (per-car view: others lists
-- every other car with reverse = is that car facing opposite to THIS one).
local mu = {}
local muOK, muCfg = pcall(dofile, "mu_config.lua")
if muOK and type(muCfg) == "table" then
    mu = muCfg
end

-- Look up the sender's consist relation; the sender may be a cab computer
-- (label exactly as in mu_config) or a door controller (car label + "_door").
local function relOf(senderLabel)
    local others = mu.others or {}
    local rel = others[senderLabel]
    if rel then return rel end
    return others[senderLabel:gsub("_door$", "")]
end

-- Open rednet BEFORE broadcastState is defined: a `local` declared later in
-- the chunk would not be in scope inside that function, so the reference
-- would silently become a global (nil) and every state broadcast would be
-- skipped.
local netUp = pcall(rednet.open, SIDE_MODEM)
if not netUp then
    print("WARNING: no modem on side '" .. SIDE_MODEM .. "', rednet disabled")
end

-- Map a door side from the sender's frame to ours. "left"/"right" are the
-- A/B sides relative to the train head; if the sender faces opposite to us
-- (sender's reverse in OUR mu_config), we flip left<->right. nil = both.
local function mapSide(only, senderLabel)
    if only == nil then return nil end
    local rel = relOf(senderLabel)
    if rel and rel.reverse == true then
        return only == "left" and "right" or "left"
    end
    return only
end

local function setOutputs()
    redstone.setOutput(SIDE_OUT_L, doorL)
    redstone.setOutput(SIDE_OUT_R, doorR)
end

local function broadcastState()
    if not netUp then return end
    rednet.broadcast({ kind = "state", openL = doorL, openR = doorR, label = locoName, t = os.clock() }, PROTOCOL)
end

-- Set one or both doors; outputs + broadcast only on actual change.
-- side: "left" | "right" | nil (both)
local function setDoor(side, open)
    if side == "left" then
        if doorL == open then return end
        doorL = open
    elseif side == "right" then
        if doorR == open then return end
        doorR = open
    else
        if doorL == open and doorR == open then return end
        doorL, doorR = open, open
    end
    setOutputs()
    print("Doors L=" .. (doorL and "OPEN" or "CLOSED") .. " R=" .. (doorR and "OPEN" or "CLOSED"))
    broadcastState()
end

-- Initial outputs + banner (rednet is already open above)
setOutputs()
print("Door control started: " .. locoName .. " (L=" .. (doorL and "OPEN" or "CLOSED")
    .. " R=" .. (doorR and "OPEN" or "CLOSED") .. ")")

while true do
    -- 0.05 s timeout paces the loop; the "redstone" event fires on input
    -- change so even a short button pulse is caught as a rising edge.
    local ev, p1, p2, p3 = os.pullEvent(0.05)

    if ev == "redstone" then
        -- left door pulse
        local inL = redstone.getInput(SIDE_IN_L)
        if inL and not lastInL then
            setDoor("left", not doorL)
            if netUp then
                rednet.broadcast({ kind = "cmd", action = doorL and "open" or "close", only = "left", from = locoName }, PROTOCOL)
            end
        end
        lastInL = inL or false

        -- right door pulse
        local inR = redstone.getInput(SIDE_IN_R)
        if inR and not lastInR then
            setDoor("right", not doorR)
            if netUp then
                rednet.broadcast({ kind = "cmd", action = doorR and "open" or "close", only = "right", from = locoName }, PROTOCOL)
            end
        end
        lastInR = inR or false

    elseif ev == "rednet_message" then
        -- p1 = sender id, p2 = message, p3 = protocol
        if p3 == PROTOCOL and type(p2) == "table" and p2.kind == "cmd" then
            -- map the A/B side from the sender's frame to ours (reversed
            -- cars flip left<->right); nil only = both sides
            local side = mapSide(p2.only, p2.from or "")
            if p2.action == "open" then
                setDoor(side, true)
            elseif p2.action == "close" then
                setDoor(side, false)
            elseif p2.action == "toggle" then
                if side == "left" then
                    setDoor("left", not doorL)
                elseif side == "right" then
                    setDoor("right", not doorR)
                else
                    setDoor(nil, not (doorL and doorR))
                end
            end
            -- state messages are recorded implicitly (nothing to do):
            -- receivers do not forward them, so there is no loop
        end
    end

    -- heartbeat: announce our state periodically so monitors/LKJ can see us
    if netUp and os.clock() - lastStateTx >= 0.5 then
        lastStateTx = os.clock()
        broadcastState()
    end
end
