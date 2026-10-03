
-- Vision | Aim / Visuals / Config tabs
--   Aim     -> Aimbot + FOV Circle
--   Visuals -> Corner ESP + Skeleton + Animation Changer (Roblox packs)
--   Config  -> save / load / list configs + Theme manager
-- Requires: Vision library (pastebin yKT5a4Bz / Entirelibrary.lua.txt)
-- Usage:    local Vision = loadstring(game:HttpGet("https://pastebin.com/raw/yKT5a4Bz"))()
--           then run this file.
--
-- NOTE: the Vision library defines its widgets with DOT syntax
--       (group.Toggle, window.Notify, ...). This script uses DOT calls only.
--       Never change them to ":" or every toggle/config silently breaks.
--
-- DESIGN RULES (these are what keep the ESP honest):
--   1. Every frame HIDES all ESP first, then re-draws only what is provably
--      alive. A box can therefore never survive a frame, even if an error
--      happens mid-frame or a corpse is left parented in the world.
--   2. The FOV, ESP and aim passes each run inside their own pcall, so a
--      failure in one can never freeze or block the others.
--   3. Every instance read is pcall-guarded. A destroyed instance makes a
--      check return false instead of throwing.
--   4. Aim is camera-only (CFrame). No mousemoverel, no namecall, no hooks.

-- ── the library ──────────────────────────────────────────────────────
-- Three sources, and a copy's capabilities decide which one runs. The file on
-- disk is the artefact this project ships and the one that gets fixed, so it is
-- asked first; getgenv() is only whatever was executed earlier in this session,
-- and a session copy outlives the file -- that is how a broken build keeps
-- running after the file it came from was repaired. The paste is the last
-- resort for a setup with no readable files at all.
local WANT_BUILD = "2026-10-01-r7"
local function libBuild(v)
    if type(v) == "table" and type(v.Build) == "string" then return v.Build end
    return "pre-r2/unknown"
end
-- Structural check only: a half-loaded or foreign table must not count.
local function libUsable(v)
    return type(v) == "table" and type(v.Window) == "function" and type(v.Flags) == "table"
end
-- Freshness is a capability, not a version string. Vision.Caps is set by the
-- fixed library; a copy that predates the UI fixes does not carry it, whichever
-- build it claims.
local function libFresh(v)
    return libUsable(v) and type(v.Caps) == "table"
        and v.Caps.keyHelpers == true and v.Caps.cursorLock == true
        and v.Caps.cards == true and v.Caps.cardControls == true
        and v.Caps.cardDrag == true
end
local function tryLoad(src)
    if type(src) ~= "string" or #src < 2000 or type(loadstring) ~= "function" then return nil end
    local ok, lib = pcall(function() return loadstring(src)() end)
    if ok and libUsable(lib) then return lib end
    return nil
end
local function libFromDisk()
    if type(readfile) ~= "function" then return nil end
    for _, path in ipairs({
        "Entirelibrary.lua.txt",
        "Vision/Entirelibrary.lua.txt",
        "workspace/Entirelibrary.lua.txt",
        "scripts/Entirelibrary.lua.txt",
    }) do
        local ok, src = pcall(readfile, path)
        if ok then
            local lib = tryLoad(src)
            if lib then return lib end
        end
    end
    return nil
end
local function libFromSession()
    if typeof(getgenv) == "function" then
        local ok, v = pcall(function() return getgenv().Vision end)
        if ok and libUsable(v) then return v end
    end
    local ok, v = pcall(function() return _G.Vision end)
    if ok and libUsable(v) then return v end
    return nil
end
local function libFromPaste()
    local ok, src = pcall(function() return game:HttpGet("https://raw.githubusercontent.com/fireware327/PaidVersion-v1/refs/heads/main/Vision.lua") end)
    if not ok then return nil end
    return tryLoad(src)
end

local Vision
for _, source in ipairs({
    { name = "disk", get = libFromDisk },
    { name = "session", get = libFromSession },
    { name = "paste", get = libFromPaste },
}) do
    local lib = source.get()
    if lib then
        -- A fresh copy wins outright; otherwise the first usable copy is kept
        -- while the remaining sources are still asked, so a stale session copy
        -- can never hide the fixed file on disk.
        if libFresh(lib) or not Vision then
            Vision = lib
        end
        if libFresh(lib) then break end
    end
end
if not Vision then
    error("[Vision] no usable library: disk, session and pastebin all failed")
end

local libStale = not libFresh(Vision)
if libStale then
    warn("[Vision] library copy is " .. libBuild(Vision)
        .. " and does not advertise the UI fixes (expected " .. WANT_BUILD .. "). "
        .. "The menu may keep the mouse locked and the leaderboard card will be missing. "
        .. "Run the updated Entirelibrary -- the copy on disk -- and restart.")
end


-- ═══════════════════════════════════════════════════════════════════
--  SERVICES
-- ═══════════════════════════════════════════════════════════════════
local function svc(name)
    local ok, s = pcall(game.GetService, game, name)
    if not ok or not s then return nil end
    if typeof(cloneref) == "function" then
        local ok2, c = pcall(cloneref, s)
        if ok2 and c then return c end
    end
    return s
end

local Players = svc("Players")
local RunService = svc("RunService")
local UserInputService = svc("UserInputService")
local Workspace = svc("Workspace")

local LP = Players and Players.LocalPlayer
local Camera = Workspace and Workspace.CurrentCamera

if Players then
    pcall(function()
        Players:GetPropertyChangedSignal("LocalPlayer"):Connect(function()
            LP = Players.LocalPlayer
        end)
    end)
end
if Workspace then
    pcall(function()
        Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
            Camera = Workspace.CurrentCamera
        end)
    end)
end

-- ═══════════════════════════════════════════════════════════════════
--  SINGLE-RUN GUARANTEE
--  Every run (any version, any tab) registers a teardown here. Starting a new
--  run wipes ALL previous ones, so loops and drawings can never stack up.
-- ═══════════════════════════════════════════════════════════════════
local G = (typeof(getgenv) == "function" and getgenv()) or _G
local RUNS = G.__VisionRuns
if type(RUNS) ~= "table" then
    RUNS = {}
    G.__VisionRuns = RUNS
end
for i = #RUNS, 1, -1 do
    pcall(RUNS[i])
    RUNS[i] = nil
end

local State = {
    Conn = nil,          -- RenderStepped connection
    Fov = nil,           -- FOV circle drawing
    Lines = {},          -- [Player] = { 8 corner lines }
    Skel = {},           -- [Player] = { 2 x (13 lines + 13 circles) }
    Rigs = {},           -- [Player] = { char, rig, parts, motors }, rebuilt on respawn
    Watch = {},          -- [Player] = { connection list }
    Lock = { Pl = nil, Char = nil, Part = nil },
    AimHeld = false,
    Friends = {},        -- [Player] = { value, at, fails, pending }: friend cache
    FriendStop = false,  -- set by teardown to end the friend resolver loop
    FriendWarned = false,-- the friend lookup has already been reported once
    Anim = {},           -- [ANIMATION CHANGER] originals, respawn wiring, restore
}

local function hasDrawing()
    return typeof(Drawing) == "table" and typeof(Drawing.new) == "function"
end

local function teardown()
    pcall(function() if State.Conn then State.Conn:Disconnect() end end)
    State.Conn = nil
    pcall(function() if State.Fov then State.Fov:Remove() end end)
    State.Fov = nil
    for _, arr in pairs(State.Lines) do
        for _, l in ipairs(arr) do pcall(function() l:Remove() end) end
    end
    State.Lines = {}
    for _, arr in pairs(State.Skel) do
        for _, l in ipairs(arr) do pcall(function() l:Remove() end) end
    end
    State.Skel = {}
    State.Rigs = {}
    for _, conns in pairs(State.Watch) do
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    end
    State.Watch = {}
    State.Lock.Pl, State.Lock.Char, State.Lock.Part = nil, nil, nil
    State.AimHeld = false
    State.FriendStop = true
    State.Friends = {}
    -- Put the character's own animations back before this run's code is gone:
    -- a swap must never outlive the script that made it.
    if State.Anim.restore then pcall(State.Anim.restore) end
end

local thisRun = function() teardown() end
RUNS[#RUNS + 1] = thisRun
G.__VisionMain = State

-- ═══════════════════════════════════════════════════════════════════
--  ANIMATION CHANGER
--  The default animations are not properties of the Humanoid. Every character
--  ships an "Animate" LocalScript that reads the AnimationIds off its own
--  children once, hands the tracks to the Animator, and never looks again --
--  which is why writing an AnimationId on its own changes nothing at all. The
--  write below is therefore always paired with a restart of that script, and
--  the change is visible on the next frame instead of on the next step.
--
--  Only the local player's own character is touched; an animation swap is local
--  by nature and no other client needs to see it.
--
--  The UI offers slot names, not folder paths. Each slot maps to the one or two
--  objects the official script uses, and a slot this rig does not have -- R6
--  against R15, a game with a custom rig -- is skipped rather than treated as
--  an error. Every object is read before it is written, so switching the toggle
--  off, or starting a new run of this script, puts the character back exactly
--  as it was found.
--
--  This is defined before the UI because the widgets call into it: a `local
--  function` written after a callback that uses it resolves to a nil global,
--  and the failure only shows up when a user clicks the button.
-- ═══════════════════════════════════════════════════════════════════
-- Declared here and built under UI below. The engine reaches it through the two
-- callbacks under this comment, and a `local` that does not exist yet would
-- bind those callbacks to a nil global instead -- a failure that only shows up
-- when somebody clicks.
local Window
local animNotify = function() end
local animApplyFlags = function() end

local ANIM_SLOTS = {
    { name = "Idle",  flag = "anim_id_idle",  paths = { { "idle", "Animation1" }, { "idle", "Animation2" } } },
    { name = "Walk",  flag = "anim_id_walk",  paths = { { "walk", "WalkAnim" } } },
    { name = "Run",   flag = "anim_id_run",   paths = { { "run", "RunAnim" } } },
    { name = "Climb", flag = "anim_id_climb", paths = { { "climb", "ClimbAnim" } } },
    { name = "Jump",  flag = "anim_id_jump",  paths = { { "jump", "JumpAnim" } } },
    { name = "Fall",  flag = "anim_id_fall",  paths = { { "fall", "FallAnim" } } },
    { name = "Swim",  flag = "anim_id_swim",  paths = { { "swim", "Swim" }, { "swimidle", "SwimIdle" } } },
}
local ANIM_SLOT_NAMES = {}
for _, slot in ipairs(ANIM_SLOTS) do
    ANIM_SLOT_NAMES[#ANIM_SLOT_NAMES + 1] = slot.name
end

-- ───────────────────────────────────────────────────────────────────
--  ROBLOX ANIMATION PACKS
--  The official animation bundles Roblox itself ships, in the same shape the
--  Animation Changer already writes: one ID per slot. Picking a pack fills
--  every slot at once, so "Ninja" or "Zombie" is one click instead of seven
--  pasted IDs. The manual ID box stays for anything not in this table.
--
--  These are the packs' own asset IDs, which is what makes them work on any
--  rig: a game's own animations are already replaced by them, and the same
--  slot-skip rules apply (an R6 rig has no separate elbow/knee but every one
--  of these seven slots still exists on both rigs).
--
--  "Default" is not a pack: it clears all seven slots and restores whatever
--  the game shipped, which is the only sane way to undo a preset.
-- ───────────────────────────────────────────────────────────────────
local ANIM_PACKS = {
    { name = "Default",     ids = nil },
    { name = "Ninja",       ids = { Idle = 658832408, Walk = 658831143, Run = 658830056, Jump = 658832070, Fall = 658831500, Climb = 658833139, Swim = 658832807 } },
    { name = "Zombie",      ids = { Idle = 619535834, Walk = 619537468, Run = 619536621, Jump = 619536283, Fall = 619535616, Climb = 619535091, Swim = 619537096 } },
    { name = "Robot",       ids = { Idle = 619521748, Walk = 619522849, Run = 619522386, Jump = 619522088, Fall = 619521521, Climb = 619521311, Swim = 619522642 } },
    { name = "Mage",        ids = { Idle = 754637456, Walk = 754636298, Run = 754635032, Jump = 754637084, Fall = 754636589, Climb = 754639239, Swim = 754638471 } },
    { name = "Pirate",      ids = { Idle = 837024662, Walk = 837023892, Run = 837023444, Jump = 837024350, Fall = 837024147, Climb = 837025325, Swim = 837025054 } },
    { name = "Knight",      ids = { Idle = 734327140, Walk = 734326330, Run = 734325948, Jump = 734326930, Fall = 734326679, Climb = 734329002, Swim = 734327363 } },
    { name = "Superhero",   ids = { Idle = 619528125, Walk = 619529601, Run = 619528716, Jump = 619528412, Fall = 619527817, Climb = 619527470, Swim = 619529095 } },
    { name = "Astronaut",   ids = { Idle = 1090133099, Walk = 1090131576, Run = 1090130630, Jump = 1090132507, Fall = 1090132063, Climb = 1090134016, Swim = 1090133583 } },
    { name = "Werewolf",    ids = { Idle = 1113752682, Walk = 1113751657, Run = 1113750642, Jump = 1113752285, Fall = 1113751889, Climb = 1113754738, Swim = 1113752975 } },
    { name = "Vampire",     ids = { Idle = 1113742618, Walk = 1113741192, Run = 1113740510, Jump = 1113742359, Fall = 1113742092, Climb = 1113743239, Swim = 1113742944 } },
    { name = "Elder",       ids = { Idle = 892268340, Walk = 892267099, Run = 892265784, Jump = 892267917, Fall = 892267521, Climb = 892269341, Swim = 892268710 } },
    { name = "Toy",         ids = { Idle = 973771666, Walk = 973767371, Run = 973766674, Jump = 973770652, Fall = 973768058, Climb = 973773170, Swim = 973772659 } },
    { name = "Cartoony",    ids = { Idle = 837011741, Walk = 837010234, Run = 837009922, Jump = 837011171, Fall = 837010685, Climb = 837013990, Swim = 837012509 } },
    { name = "Levitation",  ids = { Idle = 619542203, Walk = 619544080, Run = 619543231, Jump = 619542888, Fall = 619541867, Climb = 619541458, Swim = 619543721 } },
    { name = "Stylish",     ids = { Idle = 619511648, Walk = 619512767, Run = 619512153, Jump = 619511974, Fall = 619511417, Climb = 619509955, Swim = 619512450 } },
    { name = "Bubbly",      ids = { Idle = 1018553897, Walk = 1018549681, Run = 1018548665, Jump = 1018553240, Fall = 1018552770, Climb = 1018554668, Swim = 1018554245 } },
}
local ANIM_PACK_NAMES = {}
local ANIM_PACK_BY_NAME = {}
for _, pack in ipairs(ANIM_PACKS) do
    ANIM_PACK_NAMES[#ANIM_PACK_NAMES + 1] = pack.name
    ANIM_PACK_BY_NAME[pack.name] = pack
end

local function animChar()
    if not LP then return nil end
    local ok, c = pcall(function() return LP.Character end)
    if ok then return c end
    return nil
end

local function animSlotFor(name)
    for _, slot in ipairs(ANIM_SLOTS) do
        if slot.name == name then return slot end
    end
    return nil
end

-- "rbxassetid://123", a full asset URL and a bare 123 all name the same asset;
-- anything else is not an ID. Empty text returns nil as well -- "no change
-- wanted" and "not an ID" are different answers, and the caller tells them
-- apart by looking at the text itself.
local function animNormalize(text)
    if type(text) ~= "string" then return nil end
    local s = text:gsub("%s+", "")
    if s == "" then return nil end
    local digits = s:match("^rbxassetid://(%d+)$")
        or s:match("^%d+$")
        or s:match("[?&]id=(%d+)")     -- .../asset/?id=123
        or s:match("/library/(%d+)")   -- .../library/123/Name
    if not digits or #digits > 20 then return nil end
    return "rbxassetid://" .. digits
end

-- The Animation object a slot path names, or nil when this rig does not have
-- it. Every hop is guarded: a missing or destroyed child is "not here", never
-- an error.
local function animObject(scr, path)
    local node = scr
    for _, name in ipairs(path) do
        if not node then return nil end
        local ok, child = pcall(function() return node:FindFirstChild(name) end)
        if not ok or not child then return nil end
        node = child
    end
    if not node then return nil end
    local ok, isAnim = pcall(function() return node:IsA("Animation") end)
    if ok and isAnim then return node end
    return nil
end

-- The character's own Animate script, or nil for a rig that has none -- a game
-- with custom character scripts. That is the one situation the feature cannot
-- work in, and the one it stands down for.
local function animScript(char)
    if not char then return nil end
    local ok, s = pcall(function() return char:FindFirstChild("Animate") end)
    if not ok or not s then return nil end
    local ok2, isLua = pcall(function() return s:IsA("LuaSourceContainer") end)
    if ok2 and isLua then return s end
    return nil
end

-- originals[char][Animation] = the AnimationId found there before the first
-- write. Captured once per object: a second apply must never record its own
-- previous value as the original, or switching off would restore the change.
local function animOriginalsFor(char)
    local all = State.Anim.originals
    if type(all) ~= "table" then
        all = {}
        State.Anim.originals = all
    end
    local set = all[char]
    if type(set) ~= "table" then
        set = {}
        all[char] = set
    end
    return set
end

local function animCapture(set, obj)
    if set[obj] ~= nil then return end
    local ok, id = pcall(function() return obj.AnimationId end)
    if ok and type(id) == "string" and id ~= "" then set[obj] = id end
end

-- The slot -> text map, read straight off the flags so a config load or the
-- dropdown switch needs no second source of truth.
local function animLiveIds()
    local live = {}
    for _, slot in ipairs(ANIM_SLOTS) do
        live[slot.name] = Vision.Flags[slot.flag]
    end
    return live
end

-- Animate read every ID once, at start, and holds the tracks from then on; the
-- write above is invisible until it reads them again. Disabling and re-enabling
-- the script is what forces that read, and it is what makes the change instant
-- instead of next-movement. Guarded, so a game that protects the property keeps
-- its old animation rather than taking the whole apply down with it.
-- The tracks the old script already handed the Animator keep playing until
-- they are stopped, and a leftover idle track blended under the new one is
-- exactly what "the change did nothing" looks like. Stopped first, so the
-- re-run below starts from silence.
local function animStopTracks(char)
    if not char then return end
    local animator = nil
    pcall(function()
        local hum = char:FindFirstChildOfClass("Humanoid")
        animator = hum and hum:FindFirstChildOfClass("Animator")
    end)
    if not animator then return end
    local ok, tracks = pcall(function() return animator:GetPlayingAnimationTracks() end)
    if not ok or type(tracks) ~= "table" then return end
    for _, track in ipairs(tracks) do
        pcall(function() track:Stop(0) end)
    end
end

-- The re-enable is deferred rather than awaited: this runs from teardown too,
-- and teardown must never yield -- the next run is loading behind it. 0.1s is
-- the interval the community fix settled on; it is long enough for the engine
-- to act on the property change and short enough to read as instant.
local function animRestart(scr)
    if not scr then return end
    if not pcall(function() scr.Disabled = true end) then return end
    task.delay(0.1, function()
        pcall(function() scr.Disabled = false end)
    end)
end

-- Write one slot. Returns objects written, objects this rig does not have, and
-- objects the write was refused on. An empty box is none of the three: it means
-- "leave this slot alone", and the caller says so by looking at the text.
local function animWriteSlot(char, scr, slot, text)
    local id = animNormalize(text)
    if not id then return 0, 0, 0 end
    local set = animOriginalsFor(char)
    local written, found, failed = 0, 0, 0
    for _, path in ipairs(slot.paths) do
        local obj = animObject(scr, path)
        if obj then
            found = found + 1
            animCapture(set, obj)
            if pcall(function() obj.AnimationId = id end) then
                written = written + 1
            else
                failed = failed + 1
            end
        end
    end
    return written, (found == 0 and 1 or 0), failed
end

-- Put one slot back the way it was found, for a cleared box. Only that slot's
-- objects are touched; the rest of the character is left alone.
local function animRestoreSlot(char, scr, slot)
    if not char or not scr then return 0 end
    local set = animOriginalsFor(char)
    local n = 0
    for _, path in ipairs(slot.paths) do
        local obj = animObject(scr, path)
        local id = obj and set[obj]
        if type(id) == "string" and id ~= "" then
            if pcall(function() obj.AnimationId = id end) then n = n + 1 end
        end
    end
    return n
end

local function animWriteAll(char, live)
    local scr = animScript(char)
    if not scr then return 0, 0, 0 end
    local written, missing, failed = 0, 0, 0
    for _, slot in ipairs(ANIM_SLOTS) do
        local w, m, f = animWriteSlot(char, scr, slot, live[slot.name])
        written, missing, failed = written + w, missing + m, failed + f
    end
    return written, missing, failed
end

-- Put every captured original back. It walks every character that was touched,
-- not only the live one, so a change made before a respawn is undone too.
local function animRestoreAll()
    local all = State.Anim.originals
    State.Anim.originals = {}
    if type(all) ~= "table" then return 0 end
    local n = 0
    for _, set in pairs(all) do
        for obj, id in pairs(set) do
            if type(id) == "string" and id ~= "" then
                if pcall(function() obj.AnimationId = id end) then
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- Restore, then restart the live character's Animate so the originals come back
-- at once rather than at the next state change.
local function animUndo()
    local char = animChar()
    local n = animRestoreAll()
    if n > 0 then
        animStopTracks(char)
        animRestart(animScript(char))
    end
    return n
end

-- No Animate script means the feature cannot do anything on this rig, so it is
-- switched off and the reason is shown -- through the library's own ApplyFlags,
-- so the checkbox follows, exactly as the Friend Toggle does when its lookup is
-- unavailable. A toggle that silently does nothing is the one outcome worth
-- engineering against.
local function animStandDown(reason)
    if not Vision.Flags.anim_enabled then return end
    animApplyFlags({ anim_enabled = false })
    Vision.Flags.anim_enabled = false
    pcall(function() Vision._scheduleSave() end)
    State.Anim.enabled = false
    animRestoreAll()
    if State.Anim.warned then return end
    State.Anim.warned = true
    pcall(function()
        warn("[Vision] " .. tostring(reason) .. "; Animation Changer switched off")
    end)
    animNotify({
        title = "Animation",
        text = tostring(reason) .. ". The Animation Changer was switched off.",
        type = "warn",
        duration = 8,
    })
end

-- Every saved ID, onto one character. Returns written, missing, failed.
local function animApplyTo(char)
    if not char then return 0, 0, 0 end
    local scr = animScript(char)
    if not scr then return 0, 0, 0 end
    local written, missing, failed = animWriteAll(char, animLiveIds())
    if written > 0 then
        animStopTracks(char)
        animRestart(scr)
    end
    return written, missing, failed
end

-- One slot, now: what the Apply button does. Returns written, missing, failed.
local function animApplyOne(slotName)
    local char = animChar()
    local scr = animScript(char)
    local slot = animSlotFor(slotName)
    if not char or not scr or not slot then return 0, 0, 0 end
    local written, missing, failed = animWriteSlot(char, scr, slot, Vision.Flags[slot.flag])
    if written > 0 then
        animStopTracks(char)
        animRestart(scr)
    end
    return written, missing, failed
end

-- Clearing a slot is its own operation: the saved text is dropped, and the
-- game's own animation is written back so the character stops using the swap
-- immediately instead of waiting for the next respawn.
local function animClearOne(slotName)
    local char = animChar()
    local scr = animScript(char)
    local slot = animSlotFor(slotName)
    if not char or not scr or not slot then return 0 end
    local n = animRestoreSlot(char, scr, slot)
    if n > 0 then
        animStopTracks(char)
        animRestart(scr)
    end
    return n
end

-- One pack, every slot at once: the preset counterpart of the Apply button. It
-- writes the same slot flags, so a preset and a hand-pasted ID are
-- indistinguishable to the rest of the changer -- and the Animate tree is still
-- only ever touched by animApplyTo / animRestoreAll, never from here.
--
-- "Default" is the undo rather than a pack: every slot flag is cleared and the
-- character's own animations are put back, so a preset never leaves the game
-- changed. Returns written, missing, failed -- the same triple Apply reports.
local function animApplyPreset(name)
    local pack = ANIM_PACK_BY_NAME[name]
    if not pack then return 0, 0, 0 end

    if not pack.ids then
        for _, slot in ipairs(ANIM_SLOTS) do
            Vision.Flags[slot.flag] = ""
        end
        pcall(function() Vision._scheduleSave() end)
        local n = animUndo()
        return n, 0, 0
    end

    for _, slot in ipairs(ANIM_SLOTS) do
        local id = pack.ids[slot.name]
        Vision.Flags[slot.flag] = id and ("rbxassetid://" .. tostring(id)) or ""
    end
    pcall(function() Vision._scheduleSave() end)

    -- A preset only reaches a body while the changer is on; with it off the
    -- flags are saved and applied the moment the toggle is switched on. Not a
    -- failure, so the UI reports it as "saved, not yet applied" rather than as
    -- an error.
    if not State.Anim.enabled then return 0, 0, 0 end
    return animApplyTo(animChar())
end

-- The Animate script is a child of the character and normally arrives with
-- it, but it can land a tick later -- and "you toggled one frame too early" is
-- not the same thing as "this game has custom characters". Waiting briefly is
-- what tells the two apart, so only the real dead end stands down.
local function animWaitScript(char)
    if not char then return nil end
    for _ = 1, 10 do
        local scr = animScript(char)
        if scr then return scr end
        pcall(task.wait, 0.1)
        char = animChar()
        if not char then return nil end
    end
    return nil
end

-- The one place the toggle's effect lives, so a click and a config load take
-- the identical path. `on` is what the widget reports, never assumed.
local function animSetEnabled(on)
    on = on and true or false
    State.Anim.enabled = on
    if not on then
        animUndo()
        return
    end
    -- A respawn builds a brand-new Animate tree, so the IDs have to be written
    -- onto that one too. One connection, made once, gated by the enabled flag.
    -- Made before the first apply so a character that has not spawned yet is
    -- still caught when it does.
    if LP and not State.Anim.conn then
        pcall(function()
            State.Anim.conn = LP.CharacterAdded:Connect(function()
                -- The model arrives a tick before its children do; writing
                -- before the Animate script exists would be dropped on the
                -- floor. Waiting for it also means a game with no Animate
                -- script at all is simply skipped here, quietly: the toggle
                -- itself already reported that case.
                pcall(task.wait)
                if not State.Anim.enabled then return end
                local fresh = animChar()
                if animWaitScript(fresh) then animApplyTo(animChar()) end
            end)
        end)
    end
    local char = animChar()
    -- Between lives there is nothing to write to and nothing wrong: the
    -- respawn wiring above applies it the moment the character arrives. Only a
    -- character that exists and has no Animate script is a real dead end.
    if not char then return end
    if not animScript(char) then
        if not animWaitScript(char) then
            -- It may have been a respawn rather than a missing script, and a
            -- toggle switched off during the wait must not be acted on.
            if State.Anim.enabled and animChar() then
                animStandDown("This character has no Animate script")
            end
            return
        end
        if not State.Anim.enabled then return end
    end
    animApplyTo(animChar())
end

-- What teardown runs: put the character back, then drop the connection so a
-- later respawn cannot re-apply a change this run already undid.
local function animShutdown()
    State.Anim.enabled = false
    if State.Anim.conn then
        pcall(function() State.Anim.conn:Disconnect() end)
        State.Anim.conn = nil
    end
    -- The character may have been replaced while a wait was in flight, so the
    -- body actually carrying the swap is the one to restart -- the originals
    -- are restored onto whichever bodies are still alive either way.
    animUndo()
end
State.Anim.restore = animShutdown

-- ═══════════════════════════════════════════════════════════════════
--  UI
-- ═══════════════════════════════════════════════════════════════════
local Window = Vision.Window({
    title = "VISION",
    keybind = Enum.KeyCode.Insert,
    footerText = "Vision v" .. tostring(Vision.Version),
})

-- Hand the engine the two library calls it needs now that the window is real.
animNotify = function(o) pcall(function() Window.Notify(o) end) end
animApplyFlags = function(d) pcall(function() Window.ApplyFlags(d) end) end

-- ═══════════════════════════════════════════════════════════════════
--  LEADERBOARD CARD
--  A second frame of the same UI, docked to the window's left edge and half
--  its size. It reads each player's own leaderstats -- whatever the game
--  publishes -- ranks them by the column in use, and keeps itself current while
--  the menu is open. Rows show rank, avatar, name and one cell per stat, with
--  the local player's own line under the header.
--  It comes back with the menu every time, populated: the frame is a child of
--  the window, so the window's own visibility is the only switch. Faded,
--  themed, and hidden with the window; nothing about it moves the main UI.
--  It is dragged by its own header -- three dots at its left -- and only the
--  card moves. Dropped near either edge of the window it snaps back onto that
--  edge; dropped anywhere else it stays where it was put.
--  Options: stats = { "Time", "Kills" } picks and orders the columns,
--  sortBy / sortDescending choose the ordering, side = "right" docks it on the
--  other edge, width / height resize it, maxColumns raises the column count,
--  and debug = true prints exactly what the card read to the console.
--  Its own functions: Refresh(), SetSort(column, descending), SetStats(list),
--  SetTitle(text), SetVisible(bool), Dock("left"/"right"), MoveTo(x, y),
--  Destroy(), and the Gui frame itself.
--  Clicking a column header also orders the table by that stat, and the hint
--  under the header says what the current order is.
-- ═══════════════════════════════════════════════════════════════════
local Leaderboard = nil
if type(Window.Card) == "function" then
    Leaderboard = Window.Card({ title = "Leaderboard" })
else
    warn("[Vision] library copy has no Card(); the leaderboard panel is skipped.")
end

-- Three pages, one subject each: the aimbot and its FOV circle, everything
-- that draws on screen (box, skeleton, animations), and everything that is
-- saved (configs, theme). Groups keep their left/right column choice, so each
-- page reads as a two-column layout rather than one long list.
local AimTab = Window.Tab("Aim")
local VisualsTab = Window.Tab("Visuals")
local ConfigTab = Window.Tab("Config")

-- Aim
local AimGroup = AimTab.Group("Aimbot", { side = "left" })
local FovGroup = AimTab.Group("FOV", { side = "right" })

-- Visuals
local EspGroup = VisualsTab.Group("ESP", { side = "left" })
local SkelGroup = VisualsTab.Group("Skeleton", { side = "right" })
local AnimGroup = VisualsTab.Group("Animations", { side = "left" })

-- Config
local CfgGroup = ConfigTab.Group("Configs", { side = "left" })
local ThemeGroup = ConfigTab.Group("Theme", { side = "right" })

-- The console warning can be missed behind the menu, so say it in the UI too:
-- a stale library has no other symptom than "the update did nothing".
if libStale then
    pcall(function()
        Window.Notify({
            title = "Vision",
            text = "Stale library: this copy does not have the UI fixes. "
                .. "Labels and notifications will clip, the widget keys will fail, "
                .. "and the leaderboard card will be missing or docked to the "
                .. "wrong side with dead column headers. "
                .. "Run the updated Entirelibrary (build " .. WANT_BUILD .. ").",
            type = "error",
            duration = 10,
        })
    end)
end

local Lock = State.Lock
local function clearLock()
    Lock.Pl, Lock.Char, Lock.Part = nil, nil, nil
end

-- ═══════════════════════════════════════════════════════════════════
--  CONTROLS
-- ═══════════════════════════════════════════════════════════════════
AimGroup.Toggle({ text = "Aimbot Enabled", flag = "aim_enabled", default = false })
AimGroup.Label({ text = "Hold the key to lock onto the closest target in FOV." })

local AimKey = AimGroup.Keybind({
    text = "Aim Key",
    flag = "aim_key",
    default = Enum.UserInputType.MouseButton2, -- RMB
    mode = "Hold",                             -- hold action
    callback = function(down)
        State.AimHeld = (down == true)
        if not State.AimHeld then clearLock() end
    end,
    changed = function()
        State.AimHeld = false
        clearLock()
    end,
})

AimGroup.Dropdown({
    text = "Hit Part",
    flag = "aim_part",
    options = { "Head", "HumanoidRootPart", "UpperTorso", "Closest Part" },
    default = "Head",
})

AimGroup.Slider({ text = "Smoothing", flag = "aim_smooth", min = 1, max = 20, default = 8, step = 1, suffix = "" })
AimGroup.Slider({ text = "Prediction", flag = "aim_predict", min = 0, max = 30, default = 0, step = 1, suffix = "%" })
AimGroup.Toggle({ text = "Team Check", flag = "aim_team", default = true })
-- Friends count as allies by default: never targeted, never drawn by the ESP.
AimGroup.Toggle({ text = "Friend Toggle", flag = "friend_toggle", default = true })
AimGroup.Label({ text = "Friends count as allies: never targeted, and hidden from the ESP." })
AimGroup.Toggle({ text = "Wall Check", flag = "aim_wall", default = true })
AimGroup.Toggle({ text = "Use FOV", flag = "aim_usefov", default = true })

FovGroup.Toggle({ text = "Show FOV", flag = "aim_showfov", default = false })
FovGroup.Slider({ text = "FOV Size", flag = "aim_fov", min = 20, max = 400, default = 120, step = 1, suffix = "px" })
FovGroup.Slider({ text = "Thickness", flag = "aim_fov_thick", min = 1, max = 5, default = 1, step = 1, suffix = "px" })
FovGroup.Color({ text = "FOV Color", flag = "aim_fov_color", default = Color3.fromRGB(255, 255, 255) })

EspGroup.Toggle({ text = "Corner ESP", flag = "esp_corner", default = false })
EspGroup.Toggle({ text = "Team Check", flag = "esp_team", default = true })
EspGroup.Slider({ text = "Max Distance", flag = "esp_dist", min = 100, max = 2000, default = 800, step = 10, suffix = "st" })
EspGroup.Color({ text = "ESP Color", flag = "esp_color", default = Color3.fromRGB(255, 255, 255) })
EspGroup.Color({ text = "Visible Color", flag = "esp_vis_color", default = Color3.fromRGB(120, 255, 140) })
EspGroup.Slider({ text = "Line Thickness", flag = "esp_thick", min = 1, max = 6, default = 2, step = 1, suffix = "px" })
EspGroup.Toggle({ text = "Visible Check", flag = "esp_vischeck", default = false })
EspGroup.Toggle({
    text = "Require Humanoid",
    flag = "esp_requirehum",
    default = true,
})

SkelGroup.Toggle({ text = "Skeleton ESP", flag = "skel_esp", default = false })
SkelGroup.Label({ text = "Neck down. R6 draws its real hinges, R15 every joint." })
SkelGroup.Slider({ text = "Thickness", flag = "skel_thick", min = 1, max = 8, default = 3, step = 1, suffix = "px" })
SkelGroup.Toggle({ text = "Joint Dots", flag = "skel_joints", default = true })
SkelGroup.Toggle({ text = "Outline", flag = "skel_outline", default = true })
SkelGroup.Color({ text = "Skeleton Color", flag = "skel_color", default = Color3.fromRGB(255, 255, 255) })

-- Configs
local CfgList = nil
local CfgNameBox = CfgGroup.Textbox({ text = "Name", flag = "cfg_name", default = "default", placeholder = "config name" })

CfgGroup.Button({ text = "Save Config", callback = function()
    local name = tostring(Vision.Flags.cfg_name or "default")
    if Window.SaveConfig(name) then
        Window.Notify({ title = "Config", text = "Saved: " .. name, type = "success", duration = 3 })
        if CfgList then pcall(function() CfgList.Refresh(Window.ListConfigs()) end) end
    else
        Window.Notify({ title = "Config", text = "Save failed.", type = "error", duration = 3 })
    end
end })

CfgGroup.Button({ text = "Load Config", callback = function()
    local name = tostring(Vision.Flags.cfg_selected or Vision.Flags.cfg_name or "default")
    if Window.LoadConfig(name) then
        Window.Notify({ title = "Config", text = "Loaded: " .. name, type = "success", duration = 3 })
    else
        Window.Notify({ title = "Config", text = "Load failed: " .. name, type = "error", duration = 3 })
    end
end })

CfgList = CfgGroup.Dropdown({
    text = "Config List",
    flag = "cfg_selected",
    options = Window.ListConfigs(),
    default = nil,
    callback = function(v)
        if type(v) == "string" and v ~= "" and CfgNameBox then
            CfgNameBox.Set(v)
        end
    end,
})

CfgGroup.Button({ text = "Refresh List", callback = function()
    if CfgList then pcall(function() CfgList.Refresh(Window.ListConfigs()) end) end
end })

-- ───────────────────────────────────────────────────────────────────
--  THEME MANAGER
--  The library owns the palettes and the repaint, so this is only the picker:
--  SetTheme() swaps the whole palette in place and stores the choice under the
--  "theme" flag, which means the theme travels with a saved config and comes
--  back on AutoLoad -- applyLoadedTable re-runs SetTheme itself, so a loaded
--  config repaints without this callback being involved.
--
--  Every call is guarded on the function existing: the library gained the
--  theme API at some point, and a copy without it must leave the Config tab
--  usable rather than error on construction.
-- ───────────────────────────────────────────────────────────────────
local ThemeNames = {}
if type(Window.ListThemes) == "function" then
    local ok, names = pcall(Window.ListThemes)
    if ok and type(names) == "table" then ThemeNames = names end
end
local CurrentTheme = "Dark"
if type(Window.GetTheme) == "function" then
    local ok, name = pcall(Window.GetTheme)
    if ok and type(name) == "string" then CurrentTheme = name end
end

if #ThemeNames == 0 then
    ThemeGroup.Label({ text = "This library copy has no theme API; the theme picker is unavailable." })
else
    ThemeGroup.Dropdown({
        text = "Theme",
        flag = "theme",
        options = ThemeNames,
        default = CurrentTheme,
        callback = function(v)
            if type(v) ~= "string" or type(Window.SetTheme) ~= "function" then return end
            if not Window.SetTheme(v) then return end
            Window.Notify({
                title = "Theme",
                text = "Theme set to " .. v .. ".",
                type = "success",
                duration = 3,
            })
        end,
    })
    ThemeGroup.Label({ text = "The theme is saved with your config and restored on load." })
end

-- ───────────────────────────────────────────────────────────────────
--  ANIMATIONS
--  Pick a slot, paste an ID, Apply. Each slot remembers its own ID, so
--  switching slots only ever refills the box -- nothing is written until Apply
--  is pressed, and an empty box leaves that slot exactly as it is.
--  The toggle applies every saved ID at once, re-applies them after a respawn,
--  and puts the character's own animations back when it is switched off.
-- ───────────────────────────────────────────────────────────────────
local AnimIdBox = nil

local function animRefillBox()
    if not AnimIdBox then return end
    local slot = animSlotFor(Vision.Flags.anim_slot)
    local saved = slot and Vision.Flags[slot.flag] or ""
    if type(saved) ~= "string" then saved = "" end
    pcall(function() AnimIdBox.Set(saved) end)
end

-- A whole pack in one click. The callback is the only place that reports the
-- result, so a preset applied while the changer is off says exactly that
-- instead of claiming a change that has not happened yet.
AnimGroup.Dropdown({
    text = "Preset",
    flag = "anim_preset",
    options = ANIM_PACK_NAMES,
    default = "Default",
    callback = function(name)
        local pack = ANIM_PACK_BY_NAME[name]
        if not pack then return end
        local written, missing, failed = animApplyPreset(name)
        animRefillBox()
        if not pack.ids then
            Window.Notify({
                title = "Animation",
                text = "Preset cleared: the game's own animations play.",
                type = "info",
                duration = 4,
            })
        elseif not State.Anim.enabled then
            Window.Notify({
                title = "Animation",
                text = name .. " saved. Switch the Animation Changer on to apply it.",
                type = "info",
                duration = 5,
            })
        elseif not (LP and LP.Character) then
            -- Enabled, but between lives: the respawn wiring applies the pack
            -- the moment a body exists, so this is a wait and not a failure.
            Window.Notify({
                title = "Animation",
                text = name .. " saved. It applies as soon as you respawn.",
                type = "info",
                duration = 5,
            })
        elseif written > 0 then
            Window.Notify({
                title = "Animation",
                text = name .. " applied to " .. tostring(written) .. " animation slot(s).",
                type = "success",
                duration = 4,
            })
        elseif missing > 0 then
            Window.Notify({
                title = "Animation",
                text = "This rig has no slot for " .. tostring(missing) .. " of the " .. name .. " animations.",
                type = "warn",
                duration = 5,
            })
        elseif failed > 0 then
            Window.Notify({
                title = "Animation",
                text = "The game refused " .. tostring(failed) .. " of the " .. name .. " animation writes.",
                type = "error",
                duration = 6,
            })
        else
            Window.Notify({
                title = "Animation",
                text = "Could not apply " .. name .. ": this character has no Animate script.",
                type = "error",
                duration = 6,
            })
        end
    end,
})

AnimGroup.Dropdown({
    text = "Slot",
    flag = "anim_slot",
    options = ANIM_SLOT_NAMES,
    default = "Idle",
    callback = function() animRefillBox() end,
})

AnimIdBox = AnimGroup.Textbox({
    text = "Animation ID",
    flag = "anim_id",
    default = "",
    placeholder = "rbxassetid://...",
})

-- One slot, now. This is also the only way to set the first ID, because the
-- toggle applies the flags and nothing else -- the box is a scratchpad until
-- Apply commits it to the slot.
AnimGroup.Button({ text = "Apply", callback = function()
    local slot = animSlotFor(Vision.Flags.anim_slot)
    if not slot then return end
    local raw = tostring(Vision.Flags.anim_id or "")
    local id = animNormalize(raw)
    if not id then
        if raw:gsub("%s+", "") == "" then
            Vision.Flags[slot.flag] = ""
            pcall(function() Vision._scheduleSave() end)
            animClearOne(slot.name)
            Window.Notify({
                title = "Animation",
                text = slot.name .. " cleared: the game's own animation plays.",
                type = "info",
                duration = 4,
            })
        else
            Window.Notify({
                title = "Animation",
                text = "\"" .. raw .. "\" is not an animation ID. Paste the number, "
                    .. "a rbxassetid:// link or a full asset URL.",
                type = "error",
                duration = 6,
            })
        end
        return
    end
    Vision.Flags[slot.flag] = id
    pcall(function() Vision._scheduleSave() end)
    pcall(function() AnimIdBox.Set(id) end)
    local written, missing, failed = animApplyOne(slot.name)
    if written > 0 then
        Window.Notify({
            title = "Animation",
            text = slot.name .. " set to " .. id .. ".",
            type = "success",
            duration = 4,
        })
    elseif missing > 0 then
        Window.Notify({
            title = "Animation",
            text = "This rig has no " .. slot.name .. " animation to replace.",
            type = "warn",
            duration = 5,
        })
    elseif failed > 0 then
        Window.Notify({
            title = "Animation",
            text = "The game refused the " .. slot.name .. " animation write.",
            type = "error",
            duration = 6,
        })
    else
        Window.Notify({
            title = "Animation",
            text = "Could not set " .. slot.name .. ": this character has no Animate script.",
            type = "error",
            duration = 6,
        })
    end
end })

AnimGroup.Toggle({
    text = "Animation Changer",
    flag = "anim_enabled",
    default = false,
    callback = function(on)
        animSetEnabled(on)
        -- The toggle was asked for but cannot be delivered, so it was switched
        -- back off: refill the box for the slot that is still selected.
        if not Vision.Flags.anim_enabled then animRefillBox() end
    end,
})

AnimGroup.Label({ text = "Pick a Preset to set every slot at once, or choose a Slot and paste an ID for one. Switching the changer off restores the game's own animations." })

-- The saved flags are the source of truth, and this runs after the widgets are
-- bound, so a restored or hand-edited config shows the right slot and ID -- and
-- the changer is actually in effect, not merely shown as on.
task.defer(function()
    animRefillBox()
    if Vision.Flags.anim_enabled == true then animSetEnabled(true) end
end)

-- ═══════════════════════════════════════════════════════════════════
--  VALIDITY  (never throws; a destroyed instance simply returns false)
-- ═══════════════════════════════════════════════════════════════════
local function myChar()
    if not LP then return nil end
    return LP.Character
end

local function requireHum()
    return Vision.Flags.esp_requirehum ~= false
end

-- A character is usable only if the model is real, still in the world,
-- its humanoid is a real descendant with health above 0, and it is not
-- in the Dead state. Corpse models that stay parented are rejected here.
-- `memo` is an opt-in per-frame cache. The frame passes build one and hand it
-- down, which turns the repeated pcall + FindFirstChildOfClass + GetState chain
-- into a single lookup per character per frame. It is never used by the
-- lifetime watchers: those must keep reading live state, not last frame's.
local function validChar(char, memo)
    if memo and char ~= nil then
        local hit = memo[char]
        if hit ~= nil then return hit end
    end
    local ok, res = pcall(function()
        if typeof(char) ~= "Instance" then return false end
        if char:IsA("Model") == false then return false end
        if char.Parent == nil then return false end
        if Workspace and not char:IsDescendantOf(Workspace) then return false end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            if not hum:IsDescendantOf(char) then return false end
            if hum.Parent == nil then return false end
            if hum.Health <= 0 then return false end
            local st = hum:GetState()
            if st == Enum.HumanoidStateType.Dead then return false end
        elseif requireHum() then
            return false
        end
        return true
    end)
    res = (ok and res) and true or false
    -- Guarded against a nil key: `memo[nil] = x` would throw.
    if memo and char ~= nil then memo[char] = res end
    return res
end

-- The part must still belong to that exact living character, which kills
-- stale references pointing at a corpse that was already removed.
local function validPart(char, part, memo)
    local ok, res = pcall(function()
        if not validChar(char, memo) then return false end
        if typeof(part) ~= "Instance" then return false end
        if not part:IsA("BasePart") then return false end
        if part.Parent == nil then return false end
        if not part:IsDescendantOf(char) then return false end
        return true
    end)
    return (ok and res) and true or false
end

local function teamBlocked(checkOn, plr)
    if not checkOn then return false end
    if not LP or plr == LP then return true end
    local ok, res = pcall(function()
        return LP.Team ~= nil and plr.Team ~= nil and LP.Team == plr.Team
    end)
    return (ok and res) and true or false
end

-- ───────────────────────────────────────────────────────────────────
--  FRIENDS
--  IsFriendsWith is a web call: it takes time and it can fail, so it is never
--  called from a pass. The passes read the cache below -- one table lookup --
--  and the calls happen here, on their own task, once per player per FRIEND_TTL,
--  and only while the Friend Toggle is on.
--
--  A player whose answer has not arrived yet counts as NOT a friend. The other
--  way round -- unknown means ally -- would quietly stop the aimbot from
--  targeting anyone the moment the lookup is unavailable, which is a much worse
--  failure than a second of friend being targetable. Availability is handled out
--  loud instead: after FRIEND_FAIL_MAX consecutive failures the toggle switches
--  itself off, through the library's own ApplyFlags so the checkbox follows, and
--  the reason is shown. A toggle that silently does nothing is the one outcome
--  worth engineering against.
-- ───────────────────────────────────────────────────────────────────
local FRIEND_TTL = 10       -- seconds a resolved answer is trusted
local FRIEND_RETRY = 3      -- seconds before a failed lookup is retried
local FRIEND_FAIL_MAX = 3   -- consecutive failures before the toggle stands down

-- True when this player must be treated as an ally. That is only ever a friend
-- of the local player, and only while the toggle is on; everything else -- an
-- unanswered lookup included -- is an ordinary player.
local function friendBlocked(plr)
    if not Vision.Flags.friend_toggle then return false end
    if not plr then return true end
    if plr == LP then return true end
    local rec = State.Friends[plr]
    return rec ~= nil and rec.value == true
end

-- The lookup is unavailable, so the feature cannot do its job. Stand it down and
-- say so rather than leaving a toggle that lies about what is in effect.
local function friendStandDown()
    if not Vision.Flags.friend_toggle then return end
    pcall(function()
        Window.ApplyFlags({ friend_toggle = false })
    end)
    Vision.Flags.friend_toggle = false
    pcall(function() Vision._scheduleSave() end)
    if State.FriendWarned then return end
    State.FriendWarned = true
    pcall(function()
        warn("[Vision] friend lookup is unavailable in this executor; Friend Toggle switched off")
    end)
    pcall(function()
        Window.Notify({
            title = "Vision",
            text = "Friend lookup unavailable here, so Friend Toggle was switched off.",
            type = "warn",
            duration = 8,
        })
    end)
end

-- One lookup per player at a time, off the render path. The record doubles as
-- the in-flight guard, so a slow call can never be started twice.
local function friendLookup(plr)
    local rec = State.Friends[plr]
    if rec and rec.pending then return end
    rec = rec or {}
    rec.pending = true
    State.Friends[plr] = rec
    task.spawn(function()
        local id = nil
        pcall(function() id = tonumber(plr.UserId) end)
        local value, answered = nil, false
        if id and LP then
            local ok, res = pcall(function() return LP:IsFriendsWith(id) end)
            if ok then
                value = (res and true) or false
                answered = true
            end
        end
        -- The player may have left mid-call: the pruner drops the record, and a
        -- record that is gone must stay gone.
        local live = State.Friends[plr]
        if live == nil then return end
        live.pending = false
        live.at = os.clock()
        if answered then
            live.value = value
            live.fails = 0
            return
        end
        live.fails = (live.fails or 0) + 1
        if live.fails >= FRIEND_FAIL_MAX then friendStandDown() end
    end)
end

-- Keep the cache warm while the toggle is on, and do nothing at all while it is
-- off: no web call is made for a feature that is not in effect. Records for
-- players who left are dropped, so the cache tracks the server rather than
-- growing with it.
task.spawn(function()
    while not State.FriendStop do
        local on = Vision.Flags.friend_toggle and LP ~= nil and Players ~= nil
        if on then
            local now = os.clock()
            local live = {}
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LP then
                    live[plr] = true
                    local rec = State.Friends[plr]
                    local due = false
                    if rec == nil then
                        due = true
                    elseif not rec.pending then
                        local age = now - (rec.at or 0)
                        due = (rec.value == nil and age >= FRIEND_RETRY)
                            or (rec.value ~= nil and age >= FRIEND_TTL)
                    end
                    if due then friendLookup(plr) end
                end
            end
            for plr in pairs(State.Friends) do
                if not live[plr] then State.Friends[plr] = nil end
            end
        end
        task.wait(on and 0.5 or 1)
    end
end)

local function partFor(char, mode, center)
    if not validChar(char) then return nil end
    local ok, head, hrp, torso = pcall(function()
        local h = char:FindFirstChild("Head")
        local r = char:FindFirstChild("HumanoidRootPart")
        local t = char:FindFirstChild("UpperTorso") or r
        return h, r, t
    end)
    if not ok then return nil end
    if mode == "Head" then
        return validPart(char, head) and head or nil
    end
    if mode == "HumanoidRootPart" then
        return validPart(char, hrp) and hrp or nil
    end
    if mode == "UpperTorso" then
        return validPart(char, torso) and torso or nil
    end
    -- Closest Part: head / torso / hrp nearest to the crosshair
    local best, bestD = nil, math.huge
    if Camera and center then
        for _, p in ipairs({ head, torso, hrp }) do
            if validPart(char, p) then
                local got, sp, on = pcall(function()
                    return Camera:WorldToViewportPoint(p.Position)
                end)
                if got and on then
                    local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                    if d < bestD then best, bestD = p, d end
                end
            end
        end
    end
    return best
end

-- ═══════════════════════════════════════════════════════════════════
--  RAYCASTS / INPUT
-- ═══════════════════════════════════════════════════════════════════
local RayParams = nil
pcall(function()
    RayParams = RaycastParams.new()
    RayParams.FilterType = Enum.RaycastFilterType.Exclude
    RayParams.IgnoreWater = true
end)

local function wallBlocked(targetChar, fromPos, toPos)
    if Vision.Flags.aim_wall ~= true then return false end
    if not RayParams then return false end
    local ok, res = pcall(function()
        RayParams.FilterDescendantsInstances = { myChar(), Camera }
        return Workspace:Raycast(fromPos, toPos - fromPos, RayParams)
    end)
    if not ok or res == nil then return false end -- fail open, never break aim
    if res.Instance and targetChar and res.Instance:IsDescendantOf(targetChar) then
        return false
    end
    return true
end

-- `atPos` is a world position rather than a part, so a caller can aim at a box
-- center instead of a limb. Reuses the one shared RaycastParams: allocating a
-- fresh one per player per frame was pure garbage. Failures still count as
-- "visible" -- a blocked ray must never be what turns a target green, and a
-- broken one must never take the pass down.
local function visibleNow(targetChar, atPos)
    if not targetChar or typeof(atPos) ~= "Vector3" then return false end
    if not validChar(targetChar) then return false end
    if not RayParams or not Camera then return true end
    local ok, res = pcall(function()
        RayParams.FilterDescendantsInstances = { myChar(), Camera }
        return Workspace:Raycast(Camera.CFrame.Position, atPos - Camera.CFrame.Position, RayParams)
    end)
    if not ok or res == nil then return true end
    if res.Instance and res.Instance:IsDescendantOf(targetChar) then
        return true
    end
    return false
end

local function keyHeldNow(key)
    if not key or not UserInputService then return State.AimHeld end
    local okMouse, isMouse = pcall(function() return key.EnumType == Enum.UserInputType end)
    if okMouse and isMouse then
        if key == Enum.UserInputType.MouseButton1 then
            local ok, v = pcall(UserInputService.IsMouseButtonPressed, UserInputService, Enum.UserInputType.MouseButton1)
            return (ok and v) and true or false
        elseif key == Enum.UserInputType.MouseButton2 then
            local ok, v = pcall(UserInputService.IsMouseButtonPressed, UserInputService, Enum.UserInputType.MouseButton2)
            return (ok and v) and true or false
        elseif key == Enum.UserInputType.MouseButton3 then
            local ok, v = pcall(UserInputService.IsMouseButtonPressed, UserInputService, Enum.UserInputType.MouseButton3)
            return (ok and v) and true or false
        end
        return State.AimHeld
    end
    local ok, held = pcall(UserInputService.IsKeyDown, UserInputService, key)
    if ok then return (held and true) or false end
    return State.AimHeld
end

-- Only ever returns a provably living, in-FOV, unobstructed target.
local function getTarget(center)
    if not Camera or not Players then return nil, nil, nil end
    local fov = tonumber(Vision.Flags.aim_fov) or 120
    local useFov = Vision.Flags.aim_usefov ~= false
    local mode = tostring(Vision.Flags.aim_part or "Head")
    local bestPl, bestChar, bestPart = nil, nil, nil
    local bestD = useFov and fov or math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            local done = pcall(function()
                if teamBlocked(Vision.Flags.aim_team, plr) then return end
                if friendBlocked(plr) then return end
                local char = plr.Character
                if not validChar(char) then return end
                local part = partFor(char, mode, center)
                if not validPart(char, part) then return end
                local ok, sp, on = pcall(function()
                    return Camera:WorldToViewportPoint(part.Position)
                end)
                if not ok or not on then return end
                local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                if d > bestD then return end
                if wallBlocked(char, Camera.CFrame.Position, part.Position) then return end
                bestPl, bestChar, bestPart, bestD = plr, char, part, d
            end)
            if not done then continue end
        end
    end
    -- Final gate: the winner may have died during the scan.
    if not validPart(bestChar, bestPart) then return nil, nil, nil end
    return bestPl, bestChar, bestPart
end

-- ═══════════════════════════════════════════════════════════════════
--  DRAWINGS
-- ═══════════════════════════════════════════════════════════════════
-- Transparency in the Drawing API is INVERTED from Roblox's: 1 is fully
-- visible, 0 is invisible. Leaving it at the executor's default is exactly how
-- an ESP ends up drawing nothing at all while every line of it looks correct,
-- so every drawing this script owns has it set explicitly, and the colour pass
-- is re-stated every frame.
local DRAW_OPAQUE = 1

if hasDrawing() then
    pcall(function()
        local c = Drawing.new("Circle")
        c.Filled = false
        c.NumSides = 64
        c.Transparency = DRAW_OPAQUE
        c.Visible = false
        State.Fov = c
    end)
else
    -- Say so once, loudly. An ESP-less window that renders nothing and reports
    -- nothing is the worst outcome there is: everything looks fine.
    pcall(function()
        Window.Notify({
            title = "Vision",
            text = "No Drawing API in this executor: ESP and FOV cannot render.",
            type = "error",
            duration = 8,
        })
    end)
end

-- ───────────────────────────────────────────────────────────────────
--  CORNER ESP
--  Sixteen pooled lines per player: eight black underneath, eight coloured on
--  top. Drawing paints in creation order and the black pass is exactly 2px
--  wider, so every coloured stroke keeps 1px of border down each side -- which
--  is the whole reason the box stays readable over a bright sky, a dark wall or
--  busy detail instead of dissolving into whatever is behind it.
--
--  The order of operations in a frame is fixed, and every step of it matters:
--    1. hide every pooled line      -> nothing can survive a frame, ever
--    2. union the body's world AABB -> a steady silhouette that cannot squish
--    3. project its eight corners   -> the tight 2D box actually on screen
--    4. cull what is off-screen, pin what is not to the viewport edge
--    5. snap the box to whole px    -> crisp 1px borders, no shimmer
--    6. emit four brackets through both passes from one set of endpoints
-- ───────────────────────────────────────────────────────────────────
local ESP_PAD = 0.2       -- studs of slack, so a bracket clears the limbs
local ESP_LINE_T = 2      -- px, default coloured stroke (the Line Thickness slider)
local ESP_OUTLINE_T = 1   -- px of black added PER SIDE
local ESP_MIN_BOX = 2     -- px, below this the target is a dot, not a box
local ESP_MIN_LEG = 3     -- px, shortest a bracket leg may be drawn
local ESP_MAX_LEG = 24    -- px, longest a bracket leg may be drawn
local ESP_EDGE = 64       -- px past the viewport a box may reach before culling
local ESP_BLACK = Color3.new(0, 0, 0)

-- Slots are padded with `false`, never left nil, so the 1..8 / 9..16 split
-- survives a line that failed to create and ipairs never stops early.
local function espLinesFor(plr)
    local arr = State.Lines[plr]
    if arr then return arr end
    arr = {}
    if hasDrawing() then
        for i = 1, 16 do
            local ok, l = pcall(Drawing.new, "Line")
            if ok and l then
                l.Transparency = DRAW_OPAQUE
                l.Visible = false
                l.From = Vector2.new(0, 0)
                l.To = Vector2.new(0, 0)
                if i <= 8 then
                    -- Backing pass: wider than the colour it sits under, and
                    -- solid black, so the border is a real border rather than a
                    -- hint. Only its width is retuned per frame, by espSegment.
                    l.Thickness = ESP_LINE_T + ESP_OUTLINE_T * 2
                    l.Color = ESP_BLACK
                else
                    l.Thickness = ESP_LINE_T
                end
                arr[i] = l
            else
                arr[i] = false
            end
        end
    end
    State.Lines[plr] = arr
    return arr
end

local function hideLines(arr)
    if not arr then return end
    for _, l in ipairs(arr) do
        if l then pcall(function() l.Visible = false end) end
    end
end

-- One bracket leg through both passes at once: arr[i] is the black backing,
-- arr[i + 8] the coloured stroke. Both get the SAME two endpoints, so the
-- border is exactly ESP_OUTLINE_T per side at every thickness setting instead
-- of only at the default one.
local function espSegment(arr, i, from, to, color, thick, outlineT)
    local back = arr[i]
    if back then
        back.Thickness = outlineT
        back.From = from
        back.To = to
        back.Visible = true
    end
    local line = arr[i + 8]
    if line then
        line.Thickness = thick
        line.From = from
        line.To = to
        line.Color = color
        line.Visible = true
    end
end

-- Four brackets anchored on the four corners of the box: one horizontal and
-- one vertical leg each, so eight strokes come out of four points and two
-- offsets. Leg length is a quarter of the shorter side, floored so a distant
-- box still reads as corners rather than as a smudge, and capped both
-- absolutely and at 45% of the short side so two brackets sharing an edge can
-- never grow into each other and turn the box into a rectangle.
local function drawCorners(arr, x, y, w, h, color, thick)
    thick = thick or ESP_LINE_T
    local short = math.min(w, h)
    local floor = thick + ESP_OUTLINE_T
    if floor < ESP_MIN_LEG then floor = ESP_MIN_LEG end
    local len = math.clamp(short * 0.25, floor, ESP_MAX_LEG)
    local cap = short * 0.45
    if len > cap then len = cap end
    if len < 1 then len = 1 end

    local x2, y2 = x + w, y + h
    local ot = thick + ESP_OUTLINE_T * 2
    local tl = Vector2.new(x, y)
    local tr = Vector2.new(x2, y)
    local bl = Vector2.new(x, y2)
    local br = Vector2.new(x2, y2)
    local ox, oy = Vector2.new(len, 0), Vector2.new(0, len)
    espSegment(arr, 1, tl, tl + ox, color, thick, ot) -- top-left    horizontal
    espSegment(arr, 2, tl, tl + oy, color, thick, ot) -- top-left    vertical
    espSegment(arr, 3, tr - ox, tr, color, thick, ot) -- top-right   horizontal
    espSegment(arr, 4, tr, tr + oy, color, thick, ot) -- top-right   vertical
    espSegment(arr, 5, bl - oy, bl, color, thick, ot) -- bottom-left vertical
    espSegment(arr, 6, bl, bl + ox, color, thick, ot) -- bottom-left horizontal
    espSegment(arr, 7, br - oy, br, color, thick, ot) -- bottom-right vertical
    espSegment(arr, 8, br - ox, br, color, thick, ot) -- bottom-right horizontal
end

-- ═══════════════════════════════════════════════════════════════════
--  LIFETIME WATCHERS
--  Any death/removal signal hides the box and drops the aim lock the same
--  instant, so the ESP can never lag a frame behind reality.
-- ═══════════════════════════════════════════════════════════════════
local function clearWatch(plr)
    local conns = State.Watch[plr]
    if conns then
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    end
    State.Watch[plr] = nil
end

local function onCharacterGone(plr, char)
    hideLines(State.Lines[plr])
    hideLines(State.Skel[plr])
    clearLock()
    pcall(clearWatch, plr)
end

local function watch(plr)
    clearWatch(plr)
    hideLines(State.Lines[plr]) -- respawn gap: never show a box with no body behind it
    hideLines(State.Skel[plr]) -- respawn gap: same rule for the skeleton
    State.Rigs[plr] = nil       -- drop the joint graph, it belongs to the dead body
    if Lock.Pl == plr and not validChar(Lock.Char) then clearLock() end
    local char = plr.Character
    if not char then return end

    local conns = {}
    State.Watch[plr] = conns

    local function add(c) if c then conns[#conns + 1] = c end end

    add(pcall(function() return char.AncestryChanged:Connect(function() onCharacterGone(plr, char) end) end))
    add(pcall(function() return char.Destroying:Connect(function() onCharacterGone(plr, char) end) end))
    add(pcall(function()
        return char.ChildRemoved:Connect(function(child)
            if child:IsA("Humanoid") then onCharacterGone(plr, char) end
        end)
    end))

    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        add(pcall(function()
            return hum.HealthChanged:Connect(function(h)
                if h <= 0 then onCharacterGone(plr, char) end
            end)
        end))
        add(pcall(function() return hum.Died:Connect(function() onCharacterGone(plr, char) end) end))
    end

    -- Humanoid can arrive a tick after the model (streaming / respawn).
    add(pcall(function()
        return char.ChildAdded:Connect(function(child)
            if child:IsA("Humanoid") then watch(plr) end
        end)
    end))
end

if Players then
    pcall(function()
        for _, plr in ipairs(Players:GetPlayers()) do
            watch(plr)
            pcall(function()
                plr.CharacterAdded:Connect(function() watch(plr) end)
                plr.CharacterRemoving:Connect(function(char) onCharacterGone(plr, char) end)
            end)
        end
        Players.PlayerAdded:Connect(function(plr)
            watch(plr)
            pcall(function()
                plr.CharacterAdded:Connect(function() watch(plr) end)
                plr.CharacterRemoving:Connect(function(char) onCharacterGone(plr, char) end)
            end)
        end)
        Players.PlayerRemoving:Connect(function(plr)
            onCharacterGone(plr, plr.Character)
            local arr = State.Lines[plr]
            if arr then
                for _, l in ipairs(arr) do pcall(function() l:Remove() end) end
            end
            State.Lines[plr] = nil
            State.Rigs[plr] = nil
            clearWatch(plr)
        end)
    end)
end

-- ═══════════════════════════════════════════════════════════════════
--  FRAME PASSES  (each isolated so one failure can't affect another)
-- ═══════════════════════════════════════════════════════════════════
local function fovPass(center)
    if not State.Fov then return end
    local show = Vision.Flags.aim_showfov == true
    State.Fov.Visible = show
    if not show then return end
    State.Fov.Position = center
    State.Fov.Radius = math.clamp(tonumber(Vision.Flags.aim_fov) or 120, 1, 2000)
    State.Fov.Thickness = math.clamp(tonumber(Vision.Flags.aim_fov_thick) or 1, 1, 5)
    local c = Vision.Flags.aim_fov_color
    State.Fov.Color = (typeof(c) == "Color3" and c) or Color3.fromRGB(255, 255, 255)
end

-- Half-extents of one part's world AABB. The absolute rotation matrix dotted
-- with the part's half-size is exact for an oriented box, not an estimate, and
-- costs nine multiplies -- far cheaper than projecting eight corners later.
local function partBounds(part, minX, minY, minZ, maxX, maxY, maxZ)
    local cx, cy, cz, r00, r01, r02, r10, r11, r12, r20, r21, r22 =
        part.CFrame:GetComponents()
    local hx, hy, hz = part.Size.X * 0.5, part.Size.Y * 0.5, part.Size.Z * 0.5
    local ex = math.abs(r00) * hx + math.abs(r01) * hy + math.abs(r02) * hz
    local ey = math.abs(r10) * hx + math.abs(r11) * hy + math.abs(r12) * hz
    local ez = math.abs(r20) * hx + math.abs(r21) * hy + math.abs(r22) * hz
    return math.min(minX, cx - ex), math.min(minY, cy - ey), math.min(minZ, cz - ez),
        math.max(maxX, cx + ex), math.max(maxY, cy + ey), math.max(maxZ, cz + ez)
end

-- Bounds of a character's body as world-axis-aligned min/max per axis, or nil
-- when there is nothing to box.
--
-- GetBoundingBox() is the obvious call, but its box is ORIENTED to the
-- character's pivot: an R6 avatar is 4 studs across facing you and 1 side-on,
-- so measuring it that way makes the ESP box visibly squish as a target turns.
-- Unioning every part's own world AABB instead is both tight and steady,
-- because it measures the silhouette that is actually on screen.
--
-- Only direct BasePart children are read, and "Handle" is skipped: that is how
-- both the R6 and R15 rigs parent a hat, and how an equipped tool's mesh is
-- named, so neither can inflate the box past the body. A rig with no direct
-- body parts (a custom nested model) falls back to GetDescendants, still
-- skipping handles.
local function bodyBounds(char)
    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    local found = false
    for _, part in ipairs(char:GetChildren()) do
        if part:IsA("BasePart") and part.Name ~= "Handle" then
            minX, minY, minZ, maxX, maxY, maxZ =
                partBounds(part, minX, minY, minZ, maxX, maxY, maxZ)
            found = true
        end
    end
    if not found then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and part.Name ~= "Handle" then
                minX, minY, minZ, maxX, maxY, maxZ =
                    partBounds(part, minX, minY, minZ, maxX, maxY, maxZ)
                found = true
            end
        end
    end
    if not found then return nil end
    return minX, minY, minZ, maxX, maxY, maxZ
end

-- ═══════════════════════════════════════════════════════════════════
--  SKELETON ESP
--  An R6 rig and an R15 rig disagree about almost everything except anatomy:
--  both hang a Neck, a Left/Right Shoulder and a Left/Right Hip off the torso,
--  and both spell those names -- except R6 spells them with a space
--  ("Left Shoulder") where R15 spells them closed up ("LeftShoulder"), and only
--  R15 has elbow, wrist, knee and ankle motors at all. Reading the motors is
--  still the right source: they give real joint positions instead of part
--  centres, and they survive a body rescale. What was missing was trying BOTH
--  spellings, and handing R6 the limb tips it has no motors for -- with "Left
--  Elbow" alone, no rig ever resolved a single joint and nothing drew.
--
--  Nothing above the neck is read: no Head part, no Neck C1. The figure ends
--  at the neck on purpose.
-- ═══════════════════════════════════════════════════════════════════
local SKEL_REF_PX = 90     -- figure height (px) at which the slider applies as-is
local SKEL_MIN_T = 2       -- px, a 1px skeleton is a smudge, not a skeleton
local SKEL_MAX_T = 10      -- px, and never swell into a blob up close
local SKEL_MIN_SPAN = 8    -- px, below this the figure is a smudge
local SKEL_JOINT_K = 2.0   -- joint dot diameter as a multiple of the bone width
local SKEL_DOT_MAX = 0.18  -- a joint dot may never exceed this share of the figure
local SKEL_OUTLINE_K = 2   -- px the black pass is wider / fatter: 1px per side
local SKEL_BLACK = Color3.new(0, 0, 0)
-- The drawn pelvis. A rig puts its hip joints narrow and low, so a figure built
-- straight off the motors has a thin bar under a long waist. The bar is drawn at
-- this share of the shoulder span -- 75%, a touch tighter than the shoulders,
-- which reads cleaner than an exact match -- and the pair rises toward the chest
-- by SKEL_HIP_LIFT of the drop. Both numbers are the whole shape.
local SKEL_HIP_SPAN_K = 0.75   -- drawn hip span as a share of the shoulder span
local SKEL_HIP_LIFT = 0.15     -- share of the chest-to-hip drop the hips rise by
local SKEL_HIP_MIN_SPAN = 0.25 -- studs; below this the shoulder span is degenerate

-- 15 world anchors, filled once per target per frame, in this order:
--   1 pelvis    2 chest     3 neck
--   4 shoulderL 5 shoulderR 6 elbowL  7 wristL  8 elbowR  9 wristR
--  10 hipL     11 hipR    12 kneeL  13 ankleL 14 kneeR  15 ankleR
-- The chest is the torso centre and the pelvis is derived from the rig's own hip
-- joints -- re-spread to the shoulder span and lifted a little, see below -- and
-- 3..15 are real joints on R15, while on R6 the two that rig does not have are
-- filled with the limb brick's own centre.
local SKEL_ANCHOR = 15

-- R15 bones: thirteen, every one of them a real joint pair.
local SKEL_BONES_R15 = {
    { 1, 2 }, { 2, 3 },          -- spine: pelvis -> chest -> neck
    { 3, 4 }, { 3, 5 },          -- clavicles
    { 4, 6 }, { 6, 7 },          -- left arm:  humerus, forearm
    { 5, 8 }, { 8, 9 },          -- right arm
    { 10, 11 },                  -- pelvis bar
    { 10, 12 }, { 12, 13 },      -- left leg:  femur, tibia
    { 11, 14 }, { 14, 15 },      -- right leg
}
local SKEL_JOINTS_R15 = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }

-- R6 bones: nine. An R6 arm is one brick hinged at the shoulder and an R6 leg
-- is one brick hinged at the hip: there is no elbow, knee, wrist or ankle to
-- mark, so the figure draws the joints that exist rather than inventing a
-- mid-limb dot that would claim a hinge the rig does not have. The limb tips
-- land on anchors 7, 9, 13 and 15 -- exactly where R15 keeps its wrists and
-- ankles -- which is why both tables can share one anchor set.
local SKEL_BONES_R6 = {
    { 1, 2 }, { 2, 3 },
    { 3, 4 }, { 3, 5 },
    { 4, 7 }, { 5, 9 },          -- whole arms, shoulder -> hand
    { 10, 11 },
    { 10, 13 }, { 11, 15 },      -- whole legs, hip -> foot
}
local SKEL_JOINTS_R6 = { 3, 4, 5, 7, 9, 10, 11, 13, 15 }

-- Each pass holds one slot per bone and one per joint. Sized on the larger rig
-- (R15: 13 + 13); the slots an R6 figure does not use simply stay hidden.
local SKEL_BONE_SLOTS = 13
local SKEL_JOINT_SLOTS = 13
local SKEL_PASS_SLOTS = SKEL_BONE_SLOTS + SKEL_JOINT_SLOTS
local SKEL_SLOTS = SKEL_PASS_SLOTS * 2

-- Motor names, both spellings, keyed by the joint each one means. Canonicalising
-- them here is what keeps everything below rig-agnostic: R6 resolves fewer of
-- these and falls back to the brick for the rest, and no branch in the drawing
-- code has to know which rig it is looking at.
local SKEL_MOTORS = {
    { key = "neck",      names = { "Neck" } },
    { key = "shoulderL", names = { "Left Shoulder", "LeftShoulder" } },
    { key = "shoulderR", names = { "Right Shoulder", "RightShoulder" } },
    { key = "elbowL",    names = { "Left Elbow", "LeftElbow" } },
    { key = "elbowR",    names = { "Right Elbow", "RightElbow" } },
    { key = "wristL",    names = { "Left Wrist", "LeftWrist" } },
    { key = "wristR",    names = { "Right Wrist", "RightWrist" } },
    { key = "hipL",      names = { "Left Hip", "LeftHip" } },
    { key = "hipR",      names = { "Right Hip", "RightHip" } },
    { key = "kneeL",     names = { "Left Knee", "LeftKnee" } },
    { key = "kneeR",     names = { "Right Knee", "RightKnee" } },
    { key = "ankleL",    names = { "Left Ankle", "LeftAnkle" } },
    { key = "ankleR",    names = { "Right Ankle", "RightAnkle" } },
}

-- World position of a joint: a Motor6D's C0 is the attachment on the parent, so
-- for "Left Knee" that point IS the knee and not merely the top of the shin.
local function jointPos(m)
    if not m or not m.Part0 or not m.C0 then return nil end
    return m.Part0.CFrame * m.C0.Position
end

-- The two ends of a limb brick along its own Y. Which one is the joint and
-- which is the tip is decided by comparing their distances to a reference
-- point, never by assuming +Y or -Y: an R6 arm, an R15 forearm, a mirrored limb
-- and a body rescaled at runtime all resolve the same way.
local function limbEnd(part, ref, wantFar)
    if not part then return nil end
    local half = part.Size.Y * 0.5
    local a = part.CFrame * Vector3.new(0, half, 0)
    local b = part.CFrame * Vector3.new(0, -half, 0)
    if not ref then return b end
    local da = (a - ref):Dot(a - ref)
    local db = (b - ref):Dot(b - ref)
    if wantFar then
        return (da >= db) and a or b
    end
    return (da <= db) and a or b
end

-- A body-side axis with the lean taken out: the horizontal part of a vector as a
-- unit vector, or nil when there is no horizontal part to spread a bar along.
local function flatAxis(v)
    if not v then return nil end
    local flat = Vector3.new(v.X, 0, v.Z)
    local len = flat.Magnitude
    if len < 1e-4 then return nil end
    return flat / len
end

-- One record per character: which rig it is, its body parts, and its motors
-- keyed by canonical joint. Built once and reused until the body respawns
-- (watch() drops it), because walking a whole character every frame for a graph
-- that only changes on respawn is pure waste.
--
-- The character is walked as a whole rather than by direct children: R6 parents
-- its motors onto the Torso and R15 onto the model itself, and accessories can
-- hang anywhere, so one descendants pass covers every rig there is.

-- First existing BasePart among the names, so every body role resolves on
-- either rig's naming convention instead of on a guess about which is in play.
local function partGrab(char, ...)
    for i = 1, select("#", ...) do
        local p = char:FindFirstChild((select(i, ...)))
        if p and p:IsA("BasePart") then return p end
    end
    return nil
end

local function rigFor(plr, char)
    local cached = State.Rigs[plr]
    if cached and cached.char == char then return cached end

    local m = {}
    local parts = {}
    local ok = pcall(function()
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("Motor6D") and m[d.Name] == nil then
                m[d.Name] = d
            end
        end
        -- Body parts by role, trying each rig's spelling in turn: R15 calls them
        -- LeftUpperArm / LeftLowerArm / LeftHand, R6 calls all three "Left Arm",
        -- and a custom rig may mix the two. Betting on one convention at a time
        -- left every role of the other one unresolved.
        parts.torso = partGrab(char, "UpperTorso", "Torso")
        parts.head = partGrab(char, "Head")
        parts.upperArmL = partGrab(char, "LeftUpperArm", "Left Arm")
        parts.lowerArmL = partGrab(char, "LeftLowerArm", "Left Arm")
        parts.handL = partGrab(char, "LeftHand", "Left Arm")
        parts.upperArmR = partGrab(char, "RightUpperArm", "Right Arm")
        parts.lowerArmR = partGrab(char, "RightLowerArm", "Right Arm")
        parts.handR = partGrab(char, "RightHand", "Right Arm")
        parts.upperLegL = partGrab(char, "LeftUpperLeg", "Left Leg")
        parts.lowerLegL = partGrab(char, "LeftLowerLeg", "Left Leg")
        parts.footL = partGrab(char, "LeftFoot", "Left Leg")
        parts.upperLegR = partGrab(char, "RightUpperLeg", "Right Leg")
        parts.lowerLegR = partGrab(char, "RightLowerLeg", "Right Leg")
        parts.footR = partGrab(char, "RightFoot", "Right Leg")
    end)
    if not ok then return nil end

    local J = {}
    for _, spec in ipairs(SKEL_MOTORS) do
        for _, name in ipairs(spec.names) do
            if m[name] then
                J[spec.key] = m[name]
                break
            end
        end
    end

    -- Bones are not stored here: which figure this body carries depends on
    -- whether its elbows and knees are real, and that is a per-frame question
    -- (see skeletonFor), not a property of the body.
    local rec = { char = char, J = J, p = parts }
    State.Rigs[plr] = rec
    return rec
end

-- The elbow, or the knee. A motor is exact. Without one, the joint is the end
-- of the LOWER brick that faces the brick above it -- and only when the lower
-- brick is a brick of its own. On a one-brick limb (R6) the end nearest the
-- upper brick's centre is that brick's own top end, i.e. the shoulder: asking
-- it for an elbow is what made every R6 arm and leg zero-length.
local function elbowOrKnee(motor, upper, lower)
    local exact = jointPos(motor)
    if exact then return exact end
    if not (upper and lower) or lower == upper then return nil end
    return limbEnd(lower, upper.CFrame.Position, false)
end

-- A distal joint -- a wrist or an ankle. A motor is exact. Otherwise the near
-- end of the hand/foot brick measured against the elbow/knee above it, or, when
-- the whole limb is one brick, the far tip measured against the shoulder/hip,
-- which is exactly where the hand or the foot is.
local function tipOrJoint(motor, proximal, handPart, lowerPart, upperPart, from)
    local exact = jointPos(motor)
    if exact then return exact end
    if proximal and handPart then
        local near = limbEnd(handPart, proximal, false)
        if near then return near end
    end
    if proximal and lowerPart and lowerPart ~= upperPart then
        return limbEnd(lowerPart, proximal, true)
    end
    if upperPart and from then return limbEnd(upperPart, from, true) end
    return nil
end

-- Fill the 15 anchors for one body, and hand back the bone and joint set that
-- body can honestly carry. A motor wins wherever the rig has one; everything
-- else comes off the limb brick hanging below the joint above it, so no rig
-- needs a single hard-coded offset. Nil means the body is not complete enough
-- to draw an honest figure: half a skeleton is worse than none.
local function skeletonFor(rig, pts)
    local J, P = rig.J, rig.p
    local torso = P.torso
    if not torso then return nil end
    local tRef = torso.CFrame.Position -- every limb joint hangs off the torso

    local neck = jointPos(J.neck) or (P.head and limbEnd(P.head, tRef, false))
    local shL = jointPos(J.shoulderL) or limbEnd(P.upperArmL, tRef, false)
    local shR = jointPos(J.shoulderR) or limbEnd(P.upperArmR, tRef, false)
    local hipL = jointPos(J.hipL) or limbEnd(P.upperLegL, tRef, false)
    local hipR = jointPos(J.hipR) or limbEnd(P.upperLegR, tRef, false)
    if not (neck and shL and shR and hipL and hipR) then return nil end

    local elL = elbowOrKnee(J.elbowL, P.upperArmL, P.lowerArmL)
    local elR = elbowOrKnee(J.elbowR, P.upperArmR, P.lowerArmR)
    local knL = elbowOrKnee(J.kneeL, P.upperLegL, P.lowerLegL)
    local knR = elbowOrKnee(J.kneeR, P.upperLegR, P.lowerLegR)

    local wrL = tipOrJoint(J.wristL, elL, P.handL, P.lowerArmL, P.upperArmL, shL)
    local wrR = tipOrJoint(J.wristR, elR, P.handR, P.lowerArmR, P.upperArmR, shR)
    local anL = tipOrJoint(J.ankleL, knL, P.footL, P.lowerLegL, P.upperLegL, hipL)
    local anR = tipOrJoint(J.ankleR, knR, P.footR, P.lowerLegR, P.upperLegR, hipR)
    if not (wrL and wrR and anL and anR) then return nil end

    -- The drawn pelvis and the drawn hips. The rig's own hip joints are still what
    -- the ankles above were measured against, but they are not what gets drawn:
    -- the pair is rebuilt from the rig's pelvis centre, spread to the shoulder
    -- span along the body's side axis, and lifted a little toward the chest. Two
    -- parallel bars of one width read as a clean torso; a wide shoulder bar over a
    -- narrow pelvis bar read as a thin waist. The legs hang off the result, so
    -- each femur tilts inward the way a real one does.
    local pelvis = (hipL + hipR) * 0.5
    -- left shoulder -> right shoulder is the body's right, whatever the rig calls
    -- its axes, so the pair keeps its sides without assuming a convention.
    local side = flatAxis(shR - shL) or flatAxis(torso.CFrame.RightVector)
    local span = side and math.abs((shR - shL):Dot(side)) or 0
    if side and span >= SKEL_HIP_MIN_SPAN then
        pelvis = pelvis + (tRef - pelvis) * SKEL_HIP_LIFT
        local half = span * SKEL_HIP_SPAN_K * 0.5
        hipL = pelvis - side * half
        hipR = pelvis + side * half
    end
    pts[1] = pelvis
    -- Chest: the torso's own centre. The midpoint of the two shoulders -- what
    -- this used to be -- sits at the TOP of the torso, which is the neck, so the
    -- chest dot and the neck dot landed on the same pixel and the spine read as
    -- two points instead of three.
    pts[2] = tRef
    pts[3] = neck                 -- top of the figure; the skull is not drawn
    pts[4], pts[5] = shL, shR
    -- A one-brick limb has no middle joint, so slots 6/8 and 12/14 hold the
    -- brick's own centre. Nothing is drawn there -- the R6 bone table skips
    -- them -- but the range and cull tests read all fifteen anchors, and a brick
    -- centre is a point that is genuinely inside the body.
    pts[6], pts[7] = elL or (P.upperArmL and P.upperArmL.CFrame.Position) or shL, wrL
    pts[8], pts[9] = elR or (P.upperArmR and P.upperArmR.CFrame.Position) or shR, wrR
    pts[10], pts[11] = hipL, hipR
    pts[12], pts[13] = knL or (P.upperLegL and P.upperLegL.CFrame.Position) or hipL, anL
    pts[14], pts[15] = knR or (P.upperLegR and P.upperLegR.CFrame.Position) or hipR, anR

    -- Which figure this body carries: thirteen bones when its elbows and knees
    -- are real joints, nine when its limbs are single bricks.
    if elL and elR and knL and knR then
        return SKEL_BONES_R15, SKEL_JOINTS_R15
    end
    return SKEL_BONES_R6, SKEL_JOINTS_R6
end
-- SKEL_SLOTS pooled drawings per target: 13 bones and 13 joint dots per pass,
-- black first so Drawing's creation order puts it underneath, then the coloured
-- pass repeated at +SKEL_PASS_SLOTS. A failed creation is stored as `false`,
-- never nil, so the bone/dot split always holds and ipairs never stops early.
--
-- The dots are Circles, and a FILLED Circle is sized by Radius -- its Thickness
-- is the outline, not its diameter. Driving the dots from Thickness (as the
-- first cut did) left them at the executor's default radius: a two-pixel ESP on
-- a rig that never resolved, so nothing at all appeared.
local function skelLinesFor(plr)
    local arr = State.Skel[plr]
    if arr then return arr end
    arr = {}
    if hasDrawing() then
        for pass = 0, 1 do
            for i = 1, SKEL_PASS_SLOTS do
                local isBone = i <= SKEL_BONE_SLOTS
                local ok, d
                if isBone then
                    ok, d = pcall(Drawing.new, "Line")
                else
                    ok, d = pcall(Drawing.new, "Circle")
                end
                if ok and d then
                    d.Transparency = DRAW_OPAQUE
                    d.Visible = false
                    if isBone then
                        if pass == 0 then d.Color = SKEL_BLACK end
                    else
                        d.Filled = true  -- a joint reads as a solid head of bone
                        d.NumSides = 10  -- fixed at creation, never per frame
                        if pass == 0 then d.Color = SKEL_BLACK end
                    end
                    arr[pass * SKEL_PASS_SLOTS + i] = d
                else
                    arr[pass * SKEL_PASS_SLOTS + i] = false
                end
            end
        end
    end
    State.Skel[plr] = arr
    return arr
end

-- Reused across players, so a full frame allocates no tables and no Vector2s
-- for the anchor data: screen coordinates stay plain numbers, and the only
-- Vector2s built are the endpoints handed to Drawing, each shared by both
-- passes instead of allocated twice.
local skelPts = {}
local skelX, skelY = {}, {}

local function skelPass(center)
    -- RULE 1 on its own pool: the skeleton must not wipe the corner box, and the
    -- corner box must not wipe the skeleton.
    for _, arr in pairs(State.Skel) do
        hideLines(arr)
    end
    for plr, arr in pairs(State.Skel) do
        if typeof(plr) ~= "Instance" or plr.Parent == nil then
            for _, d in ipairs(arr) do
                if d then pcall(function() d:Remove() end) end
            end
            State.Skel[plr] = nil
            State.Rigs[plr] = nil
        end
    end
    if Vision.Flags.skel_esp ~= true then return end

    local maxD = tonumber(Vision.Flags.esp_dist) or 800 -- shares the ESP range
    local col = Vision.Flags.skel_color
    col = (typeof(col) == "Color3" and col) or Color3.fromRGB(255, 255, 255)
    local wantJoints = Vision.Flags.skel_joints ~= false
    local wantOutline = Vision.Flags.skel_outline ~= false
    local nominal = tonumber(Vision.Flags.skel_thick) or 3
    nominal = math.clamp(math.floor(nominal), SKEL_MIN_T, SKEL_MAX_T)
    local memo = {}

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and not teamBlocked(Vision.Flags.esp_team, plr) and not friendBlocked(plr) then
            local char = plr.Character
            if validChar(char, memo) then
                pcall(function()
                    local rig = rigFor(plr, char)
                    if not rig then return end
                    -- The body decides its own bone set: a rig with real elbows
                    -- and knees gets the thirteen-bone figure, one without them
                    -- gets the nine-bone figure. Nil means it is not whole enough
                    -- to draw an honest skeleton at all.
                    local bones, joints = skeletonFor(rig, skelPts)
                    if not bones then return end

                    -- Range on the skeleton itself: the world AABB of the 15
                    -- anchors, tested at its closest point. That is exactly the
                    -- volume the figure occupies, so it needs no second walk over
                    -- every body part, and it is the same rule the corner box
                    -- uses, so the two toggles agree about who is too far away.
                    local loX, loY, loZ = math.huge, math.huge, math.huge
                    local hiX, hiY, hiZ = -math.huge, -math.huge, -math.huge
                    for i = 1, SKEL_ANCHOR do
                        local p = skelPts[i]
                        if p.X < loX then loX = p.X end
                        if p.X > hiX then hiX = p.X end
                        if p.Y < loY then loY = p.Y end
                        if p.Y > hiY then hiY = p.Y end
                        if p.Z < loZ then loZ = p.Z end
                        if p.Z > hiZ then hiZ = p.Z end
                    end
                    local camPos = Camera.CFrame.Position
                    local ex = math.clamp(camPos.X, loX, hiX) - camPos.X
                    local ey = math.clamp(camPos.Y, loY, hiY) - camPos.Y
                    local ez = math.clamp(camPos.Z, loZ, hiZ) - camPos.Z
                    if ex * ex + ey * ey + ez * ez > maxD * maxD then return end

                    -- Project, and take the vertical span while doing it: that
                    -- span IS the size the eye judges the figure by, so it
                    -- doubles as the scale reference below.
                    local left, right = math.huge, -math.huge
                    local top, bot = math.huge, -math.huge
                    for i = 1, SKEL_ANCHOR do
                        local sp = Camera:WorldToViewportPoint(skelPts[i])
                        if sp.Z <= 0 then return end -- straddling the near plane
                        skelX[i], skelY[i] = sp.X, sp.Y
                        if sp.X < left then left = sp.X end
                        if sp.X > right then right = sp.X end
                        if sp.Y < top then top = sp.Y end
                        if sp.Y > bot then bot = sp.Y end
                    end
                    local span = bot - top
                    if span < SKEL_MIN_SPAN then return end

                    -- Cull a figure that is entirely off-screen. Unlike the
                    -- corner box this one is NOT clamped to the edge: a skeleton
                    -- pinned to the border would claim a body is there when only
                    -- a sliver of it is.
                    local vw, vh = center.X * 2, center.Y * 2
                    if right < -ESP_EDGE or left > vw + ESP_EDGE then return end
                    if bot < -ESP_EDGE or top > vh + ESP_EDGE then return end

                    -- SIZING. A fixed pixel width is wrong at both ends of the
                    -- range: one pixel of bone on a 30px skeleton is noise, and
                    -- one pixel on a 600px skeleton is a hairline you cannot
                    -- follow. Scaling with the figure's own on-screen height makes
                    -- it read the same at every distance, and SKEL_REF_PX is the
                    -- height at which the slider value applies verbatim. One
                    -- width for every bone, not one per bone: a skeleton is
                    -- uniform, and per-bone widths would make a clavicle as thick
                    -- as a femur.
                    local t = math.clamp(
                        math.round(nominal * span / SKEL_REF_PX), SKEL_MIN_T, SKEL_MAX_T)
                    -- The dot is capped against the figure as well as against the
                    -- bone: on a 9px-tall skeleton a 4px dot would swallow the
                    -- joints it is meant to mark, so the cap bites exactly where
                    -- it is needed.
                    local jd = math.clamp(math.round(t * SKEL_JOINT_K), 1,
                        math.max(2, math.round(span * SKEL_DOT_MAX)))

                    local arr = skelLinesFor(plr)
                    local ot = t + SKEL_OUTLINE_K

                    -- Bones. One pair of endpoints feeds both passes: Drawing
                    -- copies the value on assignment, so the outline and the
                    -- colour can share them instead of allocating two sets.
                    for b = 1, #bones do
                        local e = bones[b]
                        local v1 = Vector2.new(skelX[e[1]], skelY[e[1]])
                        local v2 = Vector2.new(skelX[e[2]], skelY[e[2]])
                        if wantOutline then
                            local dark = arr[b]
                            if dark then
                                dark.Thickness = ot
                                dark.From, dark.To = v1, v2
                                dark.Visible = true
                            end
                        end
                        local lit = arr[SKEL_PASS_SLOTS + b]
                        if lit then
                            lit.Thickness = t
                            lit.From, lit.To = v1, v2
                            lit.Color = col
                            lit.Visible = true
                        end
                    end

                    -- Joints. A filled dot a touch wider than the bone it caps,
                    -- so a knee and an elbow read as hinges rather than as bends
                    -- in a wire. Sized by Radius: that is the dot's diameter
                    -- somewhere in the executor's Circle, and it is the only
                    -- property that follows the figure at every distance.
                    if wantJoints then
                        local r = jd * 0.5
                        local rDark = r + SKEL_OUTLINE_K * 0.5
                        for jj = 1, #joints do
                            local a = joints[jj]
                            local p = Vector2.new(skelX[a], skelY[a])
                            if wantOutline then
                                local dark = arr[SKEL_BONE_SLOTS + jj]
                                if dark then
                                    dark.Radius = rDark
                                    dark.Position = p
                                    dark.Visible = true
                                end
                            end
                            local lit = arr[SKEL_PASS_SLOTS + SKEL_BONE_SLOTS + jj]
                            if lit then
                                lit.Radius = r
                                lit.Position = p
                                lit.Color = col
                                lit.Visible = true
                            end
                        end
                    end
                end)
            end
        end
    end
end

local function espPass(center)
    -- RULE 1: wipe first. Nothing drawn last frame can survive into this one.
    for _, arr in pairs(State.Lines) do
        hideLines(arr)
    end
    -- Drop drawings for players who already left.
    for plr, arr in pairs(State.Lines) do
        if typeof(plr) ~= "Instance" or plr.Parent == nil then
            for _, l in ipairs(arr) do
                if l then pcall(function() l:Remove() end) end
            end
            State.Lines[plr] = nil
            State.Rigs[plr] = nil
            clearWatch(plr)
            if Lock.Pl == plr then clearLock() end
        end
    end
    if Vision.Flags.esp_corner ~= true then return end

    local maxD = tonumber(Vision.Flags.esp_dist) or 800
    local base = Vision.Flags.esp_color
    base = (typeof(base) == "Color3" and base) or Color3.fromRGB(255, 255, 255)
    local visCol = Vision.Flags.esp_vis_color
    visCol = (typeof(visCol) == "Color3" and visCol) or Color3.fromRGB(120, 255, 140)
    local visCheck = Vision.Flags.esp_vischeck == true
    -- Mirrors the Line Thickness slider range. A hand-edited config must never
    -- hand Drawing a zero, negative or absurd width.
    local thick = math.clamp(math.floor(tonumber(Vision.Flags.esp_thick) or ESP_LINE_T), 1, 6)

    -- One validity lookup per character per frame instead of the two or three
    -- the pcall / GetState chain used to cost. Scoped to this frame on purpose.
    local memo = {}

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and not teamBlocked(Vision.Flags.esp_team, plr) and not friendBlocked(plr) then
            local char = plr.Character
            if validChar(char, memo) then
                pcall(function()
                    -- Bounds first, so the box is measured in world space rather
                    -- than guessed from a single oriented extent.
                    local ax, ay, az, bx, by, bz = bodyBounds(char)
                    if not ax then return end

                    local ctr = Vector3.new(
                        (ax + bx) * 0.5,
                        (ay + by) * 0.5,
                        (az + bz) * 0.5
                    )
                    local camPos = Camera.CFrame.Position
                    -- Range tests the CLOSEST point of the body, not its middle.
                    -- Centre testing hides a target whose near arm is inside Max
                    -- Distance while the middle of the torso is outside it, which
                    -- is exactly what makes a distance slider feel like it lies.
                    -- Clamping the camera into the box is the standard
                    -- closest-point-on-AABB, and squaring it avoids the sqrt.
                    local nx = math.clamp(camPos.X, ax, bx)
                    local ny = math.clamp(camPos.Y, ay, by)
                    local nz = math.clamp(camPos.Z, az, bz)
                    local ex, ey, ez = nx - camPos.X, ny - camPos.Y, nz - camPos.Z
                    if ex * ex + ey * ey + ez * ez > maxD * maxD then return end

                    -- Slack, then the box's eight world corners. The box is
                    -- axis-aligned, so the corners are just the min/max pairs --
                    -- nothing to rotate through the camera.
                    local x0, x1 = ax - ESP_PAD, bx + ESP_PAD
                    local y0, y1 = ay - ESP_PAD, by + ESP_PAD
                    local z0, z1 = az - ESP_PAD, bz + ESP_PAD

                    local minX, minY = math.huge, math.huge
                    local maxX, maxY = -math.huge, -math.huge
                    for xi = 0, 1 do
                        for yi = 0, 1 do
                            for zi = 0, 1 do
                                local sp = Camera:WorldToViewportPoint(Vector3.new(
                                    xi == 0 and x0 or x1,
                                    yi == 0 and y0 or y1,
                                    zi == 0 and z0 or z1
                                ))
                                -- Any corner behind the eye means the box straddles
                                -- the near plane, which in practice only happens
                                -- at point blank. A behind-eye corner has no
                                -- meaningful bearing to project, and re-aiming it
                                -- on the near plane fanned the rest of the box out
                                -- until it swallowed the whole screen -- so refuse
                                -- it, and refuse it per player per frame, so a
                                -- target you are turning away from drops the same
                                -- frame it stops being reachable.
                                if sp.Z <= 0 then return end
                                if sp.X < minX then minX = sp.X end
                                if sp.X > maxX then maxX = sp.X end
                                if sp.Y < minY then minY = sp.Y end
                                if sp.Y > maxY then maxY = sp.Y end
                            end
                        end
                    end

                    -- Cull only a box that is completely off-screen, then pin
                    -- what is left to the viewport plus ESP_EDGE. An unclamped
                    -- box for a target off to the side spans thousands of pixels
                    -- of empty screen and snaps into place the instant you turn;
                    -- clamping is what holds the corners still against the edge
                    -- while you walk up to them. vw/vh come from the centre the
                    -- render loop already handed us, so the viewport is never
                    -- re-read per target.
                    local vw, vh = center.X * 2, center.Y * 2
                    if maxX < -ESP_EDGE or minX > vw + ESP_EDGE then return end
                    if maxY < -ESP_EDGE or minY > vh + ESP_EDGE then return end
                    if minX < -ESP_EDGE then minX = -ESP_EDGE end
                    if maxX > vw + ESP_EDGE then maxX = vw + ESP_EDGE end
                    if minY < -ESP_EDGE then minY = -ESP_EDGE end
                    if maxY > vh + ESP_EDGE then maxY = vh + ESP_EDGE end

                    -- Snap to whole pixels. A box on a half-pixel row renders
                    -- every border blurred across two rows, which at 1px reads as
                    -- the box shimmering while a target moves; snapping is what
                    -- keeps all four brackets crisp.
                    local x = math.floor(minX + 0.5)
                    local y = math.floor(minY + 0.5)
                    local w = math.floor(maxX + 0.5) - x
                    local h = math.floor(maxY + 0.5) - y
                    -- A floor on both sides, never a range limit, and deliberately
                    -- no ceiling: the clamp above already bounds h to vh + 2 *
                    -- ESP_EDGE, so a ceiling would only drop a box for standing
                    -- too close to someone.
                    if w < ESP_MIN_BOX or h < ESP_MIN_BOX then return end

                    local col = base
                    if visCheck and visibleNow(char, ctr) then
                        col = visCol
                    end
                    drawCorners(espLinesFor(plr), x, y, w, h, col, thick)
                end)
            end
        end
    end
end

local function aimPass(center)
    local held = false
    pcall(function() held = keyHeldNow(AimKey.Get()) end)
    State.AimHeld = held

    local typing = false
    pcall(function() typing = (UserInputService:GetFocusedTextBox() ~= nil) end)

    local canAim = Vision.Flags.aim_enabled == true
        and held
        and not typing
        and validChar(myChar())
        and Camera ~= nil

    if not canAim then
        clearLock()
        return
    end

    -- Re-validate the sticky lock every frame: dead / removed / off-screen
    -- targets drop instantly so a corpse can never drag the camera.
    if not (Lock.Pl and Lock.Char and validPart(Lock.Char, Lock.Part)) then
        clearLock()
    end
    -- The lock is sticky, so a rule that changed mid-lock -- friend toggle on,
    -- team check on -- has to break it here, or the camera keeps dragging to a
    -- player those rules now exclude.
    if Lock.Pl and (teamBlocked(Vision.Flags.aim_team, Lock.Pl) or friendBlocked(Lock.Pl)) then
        clearLock()
    end
    if Lock.Part and Vision.Flags.aim_usefov ~= false then
        local ok, sp, on = pcall(function() return Camera:WorldToViewportPoint(Lock.Part.Position) end)
        local fov = tonumber(Vision.Flags.aim_fov) or 120
        if (not ok) or (not on) or ((Vector2.new(sp.X, sp.Y) - center).Magnitude > fov) then
            clearLock()
        end
    end
    if not Lock.Part then
        local tPl, tChar, tPart = getTarget(center)
        if tPl and tChar and tPart then
            Lock.Pl, Lock.Char, Lock.Part = tPl, tChar, tPart
        end
    end

    local part = validPart(Lock.Char, Lock.Part) and Lock.Part or nil
    if not part then
        clearLock()
        return
    end

    local smooth = math.clamp(tonumber(Vision.Flags.aim_smooth) or 8, 1, 20)
    local alpha = 1 / smooth -- higher slider = slower / safer
    local predict = math.clamp(tonumber(Vision.Flags.aim_predict) or 0, 0, 30) / 100
    local aimPos = part.Position
    pcall(function()
        local v = part.AssemblyLinearVelocity
        if typeof(v) == "Vector3" then
            aimPos = aimPos + v * (predict * 0.9)
        end
    end)
    local goal = CFrame.new(Camera.CFrame.Position, aimPos)
    Camera.CFrame = Camera.CFrame:Lerp(goal, alpha)
end

-- Every pass is isolated, and a failure is no longer invisible. The first few
-- errors of each pass are reported once and the pass keeps running next frame,
-- because a silent pcall is precisely how an ESP that throws on every single
-- frame looks identical to an ESP that draws nothing at all.
local passErrs = {}
local function safePass(name, fn, arg)
    local ok, err = pcall(fn, arg)
    if ok then return end
    local n = (passErrs[name] or 0) + 1
    passErrs[name] = n
    if n <= 3 then
        pcall(function() warn("[Vision] " .. name .. " pass: " .. tostring(err)) end)
    end
end

if RunService then
    State.Conn = RunService.RenderStepped:Connect(function()
        if not Camera then
            Camera = Workspace and Workspace.CurrentCamera
            return
        end
        local vp = Camera.ViewportSize
        local center = Vector2.new(vp.X / 2, vp.Y / 2)
        safePass("fov", fovPass, center)          -- RULE 2: isolated passes
        safePass("esp", espPass, center)          -- wipe + redraw, never trust last frame
        safePass("skeleton", skelPass, center)    -- own pool, own wipe; never touches the box
        safePass("aim", aimPass, center)          -- camera-only, no hooks
    end)
end

return Window
