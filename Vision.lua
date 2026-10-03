local Vision = {}
Vision.Version = "1.2.2"
-- Build marker. Pastebin-hosted libraries are easy to leave stale, and a
-- stale one is invisible: the script runs, nothing errors, and the reworked
-- drag system and loader transition are simply not there. Consumers compare
-- this string against the build they need.
Vision.Build = "2026-10-01-r7"
-- Capability marker. A version string cannot describe what a copy can actually
-- do: a stale in-session copy and a fresh one can claim the same build, and a
-- consumer that only compares versions will happily run the broken one. This
-- states what is guaranteed, and consumers require it outright.
Vision.Caps = {
	keyHelpers = true,   -- keyName / parseKeyString / keyStorageName exist
	autoText = true,     -- Label and Notify size to their wrapped text
	cursorLock = true,   -- open menu frees the cursor even in first person
	cards = true,        -- Window.Card: the docked leaderboard panel exists
	cardControls = true, -- left-docked panel whose column headers sort the table
	cardDrag = true,     -- that panel drags itself and docks without moving the UI
}
Vision.Flags = {}

-- ═══════════════════════════════════════════════════════════════
--  AUTO-SAVE API
--  Vision._scheduleSave()  — call after any flag change (debounced)
--  Vision._forceSave()     — save immediately (player leaving)
--  Vision._suspendSave() / Vision._resumeSave() — suppress saves during init/load
-- ═══════════════════════════════════════════════════════════════
local _savePending = false
local _saveFunc = nil  -- set later inside Window()
local _saveSuspended = 0

function Vision._suspendSave()
	_saveSuspended = _saveSuspended + 1
end

function Vision._resumeSave()
	_saveSuspended = math.max(0, _saveSuspended - 1)
end

function Vision._scheduleSave()
	if _saveSuspended > 0 then return end
	if _savePending then return end
	_savePending = true
	task.delay(1, function()
		_savePending = false
		if _saveSuspended > 0 then return end
		if _saveFunc then pcall(_saveFunc) end
	end)
end

function Vision._forceSave()
	if _saveFunc then pcall(_saveFunc) end
end

local function getService(name)
	local ok, svc = pcall(function()
		return game:GetService(name)
	end)
	if ok and svc then
		if type(cloneref) == "function" then
			local ok2, c = pcall(cloneref, svc)
			if ok2 and c then
				return c
			end
		end
		return svc
	end
	return nil
end

local TweenService = getService("TweenService")
local UserInputService = getService("UserInputService")
local RunService = getService("RunService")
local Players = getService("Players")
local CoreGui = getService("CoreGui")
local HttpService = getService("HttpService")
local Lighting = getService("Lighting")
local GuiService = getService("GuiService")

local function localPlayer()
	return Players and Players.LocalPlayer
end

local function getGuiParent()
	if type(gethui) == "function" then
		local ok, h = pcall(gethui)
		if ok and h then return h end
	end
	if type(get_hidden_gui) == "function" then
		local ok, h = pcall(get_hidden_gui)
		if ok and h then return h end
	end
	if CoreGui then
		return CoreGui
	end
	local lp = localPlayer()
	if lp then
		return lp:FindFirstChildOfClass("PlayerGui") or lp:WaitForChild("PlayerGui")
	end
	return nil
end

local function protectGui(gui)
	pcall(function()
		if syn and syn.protect_gui then
			syn.protect_gui(gui)
		elseif type(protectgui) == "function" then
			protectgui(gui)
		end
	end)
end

local function resolveIcon(icon)
	if not icon or icon == 0 or icon == "" then
		return nil
	end
	if type(icon) == "number" then
		return { Image = "rbxassetid://" .. tostring(math.floor(icon)) }
	end
	if type(icon) == "string" then
		if string.match(icon, "^%d+$") then
			return { Image = "rbxassetid://" .. icon }
		end
		if string.find(icon, "rbxassetid://") == 1 or string.sub(icon, 1, 4) == "http" then
			return { Image = icon }
		end
	end
	return nil
end

local function applyIcon(image, spec)
	if not spec or not spec.Image then
		image.Image = ""
		return false
	end
	image.Image = spec.Image
	if spec.ImageRectSize then
		image.ImageRectSize = spec.ImageRectSize
	end
	if spec.ImageRectOffset then
		image.ImageRectOffset = spec.ImageRectOffset
	end
	image.Visible = true
	return true
end

local ASSET_BASE = "https://raw.githubusercontent.com/Flameware1/Vision/main/assets/"

local function customAssetFn()
	if type(getcustomasset) == "function" then return getcustomasset end
	if type(getsynasset) == "function" then return getsynasset end
	if syn and type(syn.getcustomasset) == "function" then
		return function(p) return syn.getcustomasset(p) end
	end
	return nil
end

local PNG_MAGIC = "\137PNG\r\n\26\n"
local remoteImageCache = {}
local function remoteImage(filename)
	if remoteImageCache[filename] ~= nil then
		return remoteImageCache[filename] or nil
	end
	remoteImageCache[filename] = false
	local getAsset = customAssetFn()
	if not getAsset or type(writefile) ~= "function" then return nil end
	pcall(function()
		local valid = false
		if type(isfile) == "function" and isfile(filename) and type(readfile) == "function" then
			local head = readfile(filename)
			valid = type(head) == "string" and string.sub(head, 1, 8) == PNG_MAGIC
		end
		if not valid then
			local body = game:HttpGet(ASSET_BASE .. filename)
			if type(body) ~= "string" or string.sub(body, 1, 8) ~= PNG_MAGIC then
				return
			end
			writefile(filename, body)
		end
		remoteImageCache[filename] = getAsset(filename)
	end)
	return remoteImageCache[filename] or nil
end

-- Fill an ImageLabel from disk/network without ever blocking the caller.
-- remoteImage() runs a *synchronous* HttpGet on a cold cache, and every one of
-- its call sites sits on the UI construction path -- which runs while the loader
-- is meant to be animating. Blocking there freezes the loader mid-motion, so
-- anything built during a build goes through here instead.
local function loadImageAsync(image, filename, guard)
	if not image then return end
	task.spawn(function()
		local src = remoteImage(filename)
		if not src then return end
		pcall(function()
			if not image.Parent then return end
			if guard and guard.dead then return end
			image.Image = src
		end)
	end)
end

local LOGO_URL = "https://raw.githubusercontent.com/Flameware1/Vision/main/Vision.png"
local STRIPES_FILE = "vision_stripes_v1.png"
local TICK_FILE = "vision_tick_v1.png"
-- Icons from the Lucide set, as hosted for Roblox (the lucide-roblox port). The
-- tick is Lucide's "check", so the toggle matches the rest of the icon language.
local LUCIDE_CHECK = "rbxassetid://7733715400"

local Themes = {
	-- Dark Matter is the default dark, and the one theme that carries its own
	-- backdrop: a space image sits behind the whole window (BgImage), Alpha lowers
	-- the surface frames so that backdrop shows through, Blur eases the scene blur,
	-- and Scrim darkens the image just enough to keep text crisp on top of it.
	-- Every colour stays deliberately near-black so the translucent panels read
	-- as glass over space rather than as a washed-out grey.
	DarkMatter = {
		Accent = Color3.fromRGB(88, 132, 255),
		AccentDark = Color3.fromRGB(14, 16, 34),
		HeaderMid = Color3.fromRGB(30, 34, 60),
		GradientTop = Color3.fromRGB(54, 58, 104),
		HeaderText = Color3.fromRGB(236, 240, 255),
		WindowBg = Color3.fromRGB(5, 6, 12),
		ChromeBg = Color3.fromRGB(3, 4, 9),
		PanelBg = Color3.fromRGB(10, 12, 22),
		ControlBg = Color3.fromRGB(17, 20, 34),
		ControlBorder = Color3.fromRGB(40, 46, 72),
		Track = Color3.fromRGB(23, 27, 44),
		TextWhite = Color3.fromRGB(236, 240, 255),
		TextBright = Color3.fromRGB(205, 212, 240),
		TextMid = Color3.fromRGB(140, 150, 185),
		TextDim = Color3.fromRGB(98, 106, 138),
		Check = Color3.fromRGB(255, 255, 255),
		InfoBg = Color3.fromRGB(236, 240, 255),
		InfoText = Color3.fromRGB(8, 10, 18),
		-- Per-role BackgroundTransparency. Keyed by the palette role whose colour
		-- a frame took, so a repaint can re-glass every surface in one pass.
		Alpha = {
			WindowBg = 0.22,
			ChromeBg = 0.24,
			PanelBg = 0.40,
			ControlBg = 0.32,
			AccentDark = 0.24,
			Track = 0.30,
			InfoBg = 0,
		},
		-- The window backdrop. 441815756 is a Decal, and a Decal id does NOT render
		-- as an ImageLabel texture -- Roblox needs the underlying image, so the
		-- engine falls back to its placeholder (the "cat") and the UI looks broken.
		-- rbxthumb:// is the supported way to display an asset by its id, so the
		-- same asset the caller named is what actually shows. Scrim darkens it so
		-- text stays legible; nil BgImage means "no backdrop".
		BgImage = "rbxthumb://type=Asset&id=441815756&w=420&h=420",
		BgImageTransparency = 0.05,
		Scrim = 0.45,
		-- Suggested scene blur while this theme is active (nil = leave untouched).
		Blur = 8,
	},
	Light = {
		Accent = Color3.fromRGB(45, 130, 245),
		AccentDark = Color3.fromRGB(210, 210, 222),
		HeaderMid = Color3.fromRGB(232, 232, 240),
		GradientTop = Color3.fromRGB(255, 255, 255),
		HeaderText = Color3.fromRGB(30, 30, 38),
		WindowBg = Color3.fromRGB(242, 242, 247),
		ChromeBg = Color3.fromRGB(228, 228, 236),
		PanelBg = Color3.fromRGB(255, 255, 255),
		ControlBg = Color3.fromRGB(238, 238, 244),
		ControlBorder = Color3.fromRGB(208, 208, 220),
		Track = Color3.fromRGB(226, 226, 234),
		TextWhite = Color3.fromRGB(20, 20, 26),
		TextBright = Color3.fromRGB(38, 38, 50),
		TextMid = Color3.fromRGB(110, 110, 122),
		TextDim = Color3.fromRGB(155, 155, 168),
		Check = Color3.fromRGB(255, 255, 255),
		InfoBg = Color3.fromRGB(22, 22, 28),
		InfoText = Color3.fromRGB(245, 245, 250),
	},
	Blue = {
		Accent = Color3.fromRGB(45, 135, 255),
		AccentDark = Color3.fromRGB(14, 55, 125),
		HeaderMid = Color3.fromRGB(68, 105, 155),
		GradientTop = Color3.new(1, 1, 1),
		HeaderText = Color3.fromRGB(255, 255, 255),
		WindowBg = Color3.fromRGB(10, 14, 22),
		ChromeBg = Color3.fromRGB(6, 8, 14),
		PanelBg = Color3.fromRGB(14, 18, 28),
		ControlBg = Color3.fromRGB(21, 26, 39),
		ControlBorder = Color3.fromRGB(46, 52, 70),
		Track = Color3.fromRGB(27, 32, 46),
		TextWhite = Color3.fromRGB(236, 240, 248),
		TextBright = Color3.fromRGB(208, 216, 230),
		TextMid = Color3.fromRGB(140, 150, 170),
		TextDim = Color3.fromRGB(95, 103, 122),
		Check = Color3.fromRGB(255, 255, 255),
		InfoBg = Color3.fromRGB(236, 240, 248),
		InfoText = Color3.fromRGB(12, 14, 18),
	},
	Rose = {
		Accent = Color3.fromRGB(238, 115, 185),
		AccentDark = Color3.fromRGB(118, 30, 70),
		HeaderMid = Color3.fromRGB(165, 105, 133),
		GradientTop = Color3.new(1, 1, 1),
		HeaderText = Color3.fromRGB(255, 255, 255),
		WindowBg = Color3.fromRGB(15, 10, 12),
		ChromeBg = Color3.fromRGB(10, 6, 8),
		PanelBg = Color3.fromRGB(22, 14, 18),
		ControlBg = Color3.fromRGB(31, 21, 25),
		ControlBorder = Color3.fromRGB(58, 40, 47),
		Track = Color3.fromRGB(38, 27, 31),
		TextWhite = Color3.fromRGB(244, 236, 240),
		TextBright = Color3.fromRGB(216, 202, 211),
		TextMid = Color3.fromRGB(155, 138, 149),
		TextDim = Color3.fromRGB(105, 90, 98),
		Check = Color3.fromRGB(255, 255, 255),
		InfoBg = Color3.fromRGB(244, 236, 240),
		InfoText = Color3.fromRGB(18, 12, 14),
	},
	Amethyst = {
		Accent = Color3.fromRGB(165, 95, 255),
		AccentDark = Color3.fromRGB(68, 28, 120),
		HeaderMid = Color3.fromRGB(135, 105, 170),
		GradientTop = Color3.new(1, 1, 1),
		HeaderText = Color3.fromRGB(255, 255, 255),
		WindowBg = Color3.fromRGB(13, 10, 21),
		ChromeBg = Color3.fromRGB(8, 6, 13),
		PanelBg = Color3.fromRGB(20, 14, 30),
		ControlBg = Color3.fromRGB(29, 21, 42),
		ControlBorder = Color3.fromRGB(56, 42, 70),
		Track = Color3.fromRGB(36, 26, 50),
		TextWhite = Color3.fromRGB(239, 231, 252),
		TextBright = Color3.fromRGB(214, 200, 234),
		TextMid = Color3.fromRGB(152, 138, 172),
		TextDim = Color3.fromRGB(102, 92, 118),
		Check = Color3.fromRGB(255, 255, 255),
		InfoBg = Color3.fromRGB(239, 231, 252),
		InfoText = Color3.fromRGB(14, 10, 18),
	},
	Nebula = {
		Accent = Color3.fromRGB(200, 110, 255),
		AccentDark = Color3.fromRGB(46, 20, 74),
		HeaderMid = Color3.fromRGB(120, 78, 170),
		GradientTop = Color3.fromRGB(168, 120, 220),
		HeaderText = Color3.fromRGB(255, 255, 255),
		WindowBg = Color3.fromRGB(12, 8, 20),
		ChromeBg = Color3.fromRGB(7, 5, 13),
		PanelBg = Color3.fromRGB(19, 12, 31),
		ControlBg = Color3.fromRGB(28, 19, 44),
		ControlBorder = Color3.fromRGB(56, 40, 84),
		Track = Color3.fromRGB(34, 24, 52),
		TextWhite = Color3.fromRGB(243, 236, 255),
		TextBright = Color3.fromRGB(219, 206, 246),
		TextMid = Color3.fromRGB(156, 138, 190),
		TextDim = Color3.fromRGB(104, 92, 130),
		Check = Color3.fromRGB(255, 255, 255),
		InfoBg = Color3.fromRGB(243, 236, 255),
		InfoText = Color3.fromRGB(12, 8, 18),
	},
	Midnight = {
		Accent = Color3.fromRGB(63, 208, 255),
		AccentDark = Color3.fromRGB(12, 34, 60),
		HeaderMid = Color3.fromRGB(48, 86, 128),
		GradientTop = Color3.fromRGB(90, 140, 190),
		HeaderText = Color3.fromRGB(255, 255, 255),
		WindowBg = Color3.fromRGB(8, 12, 22),
		ChromeBg = Color3.fromRGB(5, 8, 15),
		PanelBg = Color3.fromRGB(13, 19, 32),
		ControlBg = Color3.fromRGB(20, 28, 44),
		ControlBorder = Color3.fromRGB(44, 60, 88),
		Track = Color3.fromRGB(26, 35, 54),
		TextWhite = Color3.fromRGB(232, 242, 250),
		TextBright = Color3.fromRGB(202, 220, 238),
		TextMid = Color3.fromRGB(136, 156, 182),
		TextDim = Color3.fromRGB(92, 108, 132),
		Check = Color3.fromRGB(255, 255, 255),
		InfoBg = Color3.fromRGB(232, 242, 250),
		InfoText = Color3.fromRGB(8, 12, 20),
	},
	Emerald = {
		Accent = Color3.fromRGB(43, 224, 138),
		AccentDark = Color3.fromRGB(14, 58, 40),
		HeaderMid = Color3.fromRGB(40, 120, 88),
		GradientTop = Color3.fromRGB(78, 190, 140),
		HeaderText = Color3.fromRGB(255, 255, 255),
		WindowBg = Color3.fromRGB(7, 14, 11),
		ChromeBg = Color3.fromRGB(4, 9, 7),
		PanelBg = Color3.fromRGB(12, 22, 17),
		ControlBg = Color3.fromRGB(18, 32, 25),
		ControlBorder = Color3.fromRGB(38, 66, 52),
		Track = Color3.fromRGB(24, 42, 33),
		TextWhite = Color3.fromRGB(232, 250, 240),
		TextBright = Color3.fromRGB(198, 232, 212),
		TextMid = Color3.fromRGB(132, 172, 150),
		TextDim = Color3.fromRGB(88, 118, 102),
		Check = Color3.fromRGB(255, 255, 255),
		InfoBg = Color3.fromRGB(232, 250, 240),
		InfoText = Color3.fromRGB(7, 14, 11),
	},
	Sunset = {
		Accent = Color3.fromRGB(255, 154, 60),
		AccentDark = Color3.fromRGB(74, 34, 22),
		HeaderMid = Color3.fromRGB(150, 84, 60),
		GradientTop = Color3.fromRGB(230, 150, 100),
		HeaderText = Color3.fromRGB(255, 255, 255),
		WindowBg = Color3.fromRGB(18, 11, 10),
		ChromeBg = Color3.fromRGB(12, 7, 6),
		PanelBg = Color3.fromRGB(27, 16, 14),
		ControlBg = Color3.fromRGB(38, 24, 20),
		ControlBorder = Color3.fromRGB(70, 48, 40),
		Track = Color3.fromRGB(46, 30, 25),
		TextWhite = Color3.fromRGB(252, 240, 232),
		TextBright = Color3.fromRGB(236, 214, 198),
		TextMid = Color3.fromRGB(178, 148, 128),
		TextDim = Color3.fromRGB(120, 98, 86),
		Check = Color3.fromRGB(255, 255, 255),
		InfoBg = Color3.fromRGB(252, 240, 232),
		InfoText = Color3.fromRGB(20, 12, 10),
	},
	Frost = {
		Accent = Color3.fromRGB(76, 141, 255),
		AccentDark = Color3.fromRGB(198, 210, 228),
		HeaderMid = Color3.fromRGB(226, 234, 246),
		GradientTop = Color3.fromRGB(255, 255, 255),
		HeaderText = Color3.fromRGB(28, 36, 50),
		WindowBg = Color3.fromRGB(240, 244, 250),
		ChromeBg = Color3.fromRGB(228, 233, 242),
		PanelBg = Color3.fromRGB(255, 255, 255),
		ControlBg = Color3.fromRGB(237, 241, 247),
		ControlBorder = Color3.fromRGB(206, 214, 228),
		Track = Color3.fromRGB(226, 232, 242),
		TextWhite = Color3.fromRGB(18, 24, 36),
		TextBright = Color3.fromRGB(34, 44, 62),
		TextMid = Color3.fromRGB(108, 120, 140),
		TextDim = Color3.fromRGB(150, 160, 178),
		Check = Color3.fromRGB(255, 255, 255),
		InfoBg = Color3.fromRGB(18, 24, 36),
		InfoText = Color3.fromRGB(244, 247, 252),
	},
}

-- Copy the default theme (Dark Matter) into the active palette. Alpha/Blur and
-- the backdrop fields ride along as references; SetTheme replaces the whole table
-- on every switch, so a theme that omits them can never inherit the previous
-- theme's glass or its backdrop.
local Theme = {}
local currentThemeName = "DarkMatter"
for k, v in pairs(Themes.DarkMatter) do
	Theme[k] = v
end

-- The transparency a surface role should carry right now. Group boxes and the
-- controls inside them are built by the consumer AFTER Window() has already
-- applied its theme, so the one-pass repaint can never have touched them; they
-- read this at creation instead. Paired with a zeroed VisionAlphaBase attribute
-- so a later repaint computes the same value rather than stacking a second coat.
local function surfaceAlpha(key)
	local a = Theme and Theme.Alpha and Theme.Alpha[key]
	return tonumber(a) or 0
end

local function applySurface(obj, key)
	if not obj then return obj end
	pcall(function() obj:SetAttribute("VisionAlphaBase", 0) end)
	pcall(function() obj.BackgroundTransparency = surfaceAlpha(key) end)
	return obj
end

-- The colour roles every palette should define. SetTheme backfills any a theme
-- omits from this canonical base, so a sparse theme can never inherit whatever
-- palette happened to be active before it.
local THEME_COLOR_KEYS = {
	"Accent", "AccentDark", "HeaderMid", "GradientTop", "HeaderText",
	"WindowBg", "ChromeBg", "PanelBg", "ControlBg", "ControlBorder", "Track",
	"TextWhite", "TextBright", "TextMid", "TextDim", "Check", "InfoBg", "InfoText",
}

local WIN_W = 660
local WIN_H = 620
local WIN_MIN_H = 240
local WIN_GAP_Y = 64
local WIN_ACTUAL_H = WIN_H
local TOPBAR_H = 56
local FOOTER_H = 30
local MARGIN = 16
local COL_GAP = 14
local COL_W = math.floor((WIN_W - MARGIN * 2 - COL_GAP) / 2)
local HEAD_H = 26
local ROW_H = 26
local TEXT = 13

local FONT = Enum.Font.Gotham
local FONT_MED = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold

local function tween(obj, props, dur, style, dir)
	if not obj or not props then return end
	if not TweenService then
		pcall(function()
			for k, v in pairs(props) do
				obj[k] = v
			end
		end)
		return nil
	end
	local ok, t = pcall(function()
		return TweenService:Create(obj, TweenInfo.new(dur or 0.16, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	end)
	if ok and t then
		pcall(function() t:Play() end)
		return t
	end
	pcall(function()
		for k, v in pairs(props) do
			obj[k] = v
		end
	end)
	return nil
end

local function make(class, props, children)
	local inst = Instance.new(class)
	for k, v in pairs(props or {}) do
		if k ~= "Parent" then
			inst[k] = v
		end
	end
	for _, c in ipairs(children or {}) do
		c.Parent = inst
	end
	if props and props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function corner(parent, r)
	return make("UICorner", { CornerRadius = UDim.new(0, r or 3), Parent = parent })
end

local function stroke(parent, color, transparency)
	return make("UIStroke", {
		Color = color or Theme.ControlBorder,
		Thickness = 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

-- =============================================================================
--  Loading screen (a centered mark, one dot pass, then the logo lands on top)
--
--  No card and no scrim. A single transparent stage covers the screen with
--  Active/Selectable off throughout, so mouse clicks pass straight through to
--  the game while it runs. The mark sits centered and large while the build
--  works. The UI is never shown before LOADER_HOLD has elapsed; then the chrome
--  docks in underneath the mark while a slim progress bar sweeps once (exactly
--  LOADER_DOT_TIME seconds, whatever the frame rate), and the mark then flies
--  down onto the window's own logo slot.
--  Nothing is left behind: no badge, no scrim, no lingering gui.
--
--  Pass { loader = false } to Window() to skip it entirely.
--
--  Not tagged with the Vision attribute on purpose. Window()'s cleanup scan
--  destroys anything carrying that tag, which would tear the loader down in
--  the middle of its own animation.
-- =============================================================================
local LOADER_LOGO = 64          -- mark size while it is centered
local LOADER_LAND = 30          -- resting size: matches the window's own logo
-- The loading pass: a slim bar under the mark that sweeps once while the build
-- works. Calm and self-explanatory, where three bouncing dots read as generic.
local LOADER_BAR_W = 132        -- bar track width
local LOADER_BAR_H = 3          -- bar track height
local LOADER_PILL_W = 46        -- width of the sweeping pill
local LOADER_BAR_DROP = 42      -- bar offset below the screen center
local LOADER_DOT_TIME = 0.8     -- the whole pass, exactly (name kept: the
                                -- loader's timing contract is built on it)
local LOADER_DOCK_WAIT = 0.1    -- beat between the dock and the flight, so the
                                -- logo's real rect can be read after layout
local LOADER_FLY = 0.5          -- flight from the center to the topbar slot
local LOADER_HOLD = 1.15        -- seconds the mark is up before the UI animates
local GLOW_FILE = "vision_glow_v1.png"

Vision._loader = nil
Vision._debug = false

-- Single source of truth for the window's resting rect. Window() places itself
-- with this, the loader is told where the topbar logo lands, and the drag clamp
-- shares the same geometry, so the three can never disagree.
--
-- The window sits centered, but never hugged against the top edge: that edge is
-- exactly where the loader's mark lands, and a titlebar jammed under the top bar
-- reads as a mistake rather than as a draggable window. When the client is too
-- short for the full height it shrinks to fit instead of hanging off the bottom;
-- its pages scroll, so nothing is lost. WIN_ACTUAL_H records the height that was
-- actually used, for the popup placement below.
local function windowRect()
	local vw, vh = 1280, 720
	pcall(function()
		local cam = workspace and workspace.CurrentCamera
		if cam and cam.ViewportSize and cam.ViewportSize.X > 100 then
			vw, vh = cam.ViewportSize.X, cam.ViewportSize.Y
		end
	end)

	local h = WIN_H
	local maxH = vh - WIN_GAP_Y * 2
	if maxH < h then
		h = math.max(WIN_MIN_H, maxH)
	end
	WIN_ACTUAL_H = h

	local x = math.max(20, math.floor((vw - WIN_W) / 2))
	local y = math.floor((vh - h) / 2)
	if y < WIN_GAP_Y then y = WIN_GAP_Y end

	return UDim2.new(0, x, 0, y), UDim2.fromOffset(WIN_W, h)
end

Vision._windowRect = windowRect

-- Prefer the tween's own Completed signal; fall back to a timer when the
-- engine (or a stubbed TweenService) will not hand one back.
local function onTweenDone(t, dur, fn)
	if t then
		local conn
		local ok = pcall(function()
			conn = t.Completed:Connect(function()
				if conn then pcall(function() conn:Disconnect() end) end
				pcall(fn)
			end)
		end)
		if ok and conn then return end
	end
	task.delay(dur or 0.2, function()
		pcall(fn)
	end)
end

local function isVisionTagged(inst)
	if not inst then return false end
	local ok, v = pcall(function()
		return inst:GetAttribute("Vision")
	end)
	return ok and v == true
end

local function reducedMotion()
	if not GuiService then return false end
	local ok, v = pcall(function()
		return GuiService.ReducedMotionEnabled
	end)
	return ok and v == true
end

-- ── Menu blur ───────────────────────────────────────────────────────────────
-- A BlurEffect exists only while the UI is up: it ramps in with the loader,
-- follows menu visibility, then tweens to 0 and is destroyed on close, so
-- nothing lingers in Lighting while the menu is shut. We never touch a blur the
-- game already owns -- Roblox applies a single effect of each type, so ours
-- takes precedence while it exists and the game's resumes once it is gone.
local Blur = {
	enabled = true,
	amount = 20,
	-- The stock amount, and whether the consumer pinned one. A theme may suggest
	-- its own blur (Dark Matter eases it off so the starfield reads), but an
	-- explicit Window({ blur = ... }) always wins and is never overridden.
	default = 20,
	explicit = false,
	effect = nil,
	tween = nil,
}

--- Configure from Window({ blur = <number> | false }). Nil leaves the default.
-- `fromTheme` lets a theme suggest a blur without pinning it: only a value the
-- consumer passed themselves marks the setting explicit.
function Vision._blurConfig(v, fromTheme)
	if v == false then
		Blur.explicit = true
		Blur.enabled = false
	elseif type(v) == "number" then
		if not fromTheme then Blur.explicit = true end
		Blur.amount = math.clamp(v, 0, 56)
		Blur.enabled = Blur.amount > 0
	end
end

--- Window({ debug = true }): print the loader's measured dock/dot/flight timings.
function Vision._debugMorph(v)
	Vision._debug = v and true or false
end

local function blurIsOpen()
	return Blur.effect ~= nil and Blur.effect.Parent ~= nil
end

function Vision._blurOpen()
	if not Lighting then return end
	if not Blur.enabled or Blur.amount <= 0 then return end
	if blurIsOpen() then
		-- Already up. Re-parent so ours stays last: if the game added its own
		-- BlurEffect after us, its effect would otherwise take precedence.
		local e = Blur.effect
		pcall(function()
			if e.Parent then
				e.Parent = nil
				e.Parent = Lighting
			end
		end)
		return
	end
	local ok = pcall(function()
		local e = Instance.new("BlurEffect")
		e.Name = "VisionBlur"
		e.Size = 0
		pcall(function() e:SetAttribute("Vision", true) end)
		e.Parent = Lighting
		Blur.effect = e
	end)
	if not ok or not Blur.effect then
		Blur.effect = nil
		return
	end
	if Blur.tween then pcall(function() Blur.tween:Cancel() end) end
	Blur.tween = tween(Blur.effect, { Size = Blur.amount }, 0.4, Enum.EasingStyle.Sine)
end

function Vision._blurClose(instant)
	if Blur.tween then
		pcall(function() Blur.tween:Cancel() end)
		Blur.tween = nil
	end
	local e = Blur.effect
	Blur.effect = nil
	if not e then return end
	if instant or not e.Parent then
		pcall(function() e:Destroy() end)
		return
	end
	local tw = tween(e, { Size = 0 }, 0.3, Enum.EasingStyle.Sine)
	onTweenDone(tw, 0.3, function()
		pcall(function()
			if e.Parent then e:Destroy() end
		end)
	end)
end

--- Called by Window()'s cleanup scan so a re-execute cannot orphan a blur.
function Vision._blurSweep()
	Blur.effect = nil
	if not Lighting then return end
	pcall(function()
		for _, d in ipairs(Lighting:GetChildren()) do
			if d:IsA("BlurEffect") and isVisionTagged(d) then
				d:Destroy()
			end
		end
	end)
end

-- One loader for both marks. The cached-file read is cheap and safe anywhere; the
-- cold path does an HttpGet, so it is memoized and callers run it off the render
-- path. That sharing is what makes the final hand-off invisible: the loader's
-- mark and the window's own logo are always the same image.
--
-- `noFetch` keeps a caller off the network entirely: it will only return an
-- already memoized result or the copy already sitting on disk. Window() uses that
-- form so UI construction can never block on a download.
local logoSrcCache = nil
local logoSrcBusy = false
local function loaderLogoSource(noFetch)
	if logoSrcCache ~= nil then return logoSrcCache end

	local found = nil
	pcall(function()
		local getAsset = customAssetFn()
		if not getAsset then return end
		local file = "vision_logo_v1.png"
		if type(isfile) == "function" and type(readfile) == "function" and isfile(file) then
			local okHead, head = pcall(readfile, file)
			if okHead and type(head) == "string" and string.sub(head, 1, 8) == PNG_MAGIC then
				local okAsset, asset = pcall(getAsset, file)
				if okAsset and asset then found = asset end
			end
		end
	end)
	if found then
		logoSrcCache = found
		return found
	end
	if noFetch then return nil end
	if logoSrcBusy then return nil end
	logoSrcBusy = true

	pcall(function()
		local getAsset = customAssetFn()
		if not getAsset or type(writefile) ~= "function" then return end
		local file = "vision_logo_v1.png"
		local okGet, body = pcall(function() return game:HttpGet(LOGO_URL) end)
		if okGet and type(body) == "string" and string.sub(body, 1, 8) == PNG_MAGIC then
			pcall(writefile, file, body)
			local okAsset, asset = pcall(getAsset, file)
			if okAsset and asset then found = asset end
		end
	end)

	logoSrcBusy = false
	-- Only successes are cached: a transient network failure can still recover
	-- on a later call instead of leaving both marks blank for the whole session.
	if found then logoSrcCache = found end
	return found
end

--- Destroy any previous loader immediately, without animating.
function Vision._loaderReset()
	local L = Vision._loader
	if not L then return end
	Vision._loader = nil
	L.alive = false
	L.dead = true
	if L.conn then
		pcall(function() L.conn:Disconnect() end)
		L.conn = nil
	end
	pcall(function()
		if L.gui and L.gui.Parent then L.gui:Destroy() end
	end)
end

--- True while a loader stage is alive on screen.
function Vision._loaderAlive()
	local L = Vision._loader
	return L ~= nil and L.alive == true
end

--- Show the loader. Called by Window() before any build work.
function Vision._loaderBegin(opts)
	if type(opts) == "table" and opts.loader == false then return end
	Vision._loaderReset()

	local host = getGuiParent()
	if not host then return end

	local title = "VISION"
	if type(opts) == "table" then
		if type(opts.loaderTitle) == "string" and opts.loaderTitle ~= "" then
			title = opts.loaderTitle
		end
	end

	local L = {
		alive = true,
		dead = false,
		stage = 1,          -- 1 mark, 2 dots, 3 flying, 0 done
		dotT0 = nil,
		born = os.clock(),
		minTime = LOADER_HOLD,
		reduced = reducedMotion(),
	}
	if type(opts) == "table" and type(opts.loaderMinTime) == "number" then
		L.minTime = math.max(0, opts.loaderMinTime)
	end
	Vision._loader = L

	local ok = pcall(function()
		L.gui = make("ScreenGui", {
			Name = "VisionLoader",
			ResetOnSpawn = false,
			IgnoreGuiInset = true,   -- stage offsets are therefore screen pixels
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			DisplayOrder = 1000,     -- above the window's 999, so the flight shows
			Parent = host,
		})

		-- Transparent full-screen stage. Its children are placed in screen
		-- pixels, which is what lets the mark fly anywhere at the end. Never
		-- Active, so it cannot swallow a click.
		L.stageFrame = make("Frame", {
			Name = "Stage",
			Position = UDim2.fromOffset(0, 0),
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ClipsDescendants = false,
			Active = false,
			ZIndex = 1,
			Parent = L.gui,
		})

		L.mark = make("ImageLabel", {
			Name = "Mark",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, -16),
			Size = UDim2.fromOffset(LOADER_LOGO, LOADER_LOGO),
			BackgroundTransparency = 1,
			ScaleType = Enum.ScaleType.Fit,
			ImageTransparency = 1,
			Active = false,
			ZIndex = 11,
			Parent = L.stageFrame,
		})
		-- Monogram placeholder: the mark is blank until the async logo fetch
		-- resolves, which would make a first run look broken.
		L.mono = make("TextLabel", {
			Name = "Monogram",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, -16),
			Size = UDim2.fromOffset(LOADER_LOGO, LOADER_LOGO),
			BackgroundTransparency = 1,
			Font = FONT_BOLD,
			Text = string.sub(title, 1, 1),
			TextSize = 28,
			TextColor3 = Theme.TextMid,
			TextTransparency = 1,
			Active = false,
			ZIndex = 11,
			Parent = L.stageFrame,
		})

		-- Progress bar: a faint rounded track with a brighter pill that sweeps
		-- left to right once per pass. The render loop below is its only writer, so
		-- the pass can never be driven twice at once. The pill starts fully
		-- transparent and off to the left, so nothing flashes before the pass.
		L.bar = make("Frame", {
			Name = "LoadBar",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, LOADER_BAR_DROP),
			Size = UDim2.fromOffset(LOADER_BAR_W, LOADER_BAR_H),
			BackgroundColor3 = Theme.ControlBorder,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Visible = false,
			Active = false,
			ZIndex = 12,
			Parent = L.stageFrame,
		})
		corner(L.bar, LOADER_BAR_H)
		L.pill = make("Frame", {
			Name = "LoadPill",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0),
			Size = UDim2.fromOffset(LOADER_PILL_W, LOADER_BAR_H),
			BackgroundColor3 = Theme.Accent,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = 13,
			Parent = L.bar,
		})
		corner(L.pill, LOADER_BAR_H)
	end)

	if not ok or not L.mark then
		Vision._loaderReset()
		return
	end

	-- Belt and braces: the loader must never capture mouse or gamepad input.
	pcall(function()
		for _, o in ipairs({ L.stageFrame, L.mark, L.mono }) do
			if o then
				o.Active = false
				pcall(function() o.Selectable = false end)
			end
		end
		for _, o in ipairs({ L.bar, L.pill }) do
			if o then
				o.Active = false
				pcall(function() o.Selectable = false end)
			end
		end
	end)

	-- Soft halo behind the mark. It prefers a sprite when one is available and
	-- otherwise falls back to stepped strokes, so the glow always renders with
	-- no asset dependency at all. It follows the mark until the flight starts,
	-- then dissipates so the landing is crisp.
	pcall(function()
		local framePad = 13
		local glow = make("Frame", {
			Name = "Glow",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, -16),
			Size = UDim2.fromOffset(LOADER_LOGO + framePad * 2, LOADER_LOGO + framePad * 2),
			BackgroundTransparency = 1,
			Active = false,
			ZIndex = 9,
			Parent = L.stageFrame,
		})
		L.glow = glow
		L.glowItems = {}

		-- Created with no image and filled in off the render path: the sprite
		-- download must never delay the loader's first frame. The stepped
		-- strokes below need no asset at all, so the glow is never blank.
		local halo = make("ImageLabel", {
			Name = "Halo",
			Position = UDim2.new(0, -28, 0, -28),
			Size = UDim2.new(1, 56, 1, 56),
			BackgroundTransparency = 1,
			ImageColor3 = Theme.Accent,
			ImageTransparency = 1,
			ScaleType = Enum.ScaleType.Stretch,
			ZIndex = 9,
			Parent = glow,
		})
		L.glowItems[#L.glowItems + 1] = { obj = halo, prop = "ImageTransparency", base = 0.66, amp = 0.12 }
		loadImageAsync(halo, GLOW_FILE, L)

		for i, step in ipairs({ { 3, 7, 0.90 }, { 8, 6, 0.945 }, { 13, 5, 0.972 } }) do
			local haloPad = step[1]
			local halo = make("Frame", {
				Name = "Halo" .. i,
				Position = UDim2.new(0, -haloPad, 0, -haloPad),
				Size = UDim2.new(1, haloPad * 2, 1, haloPad * 2),
				BackgroundTransparency = 1,
				Active = false,
				ZIndex = 9,
				Parent = glow,
			})
			corner(halo, 6 + haloPad)
			local s = stroke(halo, Theme.Accent, step[3])
			s.Thickness = step[2]
			L.glowItems[#L.glowItems + 1] = { obj = s, prop = "Transparency", base = step[3], amp = 0.06 }
		end
	end)

	-- Fade up, no scale bounce. Everything starts fully transparent so there is
	-- no flash of the final state.
	tween(L.mark, { ImageTransparency = 0 }, 0.3, Enum.EasingStyle.Quad)
	if L.mono then tween(L.mono, { TextTransparency = 0 }, 0.3, Enum.EasingStyle.Quad) end

	-- The render loop is the single writer for the halo and the dot pass.
	if RunService then
		L.conn = RunService.RenderStepped:Connect(function(dt)
			if L.dead or Vision._loader ~= L then return end
			local now = os.clock()

			-- Halo tracks the mark and breathes until the flight starts.
			if L.glow and L.glowItems and not L.glowOff then
				pcall(function()
					local ap, as = L.mark.AbsolutePosition, L.mark.AbsoluteSize
					L.glow.Position = UDim2.fromOffset(ap.X - as.X * 0.5, ap.Y - as.Y * 0.5)
					L.glow.Size = UDim2.fromOffset(as.X, as.Y)
				end)
				local pulse = L.reduced and 0 or (0.5 + 0.5 * math.sin(now * 2.2))
				for _, it in ipairs(L.glowItems) do
					pcall(function()
						it.obj[it.prop] = math.clamp(it.base - pulse * it.amp, 0, 1)
					end)
				end
			end

			-- Exactly one up-and-down per dot, staggered, driven off the wall
			-- clock so the whole pass lasts LOADER_DOT_TIME at any frame rate.
			if L.stage == 2 and L.dotT0 then
				local el = now - L.dotT0
				local fade = math.clamp(math.min(el, LOADER_DOT_TIME - el) / 0.14, 0, 1)
				-- One sweep, left to right, across the whole pass. The pill is offset
				-- by its own width as it travels, so it lands exactly on the right
				-- edge as the pass ends instead of hanging past it.
				local u = math.clamp(el / LOADER_DOT_TIME, 0, 1)
				pcall(function()
					if L.bar then L.bar.BackgroundTransparency = 1 - fade * 0.75 end
					if L.pill then
						L.pill.Position = UDim2.new(u, -LOADER_PILL_W * u, 0.5, 0)
						L.pill.BackgroundTransparency = 1 - fade
					end
				end)
				if el >= LOADER_DOT_TIME then
					L.stage = 3
					pcall(function()
						if L.bar then L.bar.Visible = false end
						if L.pill then L.pill.Visible = false end
					end)
					L.glowOff = true
					if L.glowItems then
						for _, it in ipairs(L.glowItems) do
							pcall(function() tween(it.obj, { [it.prop] = 1 }, 0.18, Enum.EasingStyle.Quad) end)
						end
					end
					local fly = L.startFlight
					L.startFlight = nil
					if fly then pcall(fly) end
				end
			end
		end)
	end

	-- Mark loads off the render path so it can never delay the build.
	task.spawn(function()
		local src = loaderLogoSource()
		if src and not L.dead and L.mark and L.mark.Parent then
			pcall(function() L.mark.Image = src end)
			pcall(function()
				if L.mono then L.mono.Visible = false end
			end)
		end
	end)

	-- Ramp the scene blur in with the mark.
	pcall(Vision._blurOpen)
end

--- Kept for consumer compatibility. The loader no longer draws a progress bar,
--- so reported phases have nowhere to go: Vision._loaderStep(p, label) is now a
--- no-op and is safe to call as often as you like.
function Vision._loaderStep(p, label)
	return
end

-- Fallback reveal for a window that never had a loader: show it and settle it
-- in with a short pop. Only reached when _loaderEnd is called without a reveal fn.
local function revealWindow(win)
	if not (win and win.Parent) then return end
	pcall(function()
		win.Visible = true
		local sc = win:FindFirstChildOfClass("UIScale")
		if not sc then
			sc = make("UIScale", { Parent = win })
		end
		sc.Scale = 0.97
		tween(sc, { Scale = 1 }, 0.28, Enum.EasingStyle.Quint)
	end)
end

--- Called by Window() once the build is done. The order is the whole point:
--- After LOADER_HOLD, `chromeFn` docks the window's chrome (never its tab pages)
--- underneath the centered mark and reports where the window's own logo sits,
--- then the dots bounce once, then the mark flies onto that exact slot and
--- `revealFn` takes over. Called without a window (manual replay) the mark just
--- dissolves.
--- Either way nothing is left behind.
function Vision._loaderEnd(target, revealFn, chromeFn)
	local L = Vision._loader
	local reveal = revealFn or revealWindow
	if not L or not L.alive then
		reveal(target)
		return
	end

	-- Public liveness goes false right away: Window() reads it to decide whether
	-- it still has to open the blur. The render loop guards on L.dead instead,
	-- so the intro below keeps animating.
	L.alive = false

	local win = target
	local finished = false

	local function finish()
		if finished or L.dead then return end
		finished = true
		-- Reveal first, and hand the mark over with the window: doReveal adopts
		-- the mark's sprite when the window's own logo has not resolved yet, so
		-- nothing is hidden before that swap has had its chance. Hiding first
		-- could blink the logo out of existence on a cold cache.
		pcall(reveal, win, L.mark)
		if L.mark then pcall(function() L.mark.Visible = false end) end
		if L.mono then pcall(function() L.mono.Visible = false end) end
		-- Window({ debug = true }) still reports the intro, now as measured
		-- timings rather than a morph delta.
		if Vision._debug then
			pcall(function()
				local now = os.clock()
				local base = L.born or now
				print(string.format(
					"[Vision] loader: dock=%.3fs bar=%.3fs fly=%.3fs total=%.3fs",
					(L.dockAt or now) - base,
					(L.dotsAt or now) - (L.dockAt or now),
					now - (L.dotsAt or now),
					now - base
				))
			end)
		end
		L.dead = true
		L.stage = 0
		if L.conn then
			pcall(function() L.conn:Disconnect() end)
			L.conn = nil
		end
		if Vision._loader == L then Vision._loader = nil end
		pcall(function()
			local gui = L.gui
			if gui and gui.Parent then gui:Destroy() end
		end)
	end

	-- The landing slot is re-resolved at flight time through chromeFn's
	-- resolver, not here, so a window the user dragged -- or a client that got
	-- resized -- during the hold still gets the mark on its real logo slot, at
	-- the real size. What chromeFn measured at dock time is the initial value.
	local rect = nil
	local resolveRect = nil

	local function fly()
		if L.dead or not (L.mark and L.mark.Parent) then
			finish()
			return
		end
		-- Re-resolved through chromeFn's resolver at this exact instant, so the mark
		-- lands on the logo's real absolute rect -- not on a rect that was true back
		-- when the chrome docked. A drag, or a client resize, during the intro is
		-- therefore followed rather than missed.
		if type(resolveRect) == "function" then
			pcall(function()
				local fresh = resolveRect()
				if fresh then rect = fresh end
			end)
		end
		-- The measured logo rect wins, so both the landing position AND the landing
		-- size come from the logo itself. The computed slot below is only for a
		-- window that cannot report its layout yet: the logo sits at
		-- (MARGIN + 2, TOPBAR_H / 2) inside the window rect, with both ScreenGuis
		-- ignoring the top bar inset, so either way these are plain screen pixels.
		local tx, ty, tw, th = nil, nil, LOADER_LAND, LOADER_LAND
		if type(rect) == "table" and tonumber(rect[1]) and tonumber(rect[2])
			and tonumber(rect[3]) and tonumber(rect[3]) > 1 then
			tx, ty, tw, th = rect[1], rect[2], rect[3], rect[4]
		end
		if not (tonumber(tx) and tonumber(ty)) and win and win.Parent then
			pcall(function()
				local wp = win.AbsolutePosition
				tx, ty = wp.X + MARGIN + 2, wp.Y + TOPBAR_H / 2 - LOADER_LAND / 2
			end)
		end
		if not (tonumber(tx) and tonumber(ty)) then
			finish()
			return
		end
		tw = tonumber(tw) or LOADER_LAND
		th = tonumber(th) or LOADER_LAND
		-- AnchorPoint stays (0.5, 0.5), so the goal position is the rect center
		-- and Position and Size can be tweened together without a nudge.
		local goalPos = UDim2.fromOffset(math.floor(tx + tw * 0.5), math.floor(ty + th * 0.5))
		local goalSize = UDim2.fromOffset(math.floor(tw), math.floor(th))
		local flyTween
		if TweenService then
			pcall(function()
				flyTween = TweenService:Create(
					L.mark,
					TweenInfo.new(LOADER_FLY, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
					{ Position = goalPos, Size = goalSize }
				)
				flyTween:Play()
			end)
		end
		if not flyTween then
			pcall(function()
				L.mark.Position = goalPos
				L.mark.Size = goalSize
			end)
		end
		onTweenDone(flyTween, LOADER_FLY, finish)
	end

	-- Docking lives here, at the END of the dot pass, and that order is the
	-- whole point. Docking first meant the window sat fully faded in and empty
	-- for the entire dot pass -- a finished-looking shell with nothing inside it
	-- -- which is the dead beat that made the intro feel broken. Now the mark and
	-- its dots play over a clean stage, the chrome fades in as the mark leaves
	-- for the logo, and the first tab follows the landing.
	local docked = false
	local function dock()
		if docked or L.dead then return end
		docked = true
		pcall(function() rect, resolveRect = chromeFn(win) end)
		L.dockAt = os.clock()
	end

	local function dockThenFly()
		if L.dead or finished then return end
		if not docked then dock() end
		-- The logo's live rect can only be read once the window is visible and a
		-- frame has laid it out, so the flight waits one beat after the dock.
		-- That is exactly what LOADER_DOCK_WAIT is for, and why the dock cannot
		-- simply run in the same frame as the flight.
		task.delay(LOADER_DOCK_WAIT, fly)
	end

	local function runDots()
		if L.dead or finished then return end
		if not (L.mark and L.mark.Parent) then
			finish()
			return
		end
		L.startFlight = dockThenFly
		pcall(function()
			if L.bar then L.bar.Visible = true end
			if L.pill then L.pill.Visible = true end
		end)
		L.dotT0 = os.clock()
		L.dotsAt = L.dotT0
		L.stage = 2
	end

	-- How long the mark is held centered before the UI shows at all. LOADER_HOLD
	-- is the floor; a slow build can only make it longer, never shorter.
	local dwell = 0
	pcall(function()
		dwell = math.max(0, (L.minTime or 0) - (os.clock() - (L.born or os.clock())))
	end)

	if type(chromeFn) ~= "function" then
		-- Nothing to dock (manual replay): let the mark dissolve instead.
		task.delay(dwell, function()
			if L.dead then return end
			L.glowOff = true
			if L.glowItems then
				for _, it in ipairs(L.glowItems) do
					pcall(function() tween(it.obj, { [it.prop] = 1 }, 0.2, Enum.EasingStyle.Quad) end)
				end
			end
			if L.mark then tween(L.mark, { ImageTransparency = 1 }, 0.24, Enum.EasingStyle.Quad) end
			if L.mono then tween(L.mono, { TextTransparency = 1 }, 0.24, Enum.EasingStyle.Quad) end
			task.delay(0.26, finish)
		end)
		task.delay(dwell + 0.6, finish)
		return
	end

	-- Hold the mark centered on the clean stage, play the dot pass there, and only
	-- then dock the chrome underneath it and fly it onto the window's own logo.
	task.delay(dwell, runDots)
	-- Watchdog: if the render loop never reports (no RunService, or an error part
	-- way through), hand off anyway instead of leaving the stage on screen.
	task.delay(dwell + LOADER_DOT_TIME + LOADER_DOCK_WAIT + LOADER_FLY + 1.2, finish)
end

local function keyName(keyCode)
	if not keyCode then return "None" end
	local ok, enumType = pcall(function() return keyCode.EnumType end)
	if ok and enumType == Enum.UserInputType then
		local mousePretty = {
			MouseButton1 = "LMB",
			MouseButton2 = "RMB",
			MouseButton3 = "MMB",
		}
		return mousePretty[keyCode.Name] or keyCode.Name
	end
	local pretty = {
		LeftShift = "LShift", RightShift = "RShift",
		LeftControl = "LCtrl", RightControl = "RCtrl",
		LeftAlt = "LAlt", RightAlt = "RAlt",
		Insert = "Insert", Delete = "Delete",
		MouseButton1 = "LMB", MouseButton2 = "RMB", MouseButton3 = "MMB",
		KeypadZero = "Num 0", KeypadOne = "Num 1", KeypadTwo = "Num 2",
		KeypadThree = "Num 3", KeypadFour = "Num 4", KeypadFive = "Num 5",
		KeypadSix = "Num 6", KeypadSeven = "Num 7", KeypadEight = "Num 8",
		KeypadNine = "Num 9",
		MB1 = "LMB", MB2 = "RMB", MB3 = "MMB",
	}
	return pretty[keyCode.Name] or keyCode.Name
end

local function parseKeyString(s)
	if type(s) ~= "string" or s == "" or s == "None" then return nil end
	if s == "MB1" or s == "LMB" then return Enum.UserInputType.MouseButton1 end
	if s == "MB2" or s == "RMB" then return Enum.UserInputType.MouseButton2 end
	if s == "MB3" or s == "MMB" then return Enum.UserInputType.MouseButton3 end
	local ok, kc = pcall(function() return Enum.KeyCode[s] end)
	if ok and kc then return kc end
	local ok2, mt = pcall(function() return Enum.UserInputType[s] end)
	if ok2 and mt then return mt end
	return nil
end

local function keyStorageName(key)
	if not key then return "None" end
	local ok, enumType = pcall(function() return key.EnumType end)
	if ok and enumType == Enum.UserInputType then
		if key == Enum.UserInputType.MouseButton1 then return "MB1" end
		if key == Enum.UserInputType.MouseButton2 then return "MB2" end
		if key == Enum.UserInputType.MouseButton3 then return "MB3" end
		return key.Name
	end
	return key.Name
end

local function keysMatch(a, input)
	-- a is bound EnumItem (KeyCode or MouseButton), input is UserInputService InputObject
	if not a or not input then return false end
	local ok, enumType = pcall(function() return a.EnumType end)
	if ok and enumType == Enum.UserInputType then
		return input.UserInputType == a
	end
	return input.KeyCode == a
end

local CONFIG_FOLDER = "Vision"
local function canFile()
	return type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
end

local function ensureFolder()
	if type(isfolder) == "function" and type(makefolder) == "function" then
		pcall(function()
			if not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end
			if not isfolder(CONFIG_FOLDER .. "/configs") then makefolder(CONFIG_FOLDER .. "/configs") end
		end)
	end
end

function Vision.Window(opts)
	opts = opts or {}
	local self = {}
	local title = opts.title or "VISION"
	local menuKey = opts.keybind or Enum.KeyCode.Insert

	-- Apply a custom accent override if passed via opts (derive matching dark/header so theme stays clean)
	if opts.accent and typeof(opts.accent) == "Color3" then
		Theme.Accent = opts.accent
		local h, s, v = opts.accent:ToHSV()
		Theme.AccentDark = Color3.fromHSV(h, math.min(1, s * 0.95 + 0.05), math.clamp(v * 0.42, 0.12, 0.5))
		Theme.HeaderMid = Color3.fromHSV(h, math.clamp(s * 0.55, 0.2, 0.7), math.clamp(v * 0.62 + 0.12, 0.3, 0.65))
		currentThemeName = "Custom"
	end

	-- Blur amount, applied before the loader so it ramps in with the mark.
	if type(opts) == "table" then
		Vision._blurConfig(opts.blur)
		if opts.debug ~= nil then Vision._debugMorph(opts.debug) end
	end

	-- Loading screen up before any build work, so the cleanup scan, autosave
	-- read and widget construction all happen behind it. It lives here rather
	-- than in consumer scripts because only the library knows when that work
	-- is actually finished.
	if type(opts) == "table" and opts.loader == false then
		Vision._loaderReset()
	end
	-- Before anything can create one: a re-execute must not orphan a blur, and
	-- this has to run ahead of the loader, which opens its own on the way up.
	pcall(Vision._blurSweep)
	pcall(Vision._loaderBegin, opts)

	-- ================================================================
	-- Cleanup: destroy any existing Vision UI before creating a new one
	-- ================================================================
	local function _scanAndDestroy(parent)
		if not parent then return end
		for _, child in ipairs(parent:GetChildren()) do
			local ok1 = pcall(function()
				if child:GetAttribute("Vision") == true then
					child:Destroy()
				end
			end)
			local ok2 = pcall(function()
				_scanAndDestroy(child)
			end)
		end
	end
	pcall(function()
		for _, finder in ipairs({ gethui, get_hidden_gui }) do
			if type(finder) == "function" then
				local ok, container = pcall(finder)
				if ok and container then _scanAndDestroy(container) end
			end
		end
	end)
	pcall(function()
		if CoreGui then _scanAndDestroy(CoreGui) end
		local lp = localPlayer()
		if lp then _scanAndDestroy(lp:FindFirstChildOfClass("PlayerGui")) end
	end)
	-- Also destroy any stored reference from previous Window calls
	if Vision._activeGui then
		pcall(function() Vision._activeGui.Folder:Destroy() end)
		Vision._activeGui = nil
	end

	-- ================================================================
	-- Hide: nest ScreenGui inside a random-named Folder deep in gethui
	-- ================================================================
	local parent = getGuiParent()
	local rng = Random.new()
	local hex = string.format("%08X", rng:NextInteger(0, 4294967295))
	local folderName = "LocaleData_" .. hex
	local folder = Instance.new("Folder")
	folder.Name = folderName
	folder.Parent = parent
	pcall(function()
		folder:SetAttribute("Vision", true)
	end)

	local screen = make("ScreenGui", {
		Name = "Gui_" .. hex,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 999,
	})
	pcall(function()
		screen:SetAttribute("Vision", true)
	end)
	protectGui(screen)
	screen.Parent = folder
	self.Gui = screen
	Vision._activeGui = { Screen = screen, Folder = folder }

	local conns = {}
	local function trackConn(c)
		conns[#conns + 1] = c
		return c
	end
	local themeRepaints = {}
	local function registerRepaint(fn)
		themeRepaints[#themeRepaints + 1] = fn
	end
	local destroyCallbacks = {}
	local function onDestroy(fn)
		destroyCallbacks[#destroyCallbacks + 1] = fn
	end
	local keybindListenCancel = nil
	local anyListening = false
	local attachElements
	local openHuePopup
	local popupCleanup
	local destroyed = false
	local revealed = false
	local chromeDone = false
	local pendingTab = nil

	local flagBinds = {}
	local function bindFlag(flag, setter, getter)
		if flag and flag ~= "" then
			flagBinds[flag] = { set = setter, get = getter }
		end
	end

	-- ================================================================
	-- Cursor ownership
	-- ----------------------------------------------------------------
	-- Games hold the mouse locked to the centre -- Roblox's own first-person
	-- camera re-locks it every frame -- so a menu in first person is stuck
	-- staring at the crosshair with no usable pointer. While the menu is open
	-- the cursor is freed: movable, icon shown. The exact mouse state captured
	-- when it was freed is put back on close, so a first-person game gets its
	-- lock back and a game that never locked does not suddenly acquire one.
	-- ================================================================
	local cursorSaved = nil     -- mouse state captured at the open that freed it
	local cursorWanted = false  -- whether the menu currently wants a free cursor
	local function cursorUnlock()
		if destroyed or not UserInputService then return end
		if cursorSaved == nil then
			cursorSaved = {
				behavior = UserInputService.MouseBehavior,
				icon = UserInputService.MouseIconEnabled,
			}
		end
		pcall(function()
			if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			end
			if not UserInputService.MouseIconEnabled then
				UserInputService.MouseIconEnabled = true
			end
		end)
	end
	local function cursorRestore()
		if not UserInputService or cursorSaved == nil then return end
		local saved = cursorSaved
		cursorSaved = nil
		pcall(function()
			UserInputService.MouseBehavior = saved.behavior
			UserInputService.MouseIconEnabled = saved.icon
		end)
	end

	function self.Destroy()
		if destroyed then return end
		destroyed = true
		pcall(cursorRestore)
		pcall(Vision._blurClose, true)
		pcall(function() Vision._forceSave() end)
		for _, fn in ipairs(destroyCallbacks) do
			pcall(fn)
		end
		if popupCleanup then
			pcall(popupCleanup)
			popupCleanup = nil
		end
		if keybindListenCancel then
			pcall(keybindListenCancel)
			keybindListenCancel = nil
		end
		for _, c in ipairs(conns) do
			pcall(function() c:Disconnect() end)
		end
		conns = {}
		flagBinds = {}
		pcall(function() folder:Destroy() end)
		if Vision._activeGui and Vision._activeGui.Folder == folder then
			Vision._activeGui = nil
		end
	end
	onDestroy(function()
		-- Clear global save hook if it belongs to this window (prevents dead saves after re-execute)
		-- Note: doSave is assigned later; _saveFunc is overwritten on next Window(), so just force one last save above.
	end)

	local winPos, winSize = windowRect()
	local win = make("Frame", {
		Name = "Window",
		Position = winPos,
		Size = winSize,
		BackgroundColor3 = Theme.WindowBg,
		BorderSizePixel = 0,
		Parent = screen,
	})
	corner(win, 6)
	stroke(win, Theme.ControlBorder, 0.4)

	-- Theme backdrop (Dark Matter's space image). Built first and at ZIndex 0
	-- against the default 1, so it sits under every other child; its own UICorner
	-- keeps the image inside the window's radius even though the window itself is
	-- never clipped (the stats card hangs off its edge and must not be cut).
	-- Non-backdrop themes simply hide both layers.
	local bgImage = make("ImageLabel", {
		Name = "ThemeBackdrop",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Image = Theme.BgImage or "",
		ImageTransparency = Theme.BgImageTransparency or 0,
		ScaleType = Enum.ScaleType.Crop,
		Visible = Theme.BgImage ~= nil,
		ZIndex = 0,
		Parent = win,
	})
	corner(bgImage, 6)
	-- A dark scrim over the image: the space shot is bright enough in places that
	-- raw text over it would be hard to read. This is what keeps it premium.
	local bgScrim = make("Frame", {
		Name = "ThemeScrim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.WindowBg,
		BackgroundTransparency = Theme.Scrim or 0,
		BorderSizePixel = 0,
		Visible = Theme.BgImage ~= nil,
		ZIndex = 0,
		Parent = win,
	})
	corner(bgScrim, 6)

	-- Visibility is owned by doReveal at the end of this function. Nothing is
	-- shown before the first tab's entrance animation can actually be seen.
	win.Visible = false

	local topbar = make("Frame", {
		Name = "Topbar",
		Size = UDim2.new(1, 0, 0, TOPBAR_H),
		BackgroundTransparency = 1,
		-- Required by the drag below: a Frame only raises InputBegan while it is
		-- Active, so without this the whole window is undraggable.
		Active = true,
		Parent = win,
	})
	make("Frame", {
		Name = "TopDivider",
		Position = UDim2.new(0, MARGIN, 0, TOPBAR_H - 1),
		Size = UDim2.new(1, -MARGIN * 2, 0, 1),
		BackgroundColor3 = Theme.ControlBorder,
		BorderSizePixel = 0,
		Parent = win,
	})

	local logo = make("ImageLabel", {
		Name = "Logo",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, MARGIN + 2, 0.5, 0),
		Size = UDim2.new(0, 30, 0, 30),
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Fit,
		Parent = topbar,
	})
-- Tracked separately from Image itself: the async fetch, the on-disk copy
-- and the loader hand-off all write the logo, and the reveal needs to know
-- whether any of them actually landed.
local logoHasImage = false
-- Load logo. loaderLogoSource(true) is the never-blocks form: it reads only
-- the memo and the copy already on disk, so a cold cache cannot stall window
-- construction (and with it the loader's intro) behind a download.
local logoReady = loaderLogoSource(true)
if logoReady then
	pcall(function() logo.Image = logoReady end)
	logoHasImage = true
else
	-- Cold cache. The loader mark is fetching this same file right now, and
	-- that fetch is deliberately single-flight: a second caller arriving
	-- while it is in flight gets nil rather than a queue slot. So wait for
	-- the cache to warm instead of racing it -- this is what keeps the
	-- hand-off byte-identical. noFetch=true makes each poll a plain isfile
	-- check, so the polling can never start a download of its own. LOGO_URL
	-- remains the last resort, and is only reached once the wait is over.
	task.spawn(function()
		local src = nil
		for _ = 1, 60 do
			src = loaderLogoSource(true)
			if src then break end
			task.wait(0.05)
		end
		if not src then src = loaderLogoSource() end
		pcall(function()
			if logo and logo.Parent then
				logo.Image = src or LOGO_URL
				logoHasImage = true
			end
		end)
	end)
end

	make("Frame", {
		Name = "LogoDivider",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, MARGIN + 44, 0.5, 0),
		Size = UDim2.new(0, 1, 0, 30),
		BackgroundColor3 = Theme.ControlBorder,
		BorderSizePixel = 0,
		Parent = topbar,
	})

	-- Search icon
	local searchIcon = make("ImageLabel", {
		Name = "SearchIcon",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, MARGIN + 58, 0.5, 0),
		Size = UDim2.new(0, 14, 0, 14),
		BackgroundTransparency = 1,
		Image = "rbxassetid://7733960988",
		ImageColor3 = Theme.TextDim,
		ScaleType = Enum.ScaleType.Fit,
		Parent = topbar,
	})

	local searchBox = make("TextBox", {
		Name = "SearchBox",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, MARGIN + 78, 0.5, 0),
		Size = UDim2.new(0, 96, 0, 24),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = "",
		PlaceholderText = "Search...",
		PlaceholderColor3 = Theme.TextDim,
		TextSize = TEXT,
		TextColor3 = Theme.TextBright,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Parent = topbar,
	})

	-- Horizontal scrollable tab navigation
	local NAV_START_X = MARGIN + 188  -- after logo + divider + search
	local tabScroll = make("ScrollingFrame", {
		Name = "TabScroll",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, NAV_START_X, 0.5, 0),
		Size = UDim2.new(1, -NAV_START_X - MARGIN, 0, TOPBAR_H - 4),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		Parent = topbar,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 24),
		Parent = tabScroll,
	})
	make("UIPadding", {
		PaddingTop = UDim.new(0, 4),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
		Parent = tabScroll,
	})

	local content = make("Frame", {
		Name = "Content",
		Position = UDim2.new(0, 0, 0, TOPBAR_H),
		Size = UDim2.new(1, 0, 1, -TOPBAR_H - FOOTER_H),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Parent = win,
	})

	local footer = make("Frame", {
		Name = "Footer",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, FOOTER_H),
		BackgroundTransparency = 1,
		Parent = win,
	})
	-- Footer bar
	make("Frame", {
		Position = UDim2.new(0, MARGIN, 0, 0),
		Size = UDim2.new(1, -MARGIN * 2, 0, 1),
		BackgroundColor3 = Theme.ControlBorder,
		BorderSizePixel = 0,
		Parent = footer,
	})
	-- Footer globe icon
	local globe = make("ImageLabel", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, MARGIN, 0.5, 0),
		Size = UDim2.new(0, 13, 0, 13),
		BackgroundTransparency = 1,
		Image = "rbxassetid://92188766517878",
		ImageColor3 = Theme.TextDim,
		ScaleType = Enum.ScaleType.Fit,
		Parent = footer,
	})
	make("TextLabel", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, MARGIN + 19, 0.5, 0),
		Size = UDim2.new(0, 160, 1, 0),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = opts.footerText or ("Vision v" .. Vision.Version),
		TextSize = 12,
		TextColor3 = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = footer,
	})
	-- Key expiry timer (centered in footer, shown only when Keysystem is enabled)
	local keyTimerLbl = nil
	if opts.Keysystem then
		keyTimerLbl = make("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.new(0, 140, 1, 0),
			BackgroundTransparency = 1,
			Font = FONT,
			Text = "Key:24h",
			TextSize = 12,
			TextColor3 = Theme.TextDim,
			Parent = footer,
		})
	end

	local menuKeyLbl = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -MARGIN, 0.5, 0),
		Size = UDim2.new(0, 200, 1, 0),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = "Key: " .. keyName(menuKey),
		TextSize = 12,
		TextColor3 = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		AutoButtonColor = false,
		Parent = footer,
	})

	-- Clean clickable menu-key rebind (bottom-right). Click -> "Key: .." -> press any key.
	local menuKeyListening = false
	local function stopMenuKeyListening()
		menuKeyListening = false
		if keybindListenCancel == stopMenuKeyListening then
			keybindListenCancel = nil
		end
		task.defer(function()
			anyListening = false
		end)
		pcall(function()
			menuKeyLbl.Text = "Key: " .. keyName(menuKey)
			tween(menuKeyLbl, { TextColor3 = Theme.TextDim }, 0.12)
		end)
	end
	menuKeyLbl.MouseEnter:Connect(function()
		if not menuKeyListening then
			tween(menuKeyLbl, { TextColor3 = Theme.TextBright }, 0.1)
		end
	end)
	menuKeyLbl.MouseLeave:Connect(function()
		if not menuKeyListening then
			tween(menuKeyLbl, { TextColor3 = Theme.TextDim }, 0.12)
		end
	end)
	menuKeyLbl.MouseButton1Click:Connect(function()
		if menuKeyListening then
			stopMenuKeyListening()
			return
		end
		if keybindListenCancel then
			pcall(keybindListenCancel)
		end
		menuKeyListening = true
		keybindListenCancel = stopMenuKeyListening
		anyListening = true
		menuKeyLbl.Text = "Key: .."
		tween(menuKeyLbl, { TextColor3 = Theme.Accent }, 0.1)
	end)
	trackConn(UserInputService.InputBegan:Connect(function(input, processed)
		if not menuKeyListening then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		if processed then return end
		local kc = input.KeyCode
		if kc == Enum.KeyCode.Escape then
			stopMenuKeyListening()
			return
		end
		if kc and kc ~= Enum.KeyCode.Unknown then
			menuKey = kc
			Vision.Flags["menu_key"] = kc.Name
			Vision._scheduleSave()
			menuKeyLbl.Text = "Key: " .. keyName(menuKey)
		end
		stopMenuKeyListening()
	end))
	-- Init menu key: explicit opts.keybind wins, else restore saved flag (no disk write)
	if opts.keybind and typeof(opts.keybind) == "EnumItem" then
		menuKey = opts.keybind
		Vision.Flags["menu_key"] = menuKey.Name
		menuKeyLbl.Text = "Key: " .. keyName(menuKey)
	elseif type(Vision.Flags["menu_key"]) == "string" and Vision.Flags["menu_key"] ~= "" then
		pcall(function()
			local kc = Enum.KeyCode[Vision.Flags["menu_key"]]
			if kc then
				menuKey = kc
				menuKeyLbl.Text = "Key: " .. keyName(menuKey)
			end
		end)
	else
		if Vision.Flags["menu_key"] == nil then
			Vision.Flags["menu_key"] = menuKey.Name
		end
	end

	local overlay = make("Frame", {
		Name = "Overlay",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 50,
		Parent = win,
	})
	local overlayBlock = make("TextButton", {
		Name = "Block",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 50,
		Parent = overlay,
	})
	local overlayContent = nil
	local overlayOwnerClose = nil

	local function closeOverlay()
		if overlayContent then
			overlayContent:Destroy()
			overlayContent = nil
		end
		overlay.Visible = false
		if overlayOwnerClose then
			local cb = overlayOwnerClose
			overlayOwnerClose = nil
			cb()
		end
	end

	local function openOverlay(buildFn, onClose)
		closeOverlay()
		overlayOwnerClose = onClose
		overlayContent = make("Frame", {
			Name = "OverlayContent",
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			ZIndex = 51,
			Parent = overlay,
		})
		overlay.Visible = true
		buildFn(overlayContent)
	end

	overlayBlock.MouseButton1Click:Connect(function()
		closeOverlay()
	end)

	local tooltip = make("Frame", {
		Name = "Tooltip",
		Size = UDim2.new(0, 10, 0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Theme.ControlBg,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 60,
		Parent = win,
	})
	corner(tooltip, 3)
	stroke(tooltip, Theme.ControlBorder, 0.3)
	local tooltipLbl = make("TextLabel", {
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Font = FONT,
		Text = "",
		TextSize = 12,
		TextColor3 = Theme.TextBright,
		ZIndex = 60,
		Parent = tooltip,
	})
	make("UIPadding", {
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
		Parent = tooltipLbl,
	})

	local function showTooltip(text, anchor)
		tooltipLbl.Text = text
		local ap = anchor.AbsolutePosition
		local wp = win.AbsolutePosition
		tooltip.Position = UDim2.new(0, ap.X - wp.X - 4, 0, ap.Y - wp.Y + 20)
		tooltip.Visible = true
	end
	local function hideTooltip()
		tooltip.Visible = false
	end

	do
		-- Dragging. The window follows the cursor by a fixed grab offset rather
		-- than by a delta re-measured every frame: a resize, a scale change or a
		-- dropped frame would otherwise let the window drift out from under the
		-- pointer, and that drift is exactly what makes a drag feel loose instead
		-- of attached.
		--
		-- A press that starts on an interactive topbar child belongs to that
		-- child, never to the window. The blockers are hit-tested live, so a tab
		-- strip that grows, or a search box that is hidden, is respected on the
		-- very next press with no cached geometry to go stale.
		--
		-- Reworked: any bar can be a handle, not just the topbar, and the clamp is
		-- cluster-aware. A companion panel (the stats card) declares how far it
		-- reaches past the window, and the drag then treats window + panels as one
		-- rectangle -- the whole cluster stays on screen instead of the card
		-- sliding off an edge.
		local dragging = false
		local dragToken = nil
		local grabX, grabY = 0, 0
		local blockers = {}
		local extraLeft, extraRight, extraBottom = 0, 0
		-- Motion state. A press only becomes a drag once the pointer clears a few
		-- pixels, which is what lets a tap -- and a double-tap on the bar -- stay a
		-- click instead of nudging the window. Release velocity is sampled from the
		-- pointer and smoothed, so one jittery frame cannot fling the window.
		local DEAD_ZONE = 4
		local SNAP_DIST = 24
		local TAP_TIME = 0.35
		local dragMoved = false
		local downX, downY = 0, 0
		local lastX, lastY, lastT = 0, 0, 0
		local velX, velY = 0, 0
		local glideConn = nil
		local lastTapAt, lastTapX, lastTapY = 0, 0, 0
		local topSnapSaved = nil   -- pre-snap position, for the double-tap toggle
		local dragIconSaved = nil  -- MouseIcon before a drag, when it could be read
		-- Forward-declared: stopDrag is defined before the geometry helpers below,
		-- and a closure only sees a local that exists at its own definition point.
		local settle, doubleTap

		-- Any control registered here keeps its own presses. The topbar's own two
		-- are registered below, and anything built later can register itself.
		local function addDragBlocker(obj)
			if obj then
				blockers[#blockers + 1] = obj
			end
			return obj
		end

		local function overBlocker(px, py)
			for _, obj in ipairs(blockers) do
				local hit = false
				pcall(function()
					if not obj.Visible or not obj.Parent then return end
					local ap, sz = obj.AbsolutePosition, obj.AbsoluteSize
					if sz.X <= 0 or sz.Y <= 0 then return end
					hit = px >= ap.X and px <= ap.X + sz.X and py >= ap.Y and py <= ap.Y + sz.Y
				end)
				if hit then return true end
			end
			return false
		end

		local function cancelGlide()
			if glideConn then
				pcall(function() glideConn:Disconnect() end)
				glideConn = nil
			end
		end

		-- Restore whatever cursor the drag borrowed. Best-effort: an executor that
		-- blocks MouseIcon simply never sees a change.
		local function setGrabCursor(on)
			if not UserInputService then return end
			if on then
				if dragIconSaved ~= nil then return end
				pcall(function() dragIconSaved = UserInputService.MouseIcon end)
				pcall(function() UserInputService.MouseIcon = "rbxassetid://7133979634" end)
			else
				local prev = dragIconSaved
				dragIconSaved = nil
				if prev ~= nil then pcall(function() UserInputService.MouseIcon = prev end) end
			end
		end

		local function currentPos()
			local x, y = 0, 0
			pcall(function()
				local p = win.Position
				x, y = p.X.Offset, p.Y.Offset
			end)
			return x, y
		end

		local function stopDrag()
			local wasDragging = dragging
			local moved = dragMoved
			dragging = false
			dragToken = nil
			dragMoved = false
			setGrabCursor(false)
			if wasDragging and moved then
				settle()
			elseif wasDragging then
				doubleTap()
			end
		end

		-- The whole cluster: the window plus whatever companion panel hangs off
		-- its edges. Falls back to the window alone if the geometry cannot be read
		-- yet.
		local function clusterSize()
			local w, h = WIN_W, WIN_ACTUAL_H
			pcall(function()
				w, h = win.AbsoluteSize.X, win.AbsoluteSize.Y
			end)
			return w + extraLeft + extraRight, h + extraBottom
		end

		-- Whole pixels only: a fractional position puts the window on a half-pixel
		-- row every frame, which is what makes text shimmer while it is dragged.
		--
		-- The clamp keeps the cluster fully on screen whenever it fits; only a
		-- cluster larger than the screen falls back to the older guarantee, which
		-- is that the titlebar stays reachable and the window can always be grabbed
		-- again.
		local function clampPos(px, py)
			local x, y = px, py
			pcall(function()
				local vp = screen.AbsoluteSize
				if vp and vp.X > 1 and vp.Y > 1 then
					local w, h = clusterSize()
					-- The cluster spans (x - extraLeft) .. (x - extraLeft + w), so "all
					-- of it on screen" means the window sits between the left overhang
					-- and the right overhang -- not at zero.
					if w <= vp.X then
						x = math.clamp(x, extraLeft, math.max(extraLeft, vp.X - w + extraLeft))
					else
						local ww = win.AbsoluteSize.X
						local keepX = math.min(140, ww)
						x = math.clamp(x, extraLeft + keepX - ww, math.max(extraLeft, vp.X - keepX))
					end
					if h <= vp.Y then
						y = math.clamp(y, 0, vp.Y - h)
					else
						y = math.clamp(y, 0, math.max(0, vp.Y - TOPBAR_H))
					end
				end
			end)
			return math.floor(x), math.floor(y)
		end

		local function moveTo(px, py)
			local x, y = clampPos(px, py)
			win.Position = UDim2.fromOffset(x, y)
		end

		-- On release: if the cluster is near a viewport edge, snap flush to it (the
		-- card already docks this way); otherwise let the release velocity carry on
		-- under frame-rate-independent decay until it dies or hits a wall.
		settle = function()
			cancelGlide()
			local vp = nil
			pcall(function() vp = screen.AbsoluteSize end)
			local w, h = clusterSize()
			local x, y = currentPos()
			local snapped = false
			if vp and vp.X > 1 and vp.Y > 1 then
				local visX = x - extraLeft
				if w <= vp.X then
					if math.abs(visX) <= SNAP_DIST then
						x, snapped = extraLeft, true
					elseif math.abs((visX + w) - vp.X) <= SNAP_DIST then
						x, snapped = vp.X - w + extraLeft, true
					end
				end
				if h <= vp.Y then
					if math.abs(y) <= SNAP_DIST then
						y, snapped = 0, true
					elseif math.abs((y + h) - vp.Y) <= SNAP_DIST then
						y, snapped = vp.Y - h, true
					end
				end
			end
			if snapped then
				local nx, ny = clampPos(x, y)
				tween(win, { Position = UDim2.fromOffset(nx, ny) }, 0.14, Enum.EasingStyle.Quad)
				return
			end
			if not RunService then return end
			local vx, vy = velX, velY
			if math.sqrt(vx * vx + vy * vy) < 0.35 then return end
			glideConn = RunService.Heartbeat:Connect(function(dt)
				if destroyed or not win.Visible then
					cancelGlide()
					return
				end
				-- ~9% of the speed lost per 60Hz frame: a short, natural glide.
				local decay = math.pow(0.0025, dt)
				vx, vy = vx * decay, vy * decay
				local cx, cy = currentPos()
				local rx, ry = math.floor(cx + vx * dt), math.floor(cy + vy * dt)
				local nx, ny = clampPos(rx, ry)
				-- Hit an edge? Kill that axis so the window does not jitter there.
				if nx ~= rx then vx = 0 end
				if ny ~= ry then vy = 0 end
				win.Position = UDim2.fromOffset(nx, ny)
				if math.sqrt(vx * vx + vy * vy) < 0.35 then cancelGlide() end
			end)
		end

		-- Two quick taps on the bar snap the window flush to the top and centred;
		-- two more put it back exactly where it was. Deliberately position-only:
		-- the column geometry is computed once from WIN_W, so resizing the window
		-- would break the layout.
		doubleTap = function()
			local now = os.clock()
			local near = (now - lastTapAt) <= TAP_TIME
				and math.abs(downX - lastTapX) < 8 and math.abs(downY - lastTapY) < 8
			lastTapAt, lastTapX, lastTapY = now, downX, downY
			if not near then return end
			lastTapAt = 0
			cancelGlide()
			local vp = nil
			pcall(function() vp = screen.AbsoluteSize end)
			if not vp or vp.X <= 1 then return end
			if topSnapSaved then
				local r = topSnapSaved
				topSnapSaved = nil
				local nx, ny = clampPos(r.x, r.y)
				tween(win, { Position = UDim2.fromOffset(nx, ny) }, 0.18, Enum.EasingStyle.Quad)
			else
				local x, y = currentPos()
				topSnapSaved = { x = x, y = y }
				local cw = clusterSize()
				local tx = math.floor((vp.X - cw) / 2) + extraLeft
				local nx = clampPos(tx, 0)
				tween(win, { Position = UDim2.fromOffset(nx, 0) }, 0.18, Enum.EasingStyle.Quad)
			end
		end

		local function startDrag(input)
			if destroyed or not revealed or dragging then return end
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
			local p = input.Position
			if overBlocker(p.X, p.Y) then return end
			local ap = nil
			pcall(function() ap = win.AbsolutePosition end)
			if not ap then return end
			cancelGlide()
			grabX, grabY = p.X - ap.X, p.Y - ap.Y
			downX, downY = p.X, p.Y
			lastX, lastY, lastT = p.X, p.Y, os.clock()
			velX, velY = 0, 0
			dragMoved = false
			dragging = true
			dragToken = input
			setGrabCursor(true)
		end

		-- A handle is any bar allowed to begin a drag: the topbar, and later the
		-- stats card's own header. One handler means every part of the cluster is
		-- draggable by the same rules.
		local function addDragHandle(obj)
			if obj then
				trackConn(obj.InputBegan:Connect(startDrag))
			end
			return obj
		end

		addDragHandle(topbar)

		trackConn(UserInputService.InputEnded:Connect(function(input)
			if not dragging then return end
			local t = input.UserInputType
			if input == dragToken or t == Enum.UserInputType.MouseButton1
				or t == Enum.UserInputType.Touch then
				stopDrag()
			end
		end))

		trackConn(UserInputService.InputChanged:Connect(function(input)
			if not dragging then return end
			-- The menu can be hidden, or the whole UI destroyed, mid-drag.
			if destroyed or not win.Visible then
				stopDrag()
				return
			end
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then return end
			-- A second finger must never fight the one holding the window.
			if t == Enum.UserInputType.Touch and dragToken and input ~= dragToken then return end
			local p = input.Position
			-- Smoothed pointer velocity, sampled for the release glide.
			local now = os.clock()
			local dt = now - lastT
			if dt > 0.0001 then
				velX = velX * 0.6 + ((p.X - lastX) / dt) * 0.4
				velY = velY * 0.6 + ((p.Y - lastY) / dt) * 0.4
			end
			lastX, lastY, lastT = p.X, p.Y, now
			-- Until the pointer clears the dead-zone the press is not yet a drag, so
			-- a tap (or the first half of a double-tap) never nudges the window.
			if not dragMoved then
				if math.abs(p.X - downX) < DEAD_ZONE and math.abs(p.Y - downY) < DEAD_ZONE then
					return
				end
				dragMoved = true
			end
			moveTo(p.X - grabX, p.Y - grabY)
		end))

		addDragBlocker(searchBox)
		addDragBlocker(tabScroll)
		self.AddDragBlocker = addDragBlocker
		self.AddDragHandle = addDragHandle
		-- The glide loop reads `destroyed` and stops itself, but cancel it here too
		-- so a destroyed window leaves no live connection behind.
		onDestroy(cancelGlide)
		-- Companion panels declare their overhang here -- rx past the right edge,
		-- ry past the bottom, lx past the left. The clamp above keeps the whole
		-- rectangle, window plus overhang, on screen.
		function self.SetDragExtent(rx, ry, lx)
			extraRight = tonumber(rx) or 0
			extraBottom = tonumber(ry) or 0
			extraLeft = tonumber(lx) or 0
		end
	end

	local fadeProps = {
		Frame = { "BackgroundTransparency" },
		TextLabel = { "BackgroundTransparency", "TextTransparency" },
		TextBox = { "BackgroundTransparency", "TextTransparency" },
		TextButton = { "BackgroundTransparency", "TextTransparency" },
		ImageLabel = { "BackgroundTransparency", "ImageTransparency" },
		ImageButton = { "BackgroundTransparency", "ImageTransparency" },
		ScrollingFrame = { "BackgroundTransparency", "ScrollBarImageTransparency" },
		UIStroke = { "Transparency" },
	}

	local function collectFade(root)
		local list = {}
		if not root or not root.Parent then
			return list
		end
		local ok = pcall(function()
			local function grab(inst)
				if not inst then return end
				local props = fadeProps[inst.ClassName]
				if props then
					for _, p in ipairs(props) do
						list[#list + 1] = { inst = inst, prop = p, value = inst[p] }
					end
				end
			end
			grab(root)
			for _, d in ipairs(root:GetDescendants()) do
				grab(d)
			end
		end)
		return list
	end

	-- Forward-declare tab/page state so key-system closures can capture them
	local tabs = {}
	local activeTab = nil
	local setActiveTab

	-- ================================================================
	-- Key System — encapsulated for anti-detection
	-- ================================================================
	local Key = {}
	Key.KEY_REQUIRED = "Vision-0x9"
	Key.locked = false
	Key.expiry = 0
	Key.tickerSeq = 0
	Key.fadeSeq = 0
	Key.file = CONFIG_FOLDER .. "/key.dat"
	Key.durHours = 24
	Key.durMins = 0
	Key.maxSecs = 86400
	Key.panel = nil
	Key.input = nil
	Key.inputBox = nil
	Key.redeemBtn = nil
	Key.getBtn = nil
	Key.errorLbl = nil

	Key.format = function(sec)
		if sec <= 0 then return "Key:Expired" end
		local hours = math.floor(sec / 3600)
		if hours >= 1 then
			return "Key:" .. hours .. "h " .. math.floor((sec % 3600) / 60) .. "m"
		else
			return "Key:" .. math.floor(sec / 60) .. "m " .. math.floor(sec % 60) .. "s"
		end
	end

	Key.startTicker = function()
		local s = Key.tickerSeq
		task.spawn(function()
			while s == Key.tickerSeq and not destroyed do
				pcall(function()
					if keyTimerLbl and keyTimerLbl.Parent then
						if Key.locked then
							keyTimerLbl.Text = Key.format(Key.maxSecs)
						elseif Key.expiry > 0 then
							keyTimerLbl.Text = Key.format(Key.expiry - os.time())
						end
					end
				end)
				local remaining = math.max(0, (Key.expiry or 0) - os.time())
				if remaining > 0 and remaining < 3600 then task.wait(1) else task.wait(30) end
			end
		end)
	end
	onDestroy(function()
		Key.tickerSeq = Key.tickerSeq + 1
		Key.fadeSeq = Key.fadeSeq + 1
	end)

	Key.reveal = function()
		if not Key.panel then return end
		Key.panel.Visible = true
		Key.input.Text = ""
		Key.inputBox.Interactable = true
		Key.redeemBtn.Interactable = true
		Key.getBtn.Interactable = true
		Key.errorLbl.Text = ""
		pcall(function()
			Key.panel.BackgroundTransparency = 0
			for _, d in ipairs(Key.panel:GetDescendants()) do
				if d:IsA("TextLabel") or d:IsA("TextBox") then d.TextTransparency = 0
				elseif d:IsA("Frame") and d.Name ~= "KeyPanel" then d.BackgroundTransparency = 0
				elseif d:IsA("ImageLabel") then d.ImageTransparency = 0
				elseif d:IsA("UIStroke") then d.Transparency = 0
				end
			end
		end)
	end

	Key.tryRedeem = function()
		if (Key.input and Key.input.Text or "") == Key.KEY_REQUIRED then
			Key.inputBox.Interactable = false
			Key.redeemBtn.Interactable = false
			Key.getBtn.Interactable = false
			Key.errorLbl.Text = ""
			Key.expiry = os.time() + Key.maxSecs
			Key.locked = false
			if canFile() then
				pcall(function() writefile(Key.file, tostring(Key.expiry)) end)
			end
			local fs = Key.fadeSeq
			for _, d in ipairs(Key.panel:GetDescendants()) do
				pcall(function()
					if d:IsA("TextLabel") or d:IsA("TextBox") then tween(d, { TextTransparency = 1 }, 0.35)
					elseif d:IsA("Frame") and d.Name ~= "KeyPanel" then tween(d, { BackgroundTransparency = 1 }, 0.35)
					end
				end)
			end
			task.delay(0.4, function()
				if fs ~= Key.fadeSeq then return end
				Key.panel.Visible = false
				if tabs and #tabs > 0 then setActiveTab(tabs[1]) end
			end)
		else
			Key.errorLbl.Text = "Invalid key"
			tween(Key.inputBox, { BackgroundColor3 = Color3.fromRGB(60, 20, 20) }, 0.1)
			task.delay(0.18, function() tween(Key.inputBox, { BackgroundColor3 = Theme.ControlBg }, 0.25) end)
		end
	end

	Key.destroy = function()
		Key.fadeSeq = Key.fadeSeq + 1
		Key.tickerSeq = Key.tickerSeq + 1
		if canFile() then pcall(function() if isfile(Key.file) then delfile(Key.file) end end) end
		Key.expiry = 0
		Key.locked = true
		closeOverlay()
		hideTooltip()
		for _, tb in ipairs(tabs) do if tb and tb.Page then tb.Page.Visible = false end end
		activeTab = nil
		Key.reveal()
		Key.startTicker()
	end

	-- === Activate key system if enabled ===
	if opts.Keysystem then
		Key.locked = true
		local d = opts.KeyDuration or {}
		Key.durHours = math.clamp(d.Hours or 24, 0, 48)
		Key.durMins = math.clamp(d.Minutes or 0, 0, 59)
		Key.maxSecs = (Key.durHours * 3600) + (Key.durMins * 60)

		-- Read saved expiry
		if canFile() then
			pcall(function()
				if isfile(Key.file) then Key.expiry = tonumber(readfile(Key.file)) or 0 end
			end)
		end

		if Key.expiry > os.time() then
			Key.locked = false
			Key.startTicker()
		else
			-- ============================================================
			-- Build key entry panel
			-- ============================================================
			Key.panel = make("Frame", {
				Name = "KeyPanel", AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, -14),
				Size = UDim2.new(0, 256, 0, 200),
				BackgroundColor3 = Theme.PanelBg, BorderSizePixel = 0,
				ZIndex = 40, Parent = content,
			})
			corner(Key.panel, 5)
			stroke(Key.panel, Theme.ControlBorder, 0.3)

			make("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 18),
				Size = UDim2.new(1, -28, 0, 22), BackgroundTransparency = 1,
				Font = FONT_BOLD, Text = "Vision Key", TextSize = 15,
				TextColor3 = Theme.TextWhite, ZIndex = 41, Parent = Key.panel,
			})

			Key.inputBox = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 52),
				Size = UDim2.new(1, -32, 0, 34), BackgroundColor3 = Theme.ControlBg,
				BorderSizePixel = 0, ZIndex = 41, Parent = Key.panel,
			})
			corner(Key.inputBox, 4)
			stroke(Key.inputBox, Theme.ControlBorder, 0.25)

			Key.input = make("TextBox", {
				Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -24, 1, 0),
				BackgroundTransparency = 1, Font = FONT,
				PlaceholderText = "Enter key...", PlaceholderColor3 = Theme.TextDim,
				Text = "", TextSize = 13, TextColor3 = Theme.TextWhite,
				TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false,
				ZIndex = 42, Parent = Key.inputBox,
			})

			Key.errorLbl = make("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 92),
				Size = UDim2.new(1, -32, 0, 16), BackgroundTransparency = 1,
				Font = FONT, Text = "", TextSize = 11,
				TextColor3 = Color3.fromRGB(255, 72, 72), ZIndex = 41, Parent = Key.panel,
			})

			-- Redeem
			Key.redeemBtn = make("Frame", {
				Name = "KeyRedeem", AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 112), Size = UDim2.new(1, -32, 0, 32),
				BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
				ZIndex = 41, Parent = Key.panel,
			})
			corner(Key.redeemBtn, 4)
			local rdrStroke = stroke(Key.redeemBtn, Theme.Accent, 0.15)
			local rdrLbl = make("TextLabel", {
				Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1,
				Font = FONT_BOLD, Text = "Redeem", TextSize = 13,
				TextColor3 = Theme.Check, ZIndex = 41, Parent = Key.redeemBtn,
			})
			Key.redeemBtn.MouseEnter:Connect(function()
				tween(Key.redeemBtn, { BackgroundColor3 = Theme.TextWhite }, 0.13)
				tween(rdrStroke, { Color = Theme.TextWhite }, 0.13)
				tween(rdrLbl, { TextColor3 = Theme.Check }, 0.13)
			end)
			Key.redeemBtn.MouseLeave:Connect(function()
				tween(Key.redeemBtn, { BackgroundColor3 = Theme.Accent }, 0.18)
				tween(rdrStroke, { Color = Theme.Accent }, 0.18)
				tween(rdrLbl, { TextColor3 = Theme.Check }, 0.18)
			end)
			Key.redeemBtn.InputBegan:Connect(function(i)
				if i.UserInputType == Enum.UserInputType.MouseButton1 then
					tween(Key.redeemBtn, { Size = UDim2.new(1, -30, 0, 30) }, 0.05)
					task.delay(0.06, function() tween(Key.redeemBtn, { Size = UDim2.new(1, -32, 0, 32) }, 0.08) end)
					Key.tryRedeem()
				end
			end)

			-- Get Key
			Key.getBtn = make("Frame", {
				Name = "KeyGet", AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 152), Size = UDim2.new(1, -32, 0, 30),
				BackgroundColor3 = Theme.ControlBg, BorderSizePixel = 0,
				ZIndex = 41, Parent = Key.panel,
			})
			corner(Key.getBtn, 4)
			local gkStroke = stroke(Key.getBtn, Theme.ControlBorder, 0.25)
			local gkLbl = make("TextLabel", {
				Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1,
				Font = FONT, Text = "Get Key", TextSize = 12,
				TextColor3 = Theme.TextMid, ZIndex = 41, Parent = Key.getBtn,
			})
			Key.getBtn.MouseEnter:Connect(function()
				tween(Key.getBtn, { BackgroundColor3 = Theme.PanelBg }, 0.13)
				tween(gkStroke, { Color = Theme.TextMid }, 0.13)
				tween(gkLbl, { TextColor3 = Theme.TextBright }, 0.13)
			end)
			Key.getBtn.MouseLeave:Connect(function()
				tween(Key.getBtn, { BackgroundColor3 = Theme.ControlBg }, 0.18)
				tween(gkStroke, { Color = Theme.ControlBorder }, 0.18)
				tween(gkLbl, { TextColor3 = Theme.TextMid }, 0.18)
			end)
			Key.getBtn.InputBegan:Connect(function(i)
				if i.UserInputType == Enum.UserInputType.MouseButton1 and opts.GetKeyUrl then
					pcall(function() if setclipboard then setclipboard(opts.GetKeyUrl) end end)
				end
			end)

			Key.inputBox.MouseEnter:Connect(function()
				tween(Key.inputBox, { BackgroundColor3 = Theme.Track }, 0.1)
			end)
			Key.inputBox.MouseLeave:Connect(function()
				tween(Key.inputBox, { BackgroundColor3 = Theme.ControlBg }, 0.18)
			end)

			Key.input.FocusLost:Connect(function(enter) if enter then Key.tryRedeem() end end)

			Key.startTicker()
		end

		-- === Public: RenewKey ===
		function self.RenewKey() Key.destroy() end
	end

	-- Fallback for Keysystem off
	if not self.RenewKey then
		function self.RenewKey() return false end
	end

	-- Re-expose a locked-check for internal gates
	local function isKeyLocked()
		return opts.Keysystem and Key and Key.locked
	end

	-- Window visibility is owned by doReveal at the end of this function.

	-- ================================================================
	-- Notification system
	-- ================================================================
	local notifications = make("Frame", {
		Name = "Notifications",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -20, 0, 20),
		Size = UDim2.new(0, 260, 1, -40),
		BackgroundTransparency = 1,
		ZIndex = 100,
		Parent = screen,
	})
	make("UIListLayout", {
		VerticalAlignment = Enum.VerticalAlignment.Top,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
		Parent = notifications,
	})

	local noteOrder = 0
	function self.Notify(o)
		o = o or {}
		local title = o.title or "Vision"
		local body = o.text or o.body or ""
		local duration = o.duration or 5
		local noteType = o.type or "info"
		local colors = {
			info = Color3.fromRGB(56, 150, 255),
			success = Color3.fromRGB(46, 204, 113),
			warn = Color3.fromRGB(241, 196, 15),
			error = Color3.fromRGB(231, 76, 60),
		}
		local titleColor = colors[noteType] or colors.info

		noteOrder = noteOrder + 1
		local note = make("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Theme.PanelBg,
			BorderSizePixel = 0,
			LayoutOrder = noteOrder,
			ZIndex = 31,
			Parent = notifications,
		})
		corner(note, 4)
		stroke(note, Theme.ControlBorder, 0.3)
		-- Title
		make("TextLabel", {
			Position = UDim2.new(0, 12, 0, 8),
			Size = UDim2.new(1, -24, 0, 14),
			BackgroundTransparency = 1,
			Font = FONT_BOLD,
			Text = title,
			TextSize = 12,
			TextColor3 = titleColor,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 32,
			Parent = note,
		})
		-- Body (if present)
		local bodyLbl
		if body ~= "" then
			bodyLbl = make("TextLabel", {
				Position = UDim2.new(0, 12, 0, 24),
				-- Wrapped body text has no fixed height: without AutomaticSize the
				-- label clips every line after the first.
				Size = UDim2.new(1, -24, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				Font = FONT,
				Text = body,
				TextSize = 11,
				TextColor3 = Theme.TextMid,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextWrapped = true,
				ZIndex = 32,
				Parent = note,
			})
		end
		make("UIPadding", {
			PaddingBottom = UDim.new(0, 10),
			Parent = note,
		})

		-- Fade in
		for _, d in ipairs(note:GetDescendants()) do
			pcall(function()
				if d:IsA("TextLabel") then
					d.TextTransparency = 1
				end
			end)
		end
		note.BackgroundTransparency = 1
		for _, d in ipairs(note:GetDescendants()) do
			pcall(function()
				if d:IsA("TextLabel") then
					tween(d, { TextTransparency = 0 }, 0.18)
				end
			end)
		end
		tween(note, { BackgroundTransparency = 0 }, 0.18)

		-- Fade out and destroy after duration
		task.delay(duration, function()
			for _, d in ipairs(note:GetDescendants()) do
				pcall(function()
					if d:IsA("TextLabel") then
						tween(d, { TextTransparency = 1 }, 0.2)
					elseif d:IsA("Frame") and d.Name ~= "Notifications" then
						tween(d, { BackgroundTransparency = 1 }, 0.2)
					end
				end)
			end
			task.delay(0.25, function()
				pcall(function() note:Destroy() end)
			end)
		end)

		return note
	end

	tabs = {}
	activeTab = nil
	local searchIndex = {}

	local switchGen = 0

	local function restorePage(tb)
		if tb.ActiveTweens then
			for _, tw in ipairs(tb.ActiveTweens) do
				pcall(function() tw:Cancel() end)
			end
		end
		tb.ActiveTweens = nil
		if tb.LastCache then
			for _, e in ipairs(tb.LastCache) do
				if e.inst and e.inst.Parent then
					e.inst[e.prop] = e.value
				end
			end
		end
		tb.LastCache = nil
	end

setActiveTab = function(t)
	if not t or not t.Page then return end
	if isKeyLocked() then return end
	if activeTab == t then return end
	closeOverlay()
		switchGen = switchGen + 1
		local gen = switchGen
		local old = activeTab
		local oi, ni = 0, 0
		for i, tb in ipairs(tabs) do
			if tb == old then oi = i end
			if tb == t then ni = i end
		end
		local dir = (oi ~= 0 and ni < oi) and -1 or 1

	if old then
		restorePage(old)
		if old.Page then old.Page.Visible = false end
		if old.NavIcon then tween(old.NavIcon, { ImageColor3 = Theme.TextDim }, 0.14) end
		if old.NavLabel then tween(old.NavLabel, { TextColor3 = Theme.TextDim }, 0.14) end
	end
	activeTab = t
	if t.NavIcon then tween(t.NavIcon, { ImageColor3 = Theme.Accent }, 0.14) end
	if t.NavLabel then tween(t.NavLabel, { TextColor3 = Theme.TextWhite }, 0.14) end

	restorePage(t)
	local cache = t.Page and collectFade(t.Page) or {}
		t.LastCache = cache
		t.ActiveTweens = {}
		for _, e in ipairs(cache) do
			e.inst[e.prop] = 1
		end
		t.Page.Position = UDim2.new(0, dir * 26, 0, 0)
		t.Page.Visible = true
		t.ActiveTweens[#t.ActiveTweens + 1] = tween(t.Page, { Position = UDim2.new(0, 0, 0, 0) }, 0.3, Enum.EasingStyle.Quint)

		local byGroup = {}
		local groups = t.Groups or {}
		for _, e in ipairs(cache) do
			local box
		for _, gr in ipairs(groups) do
			if e.inst == gr.Box or e.inst:IsDescendantOf(gr.Box) then
				box = gr.Box
				break
			end
		end
		byGroup[box or t.Page] = byGroup[box or t.Page] or {}
		table.insert(byGroup[box or t.Page], e)
	end
	for gi, gr in ipairs(groups) do
			local entries = byGroup[gr.Box]
			if entries then
				task.delay(0.02 + gi * 0.03, function()
					if switchGen ~= gen or not t.ActiveTweens then return end
					for _, e in ipairs(entries) do
						t.ActiveTweens[#t.ActiveTweens + 1] = tween(e.inst, { [e.prop] = e.value }, 0.2, Enum.EasingStyle.Quad)
					end
				end)
			end
		end
		local loose = byGroup[t.Page]
		if loose then
			for _, e in ipairs(loose) do
				t.ActiveTweens[#t.ActiveTweens + 1] = tween(e.inst, { [e.prop] = e.value }, 0.18, Enum.EasingStyle.Quad)
			end
		end
		local groupCount = t.Groups and #t.Groups or 0
	task.delay(0.02 + groupCount * 0.03 + 0.24, function()
			if switchGen == gen then
				t.ActiveTweens = nil
				t.LastCache = nil
			end
		end)
	end

	function self.Tab(name, topts)
		-- Handle :Tab("Combat") convention: first arg is the window itself
		if name == self then
			name, topts = topts, nil
		end
		if type(name) == "table" then
			topts = name
			name = topts.Name or topts.name or topts.title or "Tab"
		end
		topts = topts or {}
		if type(name) ~= "string" then
			name = tostring(name)
		end
		local tab = {}
		tab.Name = name

		local nav = make("Frame", {
			Name = "Nav_" .. name,
			Size = UDim2.new(0, 30, 1, -12),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			LayoutOrder = #tabs + 1,
			Parent = tabScroll,
		})
		local navIcon = make("ImageLabel", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0),
			Size = UDim2.new(0, 16, 0, 16),
			BackgroundTransparency = 1,
			ImageColor3 = Theme.TextDim,
			ScaleType = Enum.ScaleType.Fit,
			Parent = nav,
		})
		local hasNavIcon = applyIcon(navIcon, resolveIcon(topts.icon or topts.Icon))
		if not hasNavIcon then
			navIcon.Visible = false
		end
		local navLbl = make("TextLabel", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, hasNavIcon and 21 or 0, 0.5, 0),
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Font = FONT_MED,
			Text = name,
			TextSize = TEXT,
			TextColor3 = Theme.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = nav,
		})

		local page = make("ScrollingFrame", {
			Name = "Page_" .. name,
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 2,
			ScrollBarImageColor3 = Theme.ControlBorder,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			Visible = false,
			Parent = content,
		})
		local colL = make("Frame", {
			Name = "ColLeft",
			Position = UDim2.new(0, MARGIN, 0, 12),
			Size = UDim2.new(0, COL_W, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = page,
		})
		make("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, COL_GAP),
			Parent = colL,
		})
		local colR = make("Frame", {
			Name = "ColRight",
			Position = UDim2.new(0, MARGIN + COL_W + COL_GAP, 0, 12),
			Size = UDim2.new(0, COL_W, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = page,
		})
		make("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, COL_GAP),
			Parent = colR,
		})
		make("UIPadding", {
			PaddingBottom = UDim.new(0, 14),
			Parent = page,
		})

		tab.Page = page
		tab.NavIcon = navIcon
		tab.NavLabel = navLbl
		tab.ColL = colL
		tab.ColR = colR
		tab.Groups = {}

		nav.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				setActiveTab(tab)
			end
		end)
		nav.MouseEnter:Connect(function()
			if activeTab ~= tab then
				tween(navIcon, { ImageColor3 = Theme.TextMid }, 0.1)
				tween(navLbl, { TextColor3 = Theme.TextMid }, 0.1)
			end
		end)
		nav.MouseLeave:Connect(function()
			if activeTab ~= tab then
				tween(navIcon, { ImageColor3 = Theme.TextDim }, 0.1)
				tween(navLbl, { TextColor3 = Theme.TextDim }, 0.1)
			end
		end)

		function tab.Group(gname, gopts, goptsExtra)
			-- Handle :Group("Aimbot", opts): Lua passes (tab, "Aimbot", opts)
			if type(gname) == "table" and type(gopts) == "string" then
				gname, gopts = gopts, goptsExtra
			end
			if type(gname) == "table" then
				gopts = gname
				gname = gopts.Name or gopts.name or gopts.title or "Group"
			end
			gopts = gopts or {}
			if type(gname) ~= "string" then
				gname = tostring(gname)
			end
			local group = {}

			local side = gopts.side
			if side ~= "left" and side ~= "right" then
				local nl, nr = 0, 0
				for _, gr in ipairs(tab.Groups) do
					if gr.Side == "left" then nl = nl + 1 else nr = nr + 1 end
				end
				side = (nl <= nr) and "left" or "right"
			end
			local parentCol = (side == "left") and colL or colR

			local box = make("Frame", {
				Name = "Group_" .. gname,
				-- The column sorts by LayoutOrder: without one every group ties at
				-- 0 and the visible order is not specified. This is the group's
				-- 1-based index in its tab, so the order is the creation order.
				LayoutOrder = #tab.Groups + 1,
				Size = UDim2.new(1, 0, 0, HEAD_H),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = Theme.PanelBg,
				BorderSizePixel = 0,
				Parent = parentCol,
			})
			corner(box, 3)
			-- The group body is the main thing the backdrop should read through.
			applySurface(box, "PanelBg")

			local head = make("Frame", {
				Name = "Head",
				Size = UDim2.new(1, 0, 0, HEAD_H),
				BackgroundColor3 = Theme.AccentDark,
				BorderSizePixel = 0,
				Parent = box,
			})
			corner(head, 3)
			applySurface(head, "AccentDark")
			-- Group headers are draggable too. One more place the window can be
			-- grabbed matters on a crowded screen, and a header carries no control
			-- that a press should belong to.
			if self and self.AddDragHandle then self.AddDragHandle(head) end
			make("UIGradient", {
				Name = "ThemeGradient",
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Theme.GradientTop),
					ColorSequenceKeypoint.new(0.55, Theme.HeaderMid),
					ColorSequenceKeypoint.new(1, Theme.AccentDark),
				}),
				Parent = head,
			})
			-- Built empty and filled in off the render path: the stripes download
			-- must never stall group construction while the loader is animating.
			local stripes = make("ImageLabel", {
				Size = UDim2.new(1, 0, 1, 0),
				BackgroundTransparency = 1,
				ScaleType = Enum.ScaleType.Tile,
				TileSize = UDim2.new(0, 24, 0, 24),
				ImageTransparency = 0.45,
				ZIndex = 2,
				Parent = head,
			})
			loadImageAsync(stripes, STRIPES_FILE)
			local headTitle = make("TextLabel", {
				Position = UDim2.new(0, 10, 0, 0),
				Size = UDim2.new(1, -50, 1, 0),
				BackgroundTransparency = 1,
				Font = FONT_BOLD,
				Text = gname,
				TextSize = TEXT,
				TextColor3 = Theme.HeaderText or Theme.TextWhite,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 3,
				Parent = head,
			})

			if gopts.info then
				local infoCircle = make("Frame", {
					Name = "InfoCircle",
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -8, 0.5, 0),
					Size = UDim2.new(0, 15, 0, 15),
					BackgroundColor3 = Theme.InfoBg,
					BorderSizePixel = 0,
					ZIndex = 3,
					Parent = head,
				})
				corner(infoCircle, 8)
				make("TextLabel", {
					Name = "InfoCircleText",
					Size = UDim2.new(1, 0, 1, 0),
					BackgroundTransparency = 1,
					Font = FONT_BOLD,
					Text = "!",
					TextSize = 11,
					TextColor3 = Theme.InfoText,
					ZIndex = 3,
					Parent = infoCircle,
				})
				infoCircle.MouseEnter:Connect(function()
					showTooltip(gopts.info, infoCircle)
				end)
				infoCircle.MouseLeave:Connect(function()
					hideTooltip()
				end)
			end

			local body = make("Frame", {
				Name = "Body",
				Position = UDim2.new(0, 0, 0, HEAD_H),
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				Parent = box,
			})
			make("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
				Parent = body,
			})
			make("UIPadding", {
				PaddingTop = UDim.new(0, 8),
				PaddingBottom = UDim.new(0, 10),
				PaddingLeft = UDim.new(0, 10),
				PaddingRight = UDim.new(0, 10),
				Parent = body,
			})

			group.Box = box
			group.Body = body
			group.Name = gname
			group.Side = side
			local elemOrder = 0
			local function nextOrder()
				elemOrder = elemOrder + 1
				return elemOrder
			end

			local function registerSearch(text, row)
				searchIndex[#searchIndex + 1] = {
					tab = tab,
					group = group,
					text = text,
					row = row,
				}
			end

			group._nextOrder = nextOrder
			group._registerSearch = registerSearch
			tab.Groups[#tab.Groups + 1] = group

			attachElements(group)

			return group
		end

		tab.Select = function()
			setActiveTab(tab)
		end

		tabs[#tabs + 1] = tab
		if not activeTab and not isKeyLocked() then
			-- Defer until the reveal: selecting now would play the entrance
			-- stagger while the window is still invisible.
			if revealed then setActiveTab(tab) else pendingTab = pendingTab or tab end
		end
		return tab
	end

	function attachElements(group)
		local body = group.Body
		local nextOrder = group._nextOrder
		local registerSearch = group._registerSearch

		local function baseRow(h)
			local row = make("Frame", {
				Size = UDim2.new(1, 0, 0, h),
				BackgroundTransparency = 1,
				LayoutOrder = nextOrder(),
				Parent = body,
			})
			return row
		end

		function group.Label(o)
			o = o or {}
			-- Wrapped label text has no single-line height, so neither the row nor
			-- the label gets one: both size to the wrapped lines. A fixed row
			-- height clips the last line in half.
			local row = baseRow(0)
			row.AutomaticSize = Enum.AutomaticSize.Y
			make("TextLabel", {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				Font = FONT,
				Text = o.text or "",
				TextSize = TEXT,
				TextColor3 = Theme.TextMid,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextWrapped = true,
				Parent = row,
			})
			return { Row = row }
		end

		function group.Toggle(o)
			o = o or {}
			local saved = o.flag and Vision.Flags[o.flag]
			local state = saved ~= nil and (saved and true or false) or (o.default and true or false)
			local ch, cs, cv = 0, 1, 1
			local hasColor = o.color ~= nil
			if hasColor and typeof(o.color) == "Color3" then
				ch, cs, cv = o.color:ToHSV()
			end

			local row = baseRow(22)
			local lbl = make("TextLabel", {
				Size = UDim2.new(1, -60, 1, 0),
				BackgroundTransparency = 1,
				Font = FONT_MED,
				Text = o.text or "Toggle",
				TextSize = TEXT,
				TextColor3 = Theme.TextMid,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = row,
			})
			registerSearch(o.text or "Toggle", row)

			-- The check box. The tick is the Lucide "check" icon: one asset, in the
			-- same icon language as the rest of the UI and crisp at this size.
			local boxBtn = make("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.new(0, 16, 0, 16),
				BackgroundColor3 = Theme.ControlBg,
				BorderSizePixel = 0,
				Parent = row,
			})
			corner(boxBtn, 3)
			-- Built after the theme was applied, so it reads the surface alpha itself.
			applySurface(boxBtn, "ControlBg")
			local boxStroke = stroke(boxBtn, Theme.ControlBorder, 0)

			local check = make("ImageLabel", {
				Name = "Check",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				Size = UDim2.new(0, 11, 0, 11),
				BackgroundTransparency = 1,
				Image = LUCIDE_CHECK,
				ImageColor3 = Theme.Check,
				ImageTransparency = 1,
				ScaleType = Enum.ScaleType.Fit,
				ZIndex = 2,
				Parent = boxBtn,
			})

			local swatch
			if hasColor then
				swatch = make("Frame", {
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -22, 0.5, 0),
					Size = UDim2.new(0, 24, 0, 14),
					BackgroundColor3 = Color3.fromHSV(ch, cs, cv),
					BorderSizePixel = 0,
					Parent = row,
				})
				corner(swatch, 2)
				stroke(swatch, Theme.ControlBorder, 0.2)
			end

			local function paint()
				-- Re-read on every repaint, so the tick follows the theme's own mark
				-- colour instead of being frozen at build time.
				pcall(function() check.ImageColor3 = Theme.Check end)
				if state then
					tween(boxBtn, { BackgroundColor3 = Theme.Accent }, 0.14)
					tween(boxStroke, { Color = Theme.Accent }, 0.14)
					tween(check, { ImageTransparency = 0 }, 0.14)
					tween(lbl, { TextColor3 = Theme.TextBright }, 0.14)
				else
					tween(boxBtn, { BackgroundColor3 = Theme.ControlBg }, 0.14)
					tween(boxStroke, { Color = Theme.ControlBorder }, 0.14)
					tween(check, { ImageTransparency = 1 }, 0.14)
					tween(lbl, { TextColor3 = Theme.TextMid }, 0.14)
				end
			end
			paint()
			registerRepaint(paint)

			local function currentColor()
				return Color3.fromHSV(ch, cs, cv)
			end

			local function push(silent)
				if o.flag then Vision.Flags[o.flag] = state; Vision._scheduleSave() end
				if hasColor and o.colorFlag then Vision.Flags[o.colorFlag] = currentColor(); Vision._scheduleSave() end
				if not silent and o.callback then
					task.spawn(o.callback, state)
				end
			end

			local function set(v, silent)
				v = v and true or false
				if v == state then return end
				state = v
				paint()
				push(silent)
			end

			row.InputBegan:Connect(function(input)
				-- Mouse and touch both drive the switch; a palm or second finger is
				-- simply another press and is harmless here.
				local t = input.UserInputType
				if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
				if swatch then
					local x, y = input.Position.X, input.Position.Y
					local sp, ss = swatch.AbsolutePosition, swatch.AbsoluteSize
					if x >= sp.X and x <= sp.X + ss.X and y >= sp.Y and y <= sp.Y + ss.Y then
						return
					end
				end
				set(not state)
			end)
			row.MouseEnter:Connect(function()
				if not state then
					tween(lbl, { TextColor3 = Theme.TextBright }, 0.1)
				end
			end)
			row.MouseLeave:Connect(function()
				if not state then
					tween(lbl, { TextColor3 = Theme.TextMid }, 0.1)
				end
			end)

			if swatch then
				swatch.InputBegan:Connect(function(input)
					local t = input.UserInputType
					if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
						openHuePopup(swatch, function() return ch end, function(h)
							ch, cs, cv = h, 1, 1
							swatch.BackgroundColor3 = currentColor()
							if o.colorFlag then Vision.Flags[o.colorFlag] = currentColor(); Vision._scheduleSave() end
							if o.colorCallback then
								task.spawn(o.colorCallback, currentColor())
							end
						end)
					end
				end)
			end

			push(true)
			bindFlag(o.flag, function(v) set(v, false) end, function() return state end)
			if hasColor and o.colorFlag then
				bindFlag(o.colorFlag, function(v)
					if typeof(v) == "Color3" then
						ch, cs, cv = v:ToHSV()
						swatch.BackgroundColor3 = currentColor()
					end
				end, currentColor)
			end

			return {
				Row = row,
				Set = set,
				Get = function() return state end,
				SetColor = hasColor and function(c)
					ch, cs, cv = c:ToHSV()
					swatch.BackgroundColor3 = currentColor()
				end or nil,
				GetColor = hasColor and currentColor or nil,
			}
		end

		function group.Keybind(o)
			o = o or {}
			local savedKey = o.flag and Vision.Flags[o.flag]
			local key = o.default
			-- Restore saved keybind: supports keyboard ("Q", "Insert") + mouse ("MB1"/"MB2"/"MB3", "RMB")
			if type(savedKey) == "string" and savedKey ~= "None" then
				key = parseKeyString(savedKey) or key
			elseif typeof(savedKey) == "EnumItem" then
				key = savedKey
			end
			-- Allow default as string too ("MB2" for right-click)
			if type(key) == "string" then
				key = parseKeyString(key)
			end
			local mode = o.mode or "Toggle"
			local listening = false
			local held = false
			local openedAt = 0

			local row = baseRow(22)
			local lbl = make("TextLabel", {
				Size = UDim2.new(1, -80, 1, 0),
				BackgroundTransparency = 1,
				Font = FONT,
				Text = o.text or "Keybind",
				TextSize = TEXT,
				TextColor3 = Theme.TextDim,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = row,
			})
			registerSearch(o.text or "Keybind", row)
			local keyLbl = make("TextLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 0),
				Size = UDim2.new(0, 120, 1, 0),
				BackgroundTransparency = 1,
				Font = FONT_MED,
				Text = "[ " .. keyName(key) .. " ]",
				TextSize = TEXT,
				TextColor3 = Theme.TextDim,
				TextXAlignment = Enum.TextXAlignment.Right,
				Parent = row,
			})

			local function stopListening()
				listening = false
				if keybindListenCancel == stopListening then
					keybindListenCancel = nil
				end
				keyLbl.Text = "[ " .. keyName(key) .. " ]"
				tween(keyLbl, { TextColor3 = Theme.TextDim }, 0.1)
			end

			local function applyKey(kc)
				if type(kc) == "string" then
					kc = parseKeyString(kc)
				end
				key = kc
				keyLbl.Text = "[ " .. keyName(key) .. " ]"
				if o.flag then Vision.Flags[o.flag] = keyStorageName(key); Vision._scheduleSave() end
			end

			row.InputBegan:Connect(function(input)
				local t = input.UserInputType
				if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
					-- Clicking the row while listening cancels instead of rebinding.
					if listening then
						stopListening()
						task.defer(function() anyListening = false end)
						return
					end
					if keybindListenCancel then keybindListenCancel() end
					keybindListenCancel = stopListening
					anyListening = true
					listening = true
					openedAt = os.clock()
					keyLbl.Text = "[ ... ]"
					tween(keyLbl, { TextColor3 = Theme.Accent }, 0.1)
				end
			end)

			local function push(state)
				if o.callback then
					task.spawn(o.callback, state, key)
				end
			end

			trackConn(UserInputService.InputBegan:Connect(function(input, processed)
				if listening then
					-- Keyboard bind (ignore while typing). Escape cancels cleanly.
					if input.UserInputType == Enum.UserInputType.Keyboard and not processed then
						if input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode ~= Enum.KeyCode.Unknown then
							key = input.KeyCode
							if o.flag then Vision.Flags[o.flag] = keyStorageName(key); Vision._scheduleSave() end
							if o.changed then
								task.spawn(o.changed, key)
							end
						end
						stopListening()
						task.defer(function() anyListening = false end)
						return
					end
					-- Mouse bind (LMB / RMB / MMB) - clean for aim keys.
					-- Timestamp debounce, not `processed`: rows don't sink input,
					-- so the click that opened listening arrives here unprocessed
					-- and must not bind instantly.
					if input.UserInputType == Enum.UserInputType.MouseButton1
						or input.UserInputType == Enum.UserInputType.MouseButton2
						or input.UserInputType == Enum.UserInputType.MouseButton3 then
						if os.clock() - openedAt < 0.25 then return end
						key = input.UserInputType
						stopListening()
						task.defer(function() anyListening = false end)
						if o.flag then Vision.Flags[o.flag] = keyStorageName(key); Vision._scheduleSave() end
						if o.changed then
							task.spawn(o.changed, key)
						end
						return
					end
					return
				end
				if processed or listening or anyListening then return end
				if key and keysMatch(key, input) then
					if mode == "Hold" then
						held = true
						push(true)
					else
						push(true)
					end
				end
			end))
			trackConn(UserInputService.InputEnded:Connect(function(input)
				if mode == "Hold" and key and held and keysMatch(key, input) then
					held = false
					push(false)
				end
			end))

			if o.flag then Vision.Flags[o.flag] = keyStorageName(key); Vision._scheduleSave() end
			bindFlag(o.flag, function(v)
				if type(v) == "string" then
					applyKey(parseKeyString(v))
				elseif typeof(v) == "EnumItem" then
					applyKey(v)
				else
					applyKey(nil)
				end
			end, function() return keyStorageName(key) end)

			return {
				Row = row,
				Set = applyKey,
				Get = function() return key end,
			}
		end

		function group.Slider(o)
			o = o or {}
			local min = o.min or 0
			local max = o.max or 100
			local step = o.step or 1
			local decimals = o.decimals
			if decimals == nil then
				decimals = (step % 1 ~= 0) and 2 or 0
			end
			local saved = o.flag and Vision.Flags[o.flag]
			local value = math.clamp((type(saved) == "number" and saved) or (o.default or min), min, max)

			local row = baseRow(34)
			local lbl = make("TextLabel", {
				Size = UDim2.new(1, -90, 0, 18),
				BackgroundTransparency = 1,
				Font = FONT_MED,
				Text = o.text or "Slider",
				TextSize = TEXT,
				TextColor3 = Theme.TextBright,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = row,
			})
			registerSearch(o.text or "Slider", row)
			local valueLbl = make("TextLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 0),
				Size = UDim2.new(0, 86, 0, 18),
				BackgroundTransparency = 1,
				Font = FONT_MED,
				Text = "",
				TextSize = TEXT,
				TextColor3 = Theme.TextBright,
				TextXAlignment = Enum.TextXAlignment.Right,
				Parent = row,
			})

			local rail = make("Frame", {
				Position = UDim2.new(0, 0, 0, 20),
				Size = UDim2.new(1, 0, 0, 12),
				BackgroundColor3 = Theme.Track,
				BorderSizePixel = 0,
				Parent = row,
			})
			corner(rail, 2)
			-- Same as the stripes: empty up front, filled in when it arrives.
			local tick = make("ImageLabel", {
				Size = UDim2.new(1, 0, 1, 0),
				BackgroundTransparency = 1,
				ScaleType = Enum.ScaleType.Tile,
				TileSize = UDim2.new(0, 4, 1, 0),
				ImageTransparency = 0.35,
				ZIndex = 2,
				Parent = rail,
			})
			loadImageAsync(tick, TICK_FILE)
			local fill = make("Frame", {
				Size = UDim2.new(0, 0, 1, 0),
				BorderSizePixel = 0,
				ZIndex = 3,
				Parent = rail,
			})
			fill.BackgroundColor3 = Theme.Accent
			corner(fill, 2)

			local function fmt(v)
				local s
				if decimals > 0 then
					s = string.format("%." .. decimals .. "f", v)
				else
					s = tostring(math.floor(v + 0.5))
				end
				return s .. (o.suffix or "")
			end

			local function paint()
				local alpha = (max > min) and (value - min) / (max - min) or 0
				valueLbl.Text = fmt(value)
				valueLbl.TextColor3 = Theme.TextBright
				fill.BackgroundColor3 = Theme.Accent
				fill.Size = UDim2.new(alpha, 0, 1, 0)
				rail.BackgroundColor3 = Theme.Track
			end

			local function set(v, silent)
				v = math.clamp(v, min, max)
				v = min + math.floor((v - min) / step + 0.5) * step
				v = math.clamp(v, min, max)
				if v == value then
					paint()
					return
				end
				value = v
				paint()
				if o.flag then Vision.Flags[o.flag] = value; Vision._scheduleSave() end
				if not silent and o.callback then
					task.spawn(o.callback, value)
				end
			end
			registerRepaint(paint)

			local dragging = false
			local function fromX(x)
				local a = math.clamp((x - rail.AbsolutePosition.X) / math.max(rail.AbsoluteSize.X, 1), 0, 1)
				set(min + a * (max - min))
			end
			row.InputBegan:Connect(function(input)
				local t = input.UserInputType
				if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
					dragging = true
					fromX(input.Position.X)
				end
			end)
			trackConn(UserInputService.InputEnded:Connect(function(input)
				local t = input.UserInputType
				if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
					dragging = false
				end
			end))
			trackConn(UserInputService.InputChanged:Connect(function(input)
				local t = input.UserInputType
				if dragging and (t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch) then
					fromX(input.Position.X)
				end
			end))

			paint()
			if o.flag then Vision.Flags[o.flag] = value; Vision._scheduleSave() end
			bindFlag(o.flag, function(v) set(v, false) end, function() return value end)

			return {
				Row = row,
				Set = set,
				Get = function() return value end,
			}
		end

		function group.Dropdown(o)
			o = o or {}
			local options = o.options or {}
			local multi = o.multi and true or false
			local selected
			local selectedSet = {}
			local savedVal = o.flag and Vision.Flags[o.flag]
			if multi then
				local src = (type(savedVal) == "table" and savedVal) or o.default or {}
				for _, v in ipairs(src) do
					selectedSet[v] = true
				end
			else
				selected = (savedVal ~= nil and savedVal) or o.default or options[1]
			end

			local row = baseRow(26)
			local lbl = make("TextLabel", {
				Size = UDim2.new(1, -130, 1, 0),
				BackgroundTransparency = 1,
				Font = FONT_MED,
				Text = o.text or "Dropdown",
				TextSize = TEXT,
				TextColor3 = Theme.TextBright,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = row,
			})
			registerSearch(o.text or "Dropdown", row)

			local chevBtn = make("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.new(0, 22, 0, 22),
				BackgroundColor3 = Theme.ControlBg,
				BorderSizePixel = 0,
				Parent = row,
			})
			corner(chevBtn, 3)
			local chev = make("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				Size = UDim2.new(0, 11, 0, 11),
				BackgroundTransparency = 1,
				Image = "rbxassetid://124381193435292",
				ImageColor3 = Theme.TextMid,
				ScaleType = Enum.ScaleType.Fit,
				Parent = chevBtn,
			})

			local valBtn = make("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -24, 0.5, 0),
				Size = UDim2.new(0, 86, 0, 22),
				BackgroundColor3 = Theme.ControlBg,
				BorderSizePixel = 0,
				Parent = row,
			})
			corner(valBtn, 3)
			local valLbl = make("TextLabel", {
				Size = UDim2.new(1, -8, 1, 0),
				Position = UDim2.new(0, 4, 0, 0),
				BackgroundTransparency = 1,
				Font = FONT,
				Text = "",
				TextSize = 12,
				TextColor3 = Theme.TextBright,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = valBtn,
			})

			local function current()
				if multi then
					local parts = {}
					for _, opt in ipairs(options) do
						if selectedSet[opt] then parts[#parts + 1] = opt end
					end
					return parts
				end
				return selected
			end

			local function paintValue()
				if multi then
					local parts = current()
					valLbl.Text = #parts > 0 and table.concat(parts, ", ") or "None"
				else
					valLbl.Text = tostring(selected or "None")
				end
			end

			local function push(silent)
				if o.flag then Vision.Flags[o.flag] = current(); Vision._scheduleSave() end
				if not silent and o.callback then
					task.spawn(o.callback, current())
				end
			end

			local open = false
			local function openList()
				open = true
				tween(chev, { Rotation = 180 }, 0.15)
				openOverlay(function(root)
					local wp = win.AbsolutePosition
					local bp = valBtn.AbsolutePosition
					local listW = 130
					local listH = math.min(#options, 8) * 24 + 8
					local x = bp.X - wp.X + valBtn.AbsoluteSize.X - listW + 24
					local y = bp.Y - wp.Y + valBtn.AbsoluteSize.Y + 4
					if y + listH > WIN_ACTUAL_H - FOOTER_H then
						y = bp.Y - wp.Y - listH - 4
					end
					local list = make("ScrollingFrame", {
						Position = UDim2.new(0, x, 0, y),
						Size = UDim2.new(0, listW, 0, listH),
						BackgroundColor3 = Theme.ControlBg,
						BorderSizePixel = 0,
						ScrollBarThickness = 2,
						ScrollBarImageColor3 = Theme.ControlBorder,
						AutomaticCanvasSize = Enum.AutomaticSize.Y,
						CanvasSize = UDim2.new(0, 0, 0, 0),
						ZIndex = 52,
						Parent = root,
					})
					corner(list, 3)
					stroke(list, Theme.ControlBorder, 0.2)
					make("UIListLayout", {
						SortOrder = Enum.SortOrder.LayoutOrder,
						Parent = list,
					})
					make("UIPadding", {
						PaddingTop = UDim.new(0, 4),
						PaddingBottom = UDim.new(0, 4),
						Parent = list,
					})
					for i, opt in ipairs(options) do
						local item = make("TextButton", {
							Size = UDim2.new(1, 0, 0, 24),
							BackgroundTransparency = 1,
							Text = "",
							AutoButtonColor = false,
							LayoutOrder = i,
							ZIndex = 53,
							Parent = list,
						})
						local on = multi and selectedSet[opt] or (opt == selected)
						local il = make("TextLabel", {
							Position = UDim2.new(0, 10, 0, 0),
							Size = UDim2.new(1, -20, 1, 0),
							BackgroundTransparency = 1,
							Font = FONT,
							Text = opt,
							TextSize = 12,
							TextColor3 = on and Theme.Accent or Theme.TextMid,
							TextXAlignment = Enum.TextXAlignment.Left,
							ZIndex = 53,
							Parent = item,
						})
						item.MouseEnter:Connect(function()
							local sel = multi and selectedSet[opt] or (opt == selected)
							if not sel then
								tween(il, { TextColor3 = Theme.TextBright }, 0.1)
							end
						end)
						item.MouseLeave:Connect(function()
							local sel = multi and selectedSet[opt] or (opt == selected)
							if not sel then
								tween(il, { TextColor3 = Theme.TextMid }, 0.1)
							end
						end)
						item.MouseButton1Click:Connect(function()
							if multi then
								selectedSet[opt] = not selectedSet[opt] or nil
								local sel = selectedSet[opt]
								tween(il, { TextColor3 = sel and Theme.Accent or Theme.TextMid }, 0.1)
								paintValue()
								push(false)
							else
								selected = opt
								paintValue()
								push(false)
								closeOverlay()
							end
						end)
					end
				end, function()
					open = false
					tween(chev, { Rotation = 0 }, 0.15)
				end)
			end

			local function clickOpen(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					if open then
						closeOverlay()
					else
						openList()
					end
				end
			end
			valBtn.InputBegan:Connect(clickOpen)
			chevBtn.InputBegan:Connect(clickOpen)

			paintValue()
			push(true)
			bindFlag(o.flag, function(v)
				if multi and type(v) == "table" then
					selectedSet = {}
					for _, x in ipairs(v) do selectedSet[x] = true end
				elseif not multi then
					selected = v
				end
				paintValue()
				push(false)
			end, current)

			return {
				Row = row,
				Set = function(v)
					if multi and type(v) == "table" then
						selectedSet = {}
						for _, x in ipairs(v) do selectedSet[x] = true end
					elseif not multi then
						selected = v
					end
					paintValue()
					push(false)
				end,
				Get = current,
				Refresh = function(newOptions)
					options = newOptions or options
					local changed = false
					if multi then
						local keep = {}
						for _, opt in ipairs(options) do
							if selectedSet[opt] then keep[opt] = true end
						end
						for opt in pairs(selectedSet) do
							if not keep[opt] then changed = true end
						end
						selectedSet = keep
					elseif selected ~= nil then
						local found = false
						for _, opt in ipairs(options) do
							if opt == selected then
								found = true
								break
							end
						end
						if not found then
							selected = options[1]
							changed = true
						end
					end
					paintValue()
					if changed then push(false) end
				end,
			}
		end

		function group.Color(o)
			o = o or {}
			local ch, cs, cv = 0, 1, 1
			local savedClr = o.flag and Vision.Flags[o.flag]
			local initClr = (typeof(savedClr) == "Color3" and savedClr) or o.default
			if typeof(initClr) == "Color3" then
				ch, cs, cv = initClr:ToHSV()
			end

			local row = baseRow(22)
			make("TextLabel", {
				Size = UDim2.new(1, -60, 1, 0),
				BackgroundTransparency = 1,
				Font = FONT_MED,
				Text = o.text or "Color",
				TextSize = TEXT,
				TextColor3 = Theme.TextBright,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = row,
			})
			registerSearch(o.text or "Color", row)
			local swatch = make("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.new(0, 24, 0, 14),
				BackgroundColor3 = Color3.fromHSV(ch, cs, cv),
				BorderSizePixel = 0,
				Parent = row,
			})
			corner(swatch, 2)
			stroke(swatch, Theme.ControlBorder, 0.2)

			local function color()
				return Color3.fromHSV(ch, cs, cv)
			end

			local function push(silent)
				if o.flag then Vision.Flags[o.flag] = color(); Vision._scheduleSave() end
				if not silent and o.callback then
					task.spawn(o.callback, color())
				end
			end

			swatch.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					openHuePopup(swatch, function() return ch end, function(h)
						ch, cs, cv = h, 1, 1
						swatch.BackgroundColor3 = color()
						push(false)
					end)
				end
			end)

			push(true)
			bindFlag(o.flag, function(v)
				if typeof(v) == "Color3" then
					ch, cs, cv = v:ToHSV()
					swatch.BackgroundColor3 = color()
					push(false)
				end
			end, color)

			return {
				Row = row,
				Set = function(c)
					ch, cs, cv = c:ToHSV()
					swatch.BackgroundColor3 = color()
					push(false)
				end,
				Get = color,
			}
		end

		function group.Button(o)
			o = o or {}
			local row = baseRow(28)
			local btn = make("Frame", {
				Size = UDim2.new(1, 0, 0, 24),
				Position = UDim2.new(0, 0, 0, 2),
				BackgroundColor3 = Theme.ControlBg,
				BorderSizePixel = 0,
				Parent = row,
			})
			corner(btn, 3)
			local btnStroke = stroke(btn, Theme.ControlBorder, 0.3)
			local lbl = make("TextLabel", {
				Size = UDim2.new(1, 0, 1, 0),
				BackgroundTransparency = 1,
				Font = FONT_MED,
				Text = o.text or "Button",
				TextSize = 12,
				TextColor3 = Theme.TextBright,
				Parent = btn,
			})
			registerSearch(o.text or "Button", row)

			btn.MouseEnter:Connect(function()
				tween(btnStroke, { Color = Theme.Accent, Transparency = 0.2 }, 0.12)
			end)
			btn.MouseLeave:Connect(function()
				tween(btnStroke, { Color = Theme.ControlBorder, Transparency = 0.3 }, 0.15)
			end)
			btn.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					tween(lbl, { TextColor3 = Theme.Accent }, 0.06)
					task.delay(0.12, function()
						tween(lbl, { TextColor3 = Theme.TextBright }, 0.2)
					end)
					if o.callback then
						task.spawn(o.callback)
					end
				end
			end)

			return { Row = row }
		end

		function group.Textbox(o)
			o = o or {}
			local row = baseRow(26)
			-- Text only accepts a string, and a flag restored from an older config
			-- can hold a number or a boolean: coerce it instead of throwing halfway
			-- through the row.
			local initText = o.flag and Vision.Flags[o.flag]
			if initText == nil then initText = o.default end
			if initText == nil then initText = "" end
			initText = tostring(initText)
			if o.text then
				make("TextLabel", {
					Size = UDim2.new(1, -130, 1, 0),
					BackgroundTransparency = 1,
					Font = FONT_MED,
					Text = o.text,
					TextSize = TEXT,
					TextColor3 = Theme.TextBright,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = row,
				})
				registerSearch(o.text, row)
			end
			local boxW = o.text and 112 or 0
			local box = make("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = o.text and UDim2.new(0, boxW, 0, 22) or UDim2.new(1, 0, 0, 22),
				BackgroundColor3 = Theme.ControlBg,
				BorderSizePixel = 0,
				Parent = row,
			})
			corner(box, 3)
			local boxStroke = stroke(box, Theme.ControlBorder, 0.3)
			local input = make("TextBox", {
				Position = UDim2.new(0, 6, 0, 0),
				Size = UDim2.new(1, -12, 1, 0),
				BackgroundTransparency = 1,
				Font = FONT,
				Text = initText,
				PlaceholderText = o.placeholder or "",
				PlaceholderColor3 = Theme.TextDim,
				TextSize = 12,
				TextColor3 = Theme.TextBright,
				TextXAlignment = Enum.TextXAlignment.Left,
				ClearTextOnFocus = false,
				Parent = box,
			})

			local function setText(t, silent)
				input.Text = tostring(t == nil and "" or t)
				if o.flag then Vision.Flags[o.flag] = input.Text; Vision._scheduleSave() end
				if not silent and o.callback then
					task.spawn(o.callback, input.Text, false)
				end
			end

			input.Focused:Connect(function()
				tween(boxStroke, { Color = Theme.Accent, Transparency = 0.1 }, 0.1)
			end)
			input.FocusLost:Connect(function(enter)
				tween(boxStroke, { Color = Theme.ControlBorder, Transparency = 0.3 }, 0.12)
				if o.flag then Vision.Flags[o.flag] = input.Text; Vision._scheduleSave() end
				if o.callback then
					task.spawn(o.callback, input.Text, enter)
				end
			end)

			if o.flag then Vision.Flags[o.flag] = input.Text; Vision._scheduleSave() end
			bindFlag(o.flag, function(v) setText(v, false) end, function() return input.Text end)

			return {
				Row = row,
				Set = function(t) setText(t) end,
				Get = function() return input.Text end,
			}
		end
	end

	function openHuePopup(anchor, getHue, setHue)
		openOverlay(function(root)
			local wp = win.AbsolutePosition
			local ap = anchor.AbsolutePosition
			local popW, popH = 170, 40
			local x = math.clamp(ap.X - wp.X + anchor.AbsoluteSize.X - popW, 8, WIN_W - popW - 8)
			local y = ap.Y - wp.Y + anchor.AbsoluteSize.Y + 6
			if y + popH > WIN_ACTUAL_H - FOOTER_H then
				y = ap.Y - wp.Y - popH - 6
			end
			local pop = make("Frame", {
				Position = UDim2.new(0, x, 0, y),
				Size = UDim2.new(0, popW, 0, popH),
				BackgroundColor3 = Theme.ControlBg,
				BorderSizePixel = 0,
				ZIndex = 52,
				Parent = root,
			})
			corner(pop, 3)
			stroke(pop, Theme.ControlBorder, 0.2)

			local rail = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				Size = UDim2.new(1, -20, 0, 10),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BorderSizePixel = 0,
				ZIndex = 53,
				Parent = pop,
			})
			corner(rail, 3)
			make("UIGradient", {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
					ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
					ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
					ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
					ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
					ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
					ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
				}),
				Parent = rail,
			})
			local knob = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(getHue(), 0, 0.5, 0),
				Size = UDim2.new(0, 6, 0, 14),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BorderSizePixel = 0,
				ZIndex = 54,
				Parent = rail,
			})
			corner(knob, 2)
			stroke(knob, Color3.fromRGB(20, 20, 22), 0)

			local dragging = false
			local function fromX(px)
				local a = math.clamp((px - rail.AbsolutePosition.X) / math.max(rail.AbsoluteSize.X, 1), 0, 1)
				knob.Position = UDim2.new(a, 0, 0.5, 0)
				setHue(a)
			end
			pop.InputBegan:Connect(function(input)
				local t = input.UserInputType
				if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
					dragging = true
					fromX(input.Position.X)
				end
			end)
			local moveConn = UserInputService.InputChanged:Connect(function(input)
				local t = input.UserInputType
				if dragging and (t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch) then
					fromX(input.Position.X)
				end
			end)
			local upConn = UserInputService.InputEnded:Connect(function(input)
				local t = input.UserInputType
				if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
					dragging = false
				end
			end)
			popupCleanup = function()
				pcall(function() moveConn:Disconnect() end)
				pcall(function() upConn:Disconnect() end)
			end
		end, function()
			if popupCleanup then
				popupCleanup()
				popupCleanup = nil
			end
		end)
	end

	local searchToken = 0
	local searchOpenFlag = false

	local function flashRow(row)
		local hl = make("Frame", {
			Size = UDim2.new(1, 8, 1, 4),
			Position = UDim2.new(0, -4, 0, -2),
			BackgroundColor3 = Theme.Accent,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = 0,
			Parent = row,
		})
		corner(hl, 3)
		task.spawn(function()
			for _ = 1, 2 do
				tween(hl, { BackgroundTransparency = 0.75 }, 0.16)
				task.wait(0.2)
				tween(hl, { BackgroundTransparency = 1 }, 0.22)
				task.wait(0.26)
			end
			hl:Destroy()
		end)
	end

	local function runSearch(q)
		q = string.lower(q or "")
		if q == "" then
			if searchOpenFlag then
				searchOpenFlag = false
				closeOverlay()
			end
			return
		end
		searchToken = searchToken + 1
		local myToken = searchToken
		local hits = {}
		for _, e in ipairs(searchIndex) do
			if string.find(string.lower(e.text), q, 1, true) or string.find(string.lower(e.group.Name), q, 1, true) then
				hits[#hits + 1] = e
				if #hits >= 8 then break end
			end
		end
		openOverlay(function(root)
			local listH = math.max(#hits, 1) * 26 + 8
			local list = make("Frame", {
				Position = UDim2.new(0, MARGIN + 56, 0, TOPBAR_H - 6),
				Size = UDim2.new(0, 240, 0, listH),
				BackgroundColor3 = Theme.ControlBg,
				BorderSizePixel = 0,
				ZIndex = 52,
				Parent = root,
			})
			corner(list, 3)
			stroke(list, Theme.ControlBorder, 0.2)
			make("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				Parent = list,
			})
			make("UIPadding", {
				PaddingTop = UDim.new(0, 4),
				PaddingBottom = UDim.new(0, 4),
				Parent = list,
			})
			if #hits == 0 then
				make("TextLabel", {
					Size = UDim2.new(1, 0, 0, 26),
					BackgroundTransparency = 1,
					Font = FONT,
					Text = "No results",
					TextSize = 12,
					TextColor3 = Theme.TextDim,
					ZIndex = 53,
					Parent = list,
				})
			end
			for i, e in ipairs(hits) do
				local item = make("TextButton", {
					Size = UDim2.new(1, 0, 0, 26),
					BackgroundTransparency = 1,
					Text = "",
					AutoButtonColor = false,
					LayoutOrder = i,
					ZIndex = 53,
					Parent = list,
				})
				local il = make("TextLabel", {
					Position = UDim2.new(0, 10, 0, 0),
					Size = UDim2.new(1, -20, 1, 0),
					BackgroundTransparency = 1,
					Font = FONT,
					Text = e.tab.Name .. "  >  " .. e.group.Name .. "  >  " .. e.text,
					TextSize = 12,
					TextColor3 = Theme.TextMid,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					ZIndex = 53,
					Parent = item,
				})
				item.MouseEnter:Connect(function()
					tween(il, { TextColor3 = Theme.TextBright }, 0.1)
				end)
				item.MouseLeave:Connect(function()
					tween(il, { TextColor3 = Theme.TextMid }, 0.1)
				end)
				item.MouseButton1Click:Connect(function()
					searchOpenFlag = false
					searchBox.Text = ""
					closeOverlay()
					setActiveTab(e.tab)
					task.delay(0.05, function()
						local page = e.tab.Page
						local rowY = e.row.AbsolutePosition.Y - page.AbsolutePosition.Y + page.CanvasPosition.Y
						page.CanvasPosition = Vector2.new(0, math.max(0, rowY - 80))
						flashRow(e.row)
					end)
				end)
			end
		end, function()
			if myToken == searchToken then
				searchOpenFlag = false
			end
		end)
		searchOpenFlag = true
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		runSearch(searchBox.Text)
	end)

	local menuVisible = true
	local fadeCache = nil
	local fadeLock = 0

	-- Menu cursor state. setMenuVisible() pokes this on every transition; the
	-- render hold applies -- and keeps re-applying -- the free state while the
	-- window is up, because the first-person camera re-locks the cursor on its
	-- own between frames. Opening is left to the next render step so a state
	-- still being handed back by a dying previous window is already in place
	-- when this window takes its snapshot.
	local function cursorUpdate()
		if not destroyed and cursorWanted and win.Visible then
			cursorUnlock()
		else
			cursorRestore()
		end
	end
	local cursorHoldConn = nil
	local cursorAncestryConn = nil
	local function cursorHalt()
		if cursorHoldConn then
			pcall(function() cursorHoldConn:Disconnect() end)
			cursorHoldConn = nil
		end
		if cursorAncestryConn then
			pcall(function() cursorAncestryConn:Disconnect() end)
			cursorAncestryConn = nil
		end
	end
	local function cursorOrphaned()
		-- A newer execution's cleanup destroys this window's GUI without ever
		-- calling Destroy(): hand the cursor back instead of holding it forever.
		cursorRestore()
		cursorHalt()
	end
	local function cursorSet(free)
		cursorWanted = free == true
		if not cursorWanted then
			cursorUpdate()  -- closing: put the captured state back right away
		end
	end
	-- The frame's own unparenting is the test: an ancestor being destroyed
	-- clears every descendant's parent in turn, this one included.
	cursorAncestryConn = trackConn(win.AncestryChanged:Connect(function()
		if win.Parent == nil then cursorOrphaned() end
	end))
	if RunService then
		cursorHoldConn = trackConn(RunService.RenderStepped:Connect(function()
			if win.Parent == nil then
				cursorOrphaned()  -- fallback for the ancestry signal above
				return
			end
			if cursorWanted or cursorSaved ~= nil then
				cursorUpdate()
			end
		end))
	end

	local function setMenuVisible(v)
		if v == menuVisible then return end
		if os.clock() < fadeLock then return end
		fadeLock = os.clock() + 0.2
		menuVisible = v
		if not v then
			cursorSet(false)
			closeOverlay()
			hideTooltip()
			-- Kill any in-flight tab stagger: its pending frame callbacks would
			-- otherwise fade content back in while the menu is closing and leave
			-- a stale fade cache for the next open.
			switchGen = switchGen + 1
			if activeTab then restorePage(activeTab) end
			fadeCache = collectFade(win)
			for _, e in ipairs(fadeCache) do
				tween(e.inst, { [e.prop] = 1 }, 0.14)
			end
			task.delay(0.15, function()
				if not menuVisible then
					win.Visible = false
				end
			end)
			pcall(Vision._blurClose)
		else
			win.Visible = true
			cursorSet(true)
			if fadeCache then
				for _, e in ipairs(fadeCache) do
					tween(e.inst, { [e.prop] = e.value }, 0.16)
				end
			end
			pcall(Vision._blurOpen)
		end
	end

function self.ToggleMenu()
	if isKeyLocked() then return end
	setMenuVisible(not menuVisible)
	end
function self.SetMenuVisible(v)
	if isKeyLocked() then return end
	setMenuVisible(v and true or false)
	end
	function self.SetMenuKey(kc)
		if typeof(kc) == "EnumItem" then
			menuKey = kc
		elseif type(kc) == "string" and kc ~= "" and kc ~= "None" then
			local ok, parsed = pcall(function() return Enum.KeyCode[kc] end)
			if ok and parsed then
				menuKey = parsed
			else
				return
			end
		else
			return
		end
		Vision.Flags["menu_key"] = menuKey.Name
		Vision._scheduleSave()
		pcall(function()
			menuKeyLbl.Text = "Key: " .. keyName(menuKey)
		end)
	end

	-- ================================================================
	-- Stats card
	-- ----------------------------------------------------------------
	-- A companion panel docked to the window's left edge: a second frame of the
	-- same UI, half the window's size, reading the game's own leaderboard.
	-- Every player gets a row -- avatar, name, then one column per leaderstat --
	-- ordered by the column in use and kept current while the panel is visible.
	-- Clicking a column header orders by that stat, and a second click flips the
	-- direction.
	-- It is a child of the window, so the fade, the theme repaint, the menu
	-- key's visibility and Destroy() already carry it along -- there is no
	-- second switch that could leave the panel behind or show it alone. The
	-- window only has to know how far the card reaches left so the drag clamp
	-- keeps the whole cluster on screen; the card's header is a second drag
	-- handle, so the pair moves as one either way.
	-- ================================================================
	local CARD_GAP = 12
	local CARD_PAD = 10
	local CARD_HEAD = 32
	local CARD_COLH = 22
	local CARD_ROW = 26
	local CARD_AVATAR = 20
	-- The rank gutter, the "you" strip, and the room a scrollbar needs so a
	-- right-aligned number never slides underneath it.
	local CARD_RANK_W = 20
	local CARD_SELF_H = 24
	local CARD_SCROLL = 6
		local CARD_MIN_W = 180
	-- How close to a docked position a dropped card has to land before the dock
	-- takes it back. Big enough to catch a throw, small enough that a card parked
	-- beside the window is left alone.
	local CARD_SNAP = 26
	-- Folders a game may file its leaderboard under, lowercased. leaderstats is
	-- the convention; the rest are common enough to be worth reading.
	local CARD_STAT_FOLDERS = {
		leaderstats = true, stats = true, leaderboard = true, scoreboard = true,
	}

	local activeCard = nil

	-- One hairline, used under the card header, under the column header and
	-- under every player row -- the ruled paper that separates the info.
	local function cardLine(parent)
		return make("Frame", {
			Name = "Line",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = Theme.ControlBorder,
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			Parent = parent,
		})
	end

	-- The leaderboard as the game itself keeps it: every player, every child of
	-- their leaderstats folder, read live. Nothing about the stats is assumed --
	-- the columns are whatever the game actually publishes, in the order it
	-- publishes them.
	local function leaderboardRows(copts, cap, sort)
		local players = {}
		pcall(function()
			if Players then players = Players:GetPlayers() end
		end)
		local me = localPlayer()
		local seen, columns, rows = {}, {}, {}

		local function statsOf(plr)
			local folder, fallback = nil, nil
			pcall(function()
				for _, ch in ipairs(plr:GetChildren()) do
					if CARD_STAT_FOLDERS[string.lower(ch.Name)] then
						if #(ch:GetChildren()) > 0 then
							folder = ch
							break
						end
						fallback = fallback or ch
					end
				end
				if not folder then folder = fallback end
				if not folder then folder = plr:FindFirstChild("leaderstats", true) end
			end)
			local list = {}
			if folder then
				pcall(function()
					for _, ch in ipairs(folder:GetChildren()) do
						local ok, v = pcall(function() return ch.Value end)
						if ok and v ~= nil then
							list[#list + 1] = { name = ch.Name, value = v }
						end
					end
				end)
			end
			return list
		end

		for _, plr in ipairs(players) do
			local values = {}
			for _, st in ipairs(statsOf(plr)) do
				values[st.name] = st.value
				if not seen[st.name] then
					seen[st.name] = true
					columns[#columns + 1] = st.name
				end
			end
			local name = nil
			pcall(function() name = plr.DisplayName end)
			if type(name) ~= "string" or name == "" then
				pcall(function() name = plr.Name end)
			end
			rows[#rows + 1] = {
				name = name or "?",
				image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", plr.UserId or 0),
				values = values,
				highlight = plr == me,
			}
		end

		-- An explicit stats list wins: those columns, in that order, matched
		-- case-insensitively against what the game published.
		if type(copts.stats) == "table" and #copts.stats > 0 then
			local lower = {}
			for _, col in ipairs(columns) do
				lower[string.lower(col)] = col
			end
			local picked = {}
			for _, nm in ipairs(copts.stats) do
				if type(nm) == "string" then
					picked[#picked + 1] = lower[string.lower(nm)] or nm
				end
			end
			if #picked > 0 then
				columns = picked
			end
		end

		-- Order the table: the chosen stat descending where it is numeric,
		-- names otherwise -- deterministic either way.
		local sortBy = (sort and sort.col) or copts.sortBy or columns[1]
		local descending = not (sort and sort.desc == false)
		local function keyOf(row)
			local v = sortBy and row.values[sortBy] or nil
			if type(v) == "number" then return v end
			return tonumber(tostring(v or ""))
		end
		table.sort(rows, function(a, b)
			local av, bv = keyOf(a), keyOf(b)
			if av and bv and av ~= bv then
				if descending then return av > bv end
				return av < bv
			end
			if av and not bv then return true end
			if bv and not av then return false end
			return string.lower(tostring(a.name)) < string.lower(tostring(b.name))
		end)

		if #columns > cap then
			local trimmed = {}
			for i = 1, cap do
				trimmed[i] = columns[i]
			end
			columns = trimmed
		end
		return columns, rows
	end

	function self.Card(copts)
		-- Copied, not borrowed: SetSort and SetStats write back into these
		-- options, and the caller's table is not ours to change.
		local given = type(copts) == "table" and copts or {}
		copts = {}
		for k, v in pairs(given) do
			copts[k] = v
		end
		if activeCard then
			pcall(function() activeCard.Destroy() end)
			activeCard = nil
		end

		-- Size: half the window unless the caller overrides it, and never wider
		-- than the room actually available beside the window.
		local winW, winH = WIN_W, WIN_ACTUAL_H
		pcall(function()
			local sz = win.AbsoluteSize
			if sz and sz.X > 1 and sz.Y > 1 then
				winW, winH = sz.X, sz.Y
			end
		end)
		-- The same viewport source windowRect() centres against: the camera's, so
		-- the pair is centred by the same numbers the window itself was. The
		-- screen falls back in only if the camera cannot report one.
		local vpX, vpY = 1280, 720
		local vpFromCam = false
		pcall(function()
			local cam = workspace and workspace.CurrentCamera
			if cam and cam.ViewportSize and cam.ViewportSize.X > 100 then
				vpX, vpY = cam.ViewportSize.X, cam.ViewportSize.Y
				vpFromCam = true
			end
		end)
		pcall(function()
			if vpFromCam then return end
			local vp = screen.AbsoluteSize
			if vp and vp.X > 1 and vp.Y > 1 then
				vpX, vpY = vp.X, vp.Y
			end
		end)

		local cardW = tonumber(copts.width) or math.floor(winW / 2)
		local cardH = tonumber(copts.height) or math.floor(winH / 2)
		cardW = math.max(CARD_MIN_W, math.min(cardW, vpX - winW - CARD_GAP - 24))
		cardH = math.max(150, cardH)

		-- The card is a panel in its own right: it moves when it is dragged and
		-- not when the window is, and the window's position offsets are the
		-- origin everything here is expressed in, because the card is a child of
		-- the window. Screen pixels go in and out through placeCard, so there is
		-- exactly one place where the two spaces meet.
		local dockSide = (copts.side == "right") and "right" or "left"
		local docked = true
		local function dockOffsetX(side, w)
			-- Window-relative x that puts the card hard against one of the window's
			-- edges, a gap away from it.
			if side == "right" then return winW + CARD_GAP end
			return -(w + CARD_GAP)
		end
		-- The window only counts an overhang while the card is actually docked: a
		-- floating card is not the window's business, and the window's clamp must
		-- not pretend the cluster is bigger than it is.
		local function applyExtent()
			if not self.SetDragExtent then return end
			if not docked then
				self.SetDragExtent(0, 0, 0)
			elseif dockSide == "right" then
				self.SetDragExtent(CARD_GAP + cardW, 0, 0)
			else
				self.SetDragExtent(0, 0, CARD_GAP + cardW)
			end
		end

		-- Declared before the placement helpers close over them, and the panel
		-- built just below: nothing can position a frame that does not exist, and
		-- a name read by a helper has to be a local by the time it is written.
		local cardGui
		local cardGone = false
		local cardX = dockOffsetX(dockSide, cardW)
		local cardY = 0
		local cardDragging = false
		local cardToken = nil
		local cardGrabX, cardGrabY = 0, 0

		-- Where the card is allowed to be, in the same window-relative offsets:
		-- the viewport, with a margin off every edge. One definition, so "on
		-- screen" means the same thing to the drag, to the tick and to the dock.
		local CARD_EDGE = 10
		local function boundsX()
			local wx = win.Position.X.Offset
			return CARD_EDGE - wx, math.max(CARD_EDGE - wx, vpX - CARD_EDGE - cardW - wx)
		end
		local function boundsY()
			local wy = win.Position.Y.Offset
			return CARD_EDGE - wy, math.max(CARD_EDGE - wy, vpY - CARD_EDGE - cardH - wy)
		end

		-- Whole pixels, wholly inside those bounds. Nothing reads the frame's own
		-- layout: its screen rect is the window's offsets plus its own, which is
		-- arithmetic that cannot be a frame behind a drag in progress. Screen
		-- pixels come in, offsets go out -- the one place the two spaces meet.
		local function placeCard(absX, absY)
			local wx, wy = win.Position.X.Offset, win.Position.Y.Offset
			local lx, hx = boundsX()
			local ly, hy = boundsY()
			local x = math.clamp(math.floor(absX - wx), lx, hx)
			local y = math.clamp(math.floor(absY - wy), ly, hy)
			cardX, cardY = x, y
			cardGui.Position = UDim2.fromOffset(x, y)
		end

		-- A window drag carries the card along, because the card is a child frame,
		-- so the window can push the card past an edge without the card ever being
		-- touched. Pull it back the moment that happens: a panel that is off
		-- screen is a panel that cannot be grabbed and dragged back. The cost of
		-- the tick is one comparison per edge, and it writes nothing at all while
		-- the card is where it should be.
		local function keepOnScreen()
			if cardDragging or cardGone or destroyed or not cardGui.Parent then return end
			local lx, hx = boundsX()
			local ly, hy = boundsY()
			if cardX >= lx and cardX <= hx and cardY >= ly and cardY <= hy then return end
			placeCard(win.Position.X.Offset + cardX, win.Position.Y.Offset + cardY)
		end

		-- Docked by default, hanging out of the window's edge exactly CARD_GAP:
		-- one frame of the same UI, carrying the same theme, fade and lifetime.
		cardGui = make("Frame", {
			Name = "StatsCard",
			Position = UDim2.fromOffset(cardX, cardY),
			Size = UDim2.fromOffset(cardW, cardH),
			BackgroundColor3 = Theme.PanelBg,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Parent = win,
		})
		corner(cardGui, 6)
		stroke(cardGui, Theme.ControlBorder, 0.35)

		local head = make("Frame", {
			Name = "Head",
			Size = UDim2.new(1, 0, 0, CARD_HEAD),
			BackgroundColor3 = Theme.AccentDark,
			BorderSizePixel = 0,
			Parent = cardGui,
		})
		cardLine(head)

		-- Three dots: the bar below really is what moves the panel, and the panel
		-- really does move on its own. A handle nobody can see is not a handle.
		for gi = 0, 2 do
			local dot = make("Frame", {
				Name = "Grip",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, CARD_PAD + 1, 0.5, (gi - 1) * 7),
				Size = UDim2.fromOffset(3, 3),
				BackgroundColor3 = Theme.HeaderText,
				BackgroundTransparency = 0.45,
				BorderSizePixel = 0,
				Parent = head,
			})
			corner(dot, 99)
		end

		local titleLbl = make("TextLabel", {
			Position = UDim2.new(0, CARD_PAD + 14, 0, 0),
			Size = UDim2.new(1, -(CARD_PAD * 2 + 84 + 14), 1, 0),
			BackgroundTransparency = 1,
			Font = FONT_BOLD,
			Text = tostring(copts.title or "Leaderboard"),
			TextSize = 13,
			TextColor3 = Theme.HeaderText,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = head,
		})
		local countLbl = nil
		if copts.count ~= false then
			countLbl = make("TextLabel", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -CARD_PAD, 0.5, 0),
				Size = UDim2.new(0, 80, 1, 0),
				BackgroundTransparency = 1,
				Font = FONT_MED,
				Text = "",
				TextSize = 11,
				TextColor3 = Theme.TextBright,
				TextTransparency = 0.2,
				TextXAlignment = Enum.TextXAlignment.Right,
				Parent = head,
			})
		end

		-- The local player's own line: avatar, their rank out of the room, and the
		-- value of the stat the table is ordered by. Built once and shown only
		-- when there is something true to put in it.
		local selfPill = make("Frame", {
			Name = "You",
			Position = UDim2.new(0, 0, 0, CARD_HEAD),
			Size = UDim2.new(1, 0, 0, CARD_SELF_H),
			BackgroundColor3 = Theme.Accent,
			BackgroundTransparency = 0.9,
			BorderSizePixel = 0,
			Visible = false,
			Parent = cardGui,
		})
		cardLine(selfPill)
		local selfAv = make("ImageLabel", {
			Name = "YouAvatar",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, CARD_PAD, 0.5, 0),
			Size = UDim2.fromOffset(16, 16),
			BackgroundColor3 = Theme.ControlBg,
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			Image = "",
			Parent = selfPill,
		})
		corner(selfAv, 99)
		local selfLbl = make("TextLabel", {
			Name = "YouLabel",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, CARD_PAD + 22, 0.5, 0),
			Size = UDim2.new(1, -(CARD_PAD * 2 + 22 + 66), 1, 0),
			BackgroundTransparency = 1,
			Font = FONT_MED,
			Text = "",
			TextSize = 11,
			TextColor3 = Theme.TextBright,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = selfPill,
		})
		local selfVal = make("TextLabel", {
			Name = "YouValue",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -CARD_PAD, 0.5, 0),
			Size = UDim2.new(0, 62, 1, 0),
			BackgroundTransparency = 1,
			Font = FONT_MED,
			Text = "",
			TextSize = 11,
			TextColor3 = Theme.TextWhite,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = selfPill,
		})

		local colHead = make("Frame", {
			Name = "ColHead",
			Position = UDim2.new(0, 0, 0, CARD_HEAD),
			Size = UDim2.new(1, 0, 0, CARD_COLH),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = cardGui,
		})
		local colLine = cardLine(colHead)

		local list = make("ScrollingFrame", {
			Name = "List",
			Position = UDim2.new(0, 0, 0, CARD_HEAD + CARD_COLH),
			Size = UDim2.new(1, 0, 1, -(CARD_HEAD + CARD_COLH)),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 2,
			ScrollBarImageColor3 = Theme.ControlBorder,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			Parent = cardGui,
		})

		-- What a column header means, in words: a card that sorts is a card that
		-- has to say what it is sorting by. The hint is a child of the card, not
		-- of the window, so it can never be clipped away from the columns it
		-- describes. It takes the column header's own band while a header is
		-- under the pointer: the labels are what the pointer is already on, and
		-- the rows -- which are the point of the card -- stay readable.
		local hint = make("Frame", {
			Name = "Hint",
			Position = UDim2.new(0, CARD_PAD, 0, CARD_HEAD),
			Size = UDim2.new(1, -CARD_PAD * 2, 0, 22),
			BackgroundColor3 = Theme.ControlBg,
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 5,
			Parent = cardGui,
		})
		corner(hint, 3)
		stroke(hint, Theme.ControlBorder, 0.25)
		local hintLbl = make("TextLabel", {
			Size = UDim2.new(1, -CARD_PAD * 2, 1, 0),
			Position = UDim2.new(0, CARD_PAD, 0, 0),
			BackgroundTransparency = 1,
			Font = FONT,
			Text = "",
			TextSize = 11,
			TextColor3 = Theme.TextBright,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 5,
			Parent = hint,
		})

		-- The three stacked bands move together when the "you" line is present or
		-- absent, so the column header always sits directly on top of the rows it
		-- labels, whatever the card has to show.
		local function placeChrome(hasSelf)
			local top = CARD_HEAD + (hasSelf and CARD_SELF_H or 0)
			selfPill.Visible = hasSelf and true or false
			colHead.Position = UDim2.new(0, 0, 0, top)
			list.Position = UDim2.new(0, 0, 0, top + CARD_COLH)
			list.Size = UDim2.new(1, 0, 1, -(top + CARD_COLH))
			hint.Position = UDim2.new(0, CARD_PAD, 0, top)
		end

		-- Column geometry: a rank gutter, a name cell holding the avatar, then the
		-- stat columns sharing what is left. The card is half the window, so at
		-- most four stat columns fit at the default size; the name cell gives way
		-- first -- down to its floor -- before anything is trimmed, and only past
		-- that does leaderboardRows(cap) drop the extra stats. The scrollbar keeps
		-- a strip of its own, so a right-aligned number never runs under it.
		local bodyW = cardW - CARD_PAD * 2 - CARD_SCROLL
		local availW = bodyW - CARD_RANK_W
		local maxCols = math.max(1, math.floor(bodyW / 56) - 1)
		maxCols = math.max(1, math.min(maxCols, tonumber(copts.maxColumns) or 5))

		local function fmt(v)
			if v == nil then return "—" end
			if type(v) == "number" then
				if v ~= v then return "—" end
				if v ~= math.floor(v) then
					return string.format("%.1f", v)
				end
				return tostring(math.floor(v))
			end
			local s = tostring(v)
			if s == "" then return "—" end
			return s
		end

		local function signature(columns, rows)
			local parts = { tostring(#columns) }
			for _, col in ipairs(columns) do
				parts[#parts + 1] = col
			end
			for _, row in ipairs(rows) do
				parts[#parts + 1] = row.name
				for _, col in ipairs(columns) do
					parts[#parts + 1] = tostring(row.values[col])
				end
			end
			return table.concat(parts, "\30")
		end

		-- Which column the table is ordered by, and in which direction. Read on
		-- every draw, so a click on a header cell reorders the table in place.
		local sort = { col = copts.sortBy, desc = copts.sortDescending ~= false }

		-- What a header means, in words: a table that sorts has to be able to say
		-- what it is sorted by and what a click would do about it.
		local function hintFor(columns, col)
			local active = (sort.col or columns[1]) == col
			if not active then
				return "Click to sort by " .. tostring(col) .. "."
			end
			local way = sort.desc and "high to low" or "low to high"
			if sort.col == col then
				return string.format("%s — sorted %s. Click again to reverse it.", col, way)
			end
			return string.format("%s — sorted %s.", col, way)
		end
		-- Assigned once refresh() exists; draw() only ever calls it on a click.
		local setSort = nil
		local lastSig = nil

		local function draw(columns, rows)
			for _, ch in ipairs(colHead:GetChildren()) do
				if ch ~= colLine then
					pcall(function() ch:Destroy() end)
				end
			end
			for _, ch in ipairs(list:GetChildren()) do
				pcall(function() ch:Destroy() end)
			end
			-- The hint was anchored to a cell that no longer exists, so it goes
			-- with it -- a hint left standing over a table nobody is pointing at
			-- would be a lie about what is under the pointer.
			hint.Visible = false

			-- Rows are a fixed height, so the scroll range is exact and needs no
			-- automatic measuring -- every row is reachable however long the table
			-- gets.
			list.CanvasSize = UDim2.new(0, 0, 0, #rows * CARD_ROW)

			local shown = math.max(1, #columns)
			local nameW = math.clamp(math.floor(availW * 0.36), 88, 132)
			if shown * 56 + nameW > availW then
				nameW = math.max(88, availW - shown * 56)
			end
			local colW = math.floor((availW - nameW) / shown)
			-- Every column past the rank gutter and the name cell starts here.
			local statX = CARD_PAD + CARD_RANK_W + nameW
			local numeric = {}
			for _, col in ipairs(columns) do
				local allNum, any = true, false
				for _, row in ipairs(rows) do
					local v = row.values[col]
					if v ~= nil and v ~= "" then
						any = true
						if tonumber(tostring(v)) == nil then
							allNum = false
							break
						end
					end
				end
				numeric[col] = any and allNum
			end

			if #columns > 0 then
				-- The gutter and the name cell are labels, not controls: there is
				-- nothing to order by in either of them.
				make("TextLabel", {
					Position = UDim2.new(0, CARD_PAD, 0, 0),
					Size = UDim2.new(0, CARD_RANK_W, 1, 0),
					BackgroundTransparency = 1,
					Font = FONT_MED,
					Text = "#",
					TextSize = 10,
					TextColor3 = Theme.TextDim,
					TextXAlignment = Enum.TextXAlignment.Center,
					Parent = colHead,
				})
				make("TextLabel", {
					Position = UDim2.new(0, CARD_PAD + CARD_RANK_W, 0, 0),
					Size = UDim2.new(0, nameW, 1, 0),
					BackgroundTransparency = 1,
					Font = FONT_MED,
					Text = "Player",
					TextSize = 10,
					TextColor3 = Theme.TextDim,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = colHead,
				})
				for i, col in ipairs(columns) do
					-- A column header is a button wearing a label's clothes: it orders
					-- the table by that stat, and a second click on the column already
					-- in use flips the direction.
					--
					-- With no explicit choice yet the game's first stat is the one in
					-- use, so that is the column that wears the mark: an accent rule
					-- under the label rather than an arrow glyph, because a glyph
					-- depends on the font carrying it and a rule does not.
					local active = (sort.col or columns[1]) == col
					local cell = make("TextButton", {
						Name = "Col_" .. tostring(col),
						Position = UDim2.new(0, statX + (i - 1) * colW, 0, 0),
						Size = UDim2.new(0, math.max(24, colW - 6), 1, 0),
						BackgroundTransparency = 1,
						AutoButtonColor = false,
						Font = FONT_MED,
						Text = string.upper(col),
						TextSize = 10,
						TextColor3 = active and Theme.TextBright or Theme.TextDim,
						TextXAlignment = numeric[col] and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left,
						TextTruncate = Enum.TextTruncate.AtEnd,
						Parent = colHead,
					})
					if active then
						make("Frame", {
							Name = "SortMark",
							AnchorPoint = Vector2.new(0, 1),
							Position = UDim2.new(0, 0, 1, -3),
							Size = UDim2.new(1, 0, 0, 2),
							BackgroundColor3 = Theme.Accent,
							BorderSizePixel = 0,
							Parent = cell,
						})
					end
					-- Cells are rebuilt on every draw and die with it, so these are the
					-- cell's own connections, not the card's: no per-draw wiring outlives
					-- the instance that carried it.
					trackConn(cell.Activated:Connect(function()
						setSort(col)
					end))
					trackConn(cell.MouseEnter:Connect(function()
						pcall(function()
							cell.TextColor3 = Theme.TextBright
							hintLbl.Text = hintFor(columns, col)
							hint.Visible = true
						end)
					end))
					trackConn(cell.MouseLeave:Connect(function()
						pcall(function()
							cell.TextColor3 = active and Theme.TextBright or Theme.TextDim
							hint.Visible = false
						end)
					end))
				end
			end

			if #rows == 0 or #columns == 0 then
				-- Empty is a state, not a failure: say what was looked for and what
				-- will make it appear, centred in the space the table would have
				-- filled, rather than leaving a hole where a table should be.
				local box = make("Frame", {
					Name = "Empty",
					Position = UDim2.new(0, CARD_PAD, 0, 0),
					Size = UDim2.new(1, -CARD_PAD * 2, 1, 0),
					BackgroundTransparency = 1,
					Parent = list,
				})
				make("TextLabel", {
					Name = "EmptyTitle",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.new(0.5, 0, 0.5, -10),
					Size = UDim2.new(1, 0, 0, 18),
					BackgroundTransparency = 1,
					Font = FONT_MED,
					Text = #columns == 0 and "No leaderboard found" or "Nobody else online",
					TextSize = 12,
					TextColor3 = Theme.TextBright,
					TextXAlignment = Enum.TextXAlignment.Center,
					Parent = box,
				})
				make("TextLabel", {
					Name = "EmptyHint",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.new(0.5, 0, 0.5, 12),
					Size = UDim2.new(1, 0, 0, 32),
					BackgroundTransparency = 1,
					Font = FONT,
					Text = #columns == 0
						and "Waiting for the game to publish leaderstats"
						or "Players appear here as they join",
					TextSize = 11,
					TextColor3 = Theme.TextDim,
					TextWrapped = true,
					TextXAlignment = Enum.TextXAlignment.Center,
					Parent = box,
				})
			else
				for i, row in ipairs(rows) do
					-- Three quiet signals in one place: the local player's row is
					-- tinted, the leader's is lifted a little, and alternate rows
					-- carry a whisper of a band so a long table stays readable. The
					-- hover is the same tint, on whichever row the pointer is over.
					local bg, bt = Theme.PanelBg, 1
					if row.highlight then
						bg, bt = Theme.Accent, 0.86
					elseif i == 1 then
						bg, bt = Theme.Accent, 0.94
					elseif i % 2 == 0 then
						bg, bt = Theme.ControlBg, 0.95
					end
					local r = make("Frame", {
						Name = "Row",
						Position = UDim2.new(0, 0, 0, (i - 1) * CARD_ROW),
						Size = UDim2.new(1, 0, 0, CARD_ROW),
						BackgroundColor3 = bg,
						BackgroundTransparency = bt,
						BorderSizePixel = 0,
						Parent = list,
					})
					trackConn(r.MouseEnter:Connect(function()
						pcall(function() r.BackgroundTransparency = math.min(bt, 0.92) end)
					end))
					trackConn(r.MouseLeave:Connect(function()
						pcall(function() r.BackgroundTransparency = bt end)
					end))
					-- The rank is the row's place in this table, not a stat: it comes
					-- from the order the rows came back in.
					make("TextLabel", {
						Name = "Rank",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.new(0, CARD_PAD + CARD_RANK_W / 2, 0.5, 0),
						Size = UDim2.new(0, CARD_RANK_W, 1, 0),
						BackgroundTransparency = 1,
						Font = (i <= 3) and FONT_BOLD or FONT,
						Text = tostring(i),
						TextSize = 11,
						TextColor3 = (i <= 3) and Theme.TextBright or Theme.TextDim,
						TextXAlignment = Enum.TextXAlignment.Center,
						Parent = r,
					})
					local av = make("ImageLabel", {
						Name = "Avatar",
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.new(0, CARD_PAD + CARD_RANK_W, 0.5, 0),
						Size = UDim2.fromOffset(CARD_AVATAR, CARD_AVATAR),
						BackgroundColor3 = Theme.ControlBg,
						BackgroundTransparency = 0.15,
						BorderSizePixel = 0,
						Image = row.image or "",
						Parent = r,
					})
					corner(av, 99)
					if row.highlight then
						-- A ring on the avatar, so the player's own row is findable at a
						-- glance without reading a name.
						stroke(av, Theme.Accent, 0.1)
					end
					make("TextLabel", {
						Name = "Name",
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.new(0, CARD_PAD + CARD_RANK_W + CARD_AVATAR + 6, 0.5, 0),
						Size = UDim2.new(0, math.max(30, nameW - CARD_AVATAR - 6), 1, 0),
						BackgroundTransparency = 1,
						Font = FONT_MED,
						Text = tostring(row.name),
						TextSize = 12,
						TextColor3 = row.highlight and Theme.TextWhite or Theme.TextBright,
						TextXAlignment = Enum.TextXAlignment.Left,
						TextTruncate = Enum.TextTruncate.AtEnd,
						Parent = r,
					})
					for ci, col in ipairs(columns) do
						make("TextLabel", {
							Name = "V_" .. tostring(col),
							AnchorPoint = Vector2.new(0, 0.5),
							Position = UDim2.new(0, statX + (ci - 1) * colW, 0.5, 0),
							Size = UDim2.new(0, math.max(24, colW - 6), 1, 0),
							BackgroundTransparency = 1,
							Font = FONT,
							Text = fmt(row.values[col]),
							TextSize = 12,
							TextColor3 = row.highlight and Theme.TextWhite or Theme.TextMid,
							TextXAlignment = numeric[col] and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left,
							TextTruncate = Enum.TextTruncate.AtEnd,
							Parent = r,
						})
					end
					cardLine(r)
				end
			end

			-- The card's own line, when the player is in the table at all: avatar,
			-- rank out of the room, and the value of the stat the table is ordered
			-- by. The three bands below the header move together, so the column
			-- header always sits on top of the rows it labels.
			local meRow, meRank = nil, nil
			for i, row in ipairs(rows) do
				if row.highlight then
					meRow, meRank = row, i
					break
				end
			end
			if meRow and meRank then
				local activeCol = sort.col or columns[1]
				selfAv.Image = meRow.image or ""
				selfLbl.Text = string.format("You · #%d of %d", meRank, #rows)
				selfVal.Text = activeCol and fmt(meRow.values[activeCol]) or ""
			end
			placeChrome(meRow ~= nil)

			if countLbl then
				countLbl.Text = #columns == 0 and "no data" or string.format("%d online", #rows)
			end
		end

		local cardWarned = false
		local function cardWarn(err)
			-- One diagnostic per card: an empty panel with no explanation would be
			-- the worst possible failure mode.
			if cardWarned then return end
			cardWarned = true
			warn("[Vision] card: " .. tostring(err))
		end

		local function refresh(force)
			if cardGone or destroyed or not cardGui.Parent then return end
			if not force and (not menuVisible or not win.Visible) then return end
			local columns, rows = leaderboardRows(copts, maxCols, sort)
			local sig = signature(columns, rows)
			if not force and sig == lastSig then return end
			lastSig = sig
			if copts.debug or Vision._debug then
				if #columns == 0 then
					warn("[Vision] card: no leaderboard found -- looked for leaderstats / Stats / leaderboard / scoreboard on every player")
				else
					print(string.format("[Vision] card: %d players, columns: %s", #rows, table.concat(columns, ", ")))
				end
			end
			draw(columns, rows)
		end

		-- Every entry point goes through this, so a failure surfaces as one console
		-- warning instead of a card that silently stays empty.
		local function tryRefresh(force)
			local ok, err = pcall(refresh, force)
			if not ok then cardWarn(err) end
		end

		-- The click path behind the column headers. It reuses the same draw as
		-- everything else -- an order is just one more thing the next draw reads.
		setSort = function(col)
			if cardGone or col == nil then return end
			if sort.col == col then
				sort.desc = not sort.desc
			else
				sort.col, sort.desc = col, true
			end
			lastSig = nil
			tryRefresh(true)
		end

		-- Live while the menu is up, silent while it is down: a slow tick that
		-- redraws only when the leaderboard actually changed, plus an immediate
		-- refresh the moment the window becomes visible again.
		local acc = 0
		local interval = math.max(0.25, tonumber(copts.refresh) or 1)
		if RunService then
			trackConn(RunService.Heartbeat:Connect(function(dt)
				if cardGone or destroyed or not cardGui.Parent then return end
				if not win.Visible then return end
				-- Every frame, but it only writes when the card has actually been
				-- pushed past an edge, which a window drag can do without touching
				-- the card at all.
				keepOnScreen()
				if not menuVisible then return end
				acc = acc + (tonumber(dt) or 0)
				if acc < interval then return end
				acc = 0
				tryRefresh()
			end))
		end
		trackConn(win:GetPropertyChangedSignal("Visible"):Connect(function()
			if not win.Visible then return end
			-- The tick's clock restarts with the reveal, so the first live refresh
			-- waits a whole interval instead of landing mid-fade.
			acc = 0
			-- A beat after the fade back in, so a redraw lands on a settled panel
			-- instead of swapping rows out from under the fade. This is the one
			-- that matters when the board changed while the menu was down.
			task.delay(0.2, function() tryRefresh() end)
		end))

		-- One unit while docked: the pair is what gets centred, so the window rests
		-- half the dock away from where it would sit on its own. A floating card is
		-- not part of that -- nothing about the card moves the main UI, so the
		-- window is centred as the window. Before the reveal the shift is
		-- invisible: the loader measures the window later, so it flies to the
		-- moved rect too. After one, only the overflow is given back, with a short
		-- tween.
		local dockW = CARD_GAP + cardW
		-- How far the cluster reaches past the window, and on which side. A docked
		-- card on the left is a reach of shift to the left and nothing to the
		-- right; one on the right is the mirror image. Keeping the two apart is
		-- what stops the window being pulled back further than it has to be.
		local shift = (docked and dockSide ~= "right") and dockW or 0
		local reach = (docked and dockSide == "right") and dockW or 0
		local clusterW = winW + shift + reach
		pcall(function()
			-- Position offsets, not AbsolutePosition: layout may not have run yet,
			-- while the offsets are exactly what windowRect() set.
			local pos = win.Position
			local x, y = pos.X.Offset, pos.Y.Offset
			if not revealed then
				x = math.floor((vpX - clusterW) / 2) + shift
			else
				-- Already on screen: give back only the part that hangs out.
				local over = (x + winW + reach) - (vpX - 10)
				if over > 0 then x = x - over end
				local under = (10 + shift) - x
				if under > 0 then x = x + under end
			end
			if clusterW <= vpX - 20 then
				x = math.clamp(x, 10 + shift, math.max(10 + shift, vpX - 10 - winW - reach))
			else
				-- The pair cannot fit: the window is the UI and wins the screen; the
				-- card is what gives way, and the drag clamp's own fallback keeps the
				-- titlebar reachable so the cluster can still be pulled back in.
				x = math.clamp(x, 10, math.max(10, vpX - winW - 10))
			end
			y = math.clamp(y, 10, math.max(10, vpY - winH - 10))
			if math.abs(x - pos.X.Offset) >= 1 or math.abs(y - pos.Y.Offset) >= 1 then
				local target = UDim2.fromOffset(math.floor(x), math.floor(y))
				if revealed then
					tween(win, { Position = target }, 0.2, Enum.EasingStyle.Quad)
				else
					win.Position = target
				end
			end
		end)

		-- The window is told how far a docked card reaches, and nothing else. It
		-- never hears about the card's own drag: the two panels move separately.
		applyExtent()

		-- The card is declared to the window as a blocker, so a press that lands
		-- on the card can never start a window drag -- which matters when the card
		-- has been parked over the titlebar. The card's own handler listens only
		-- on its header, which the window never sees, so one press can never move
		-- both panels.
		if self.AddDragBlocker then
			self.AddDragBlocker(cardGui)
		end

		local function cardDragStart(input)
			if cardGone or destroyed or cardDragging or not revealed or not win.Visible then return end
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
			local p = input.Position
			local wx, wy = win.Position.X.Offset, win.Position.Y.Offset
			-- The grab is fixed at press, so the panel cannot drift out from under
			-- the pointer when a frame is dropped mid-drag.
			cardGrabX = p.X - (wx + cardX)
			cardGrabY = p.Y - (wy + cardY)
			cardDragging = true
			cardToken = input
		end

		local function cardDragStop()
			if not cardDragging then return end
			cardDragging = false
			cardToken = nil
			if cardGone or destroyed then return end
			-- Dropped near one of the window's edges? Then that edge is where the
			-- card belongs, and the dock takes it back with a short tween.
			-- Anywhere else it stays where it was put, floating free.
			local leftGap = math.abs(cardX + cardW + CARD_GAP)
			local rightGap = math.abs(cardX - (winW + CARD_GAP))
			if leftGap <= CARD_SNAP then
				dockSide, docked = "left", true
			elseif rightGap <= CARD_SNAP then
				dockSide, docked = "right", true
			else
				docked = false
			end
			applyExtent()
			if docked then
				cardX = dockOffsetX(dockSide, cardW)
				tween(cardGui, { Position = UDim2.fromOffset(cardX, cardY) }, 0.12, Enum.EasingStyle.Quad)
			end
		end

		if UserInputService then
			trackConn(head.InputBegan:Connect(cardDragStart))
			trackConn(UserInputService.InputEnded:Connect(function(input)
				if not cardDragging then return end
				local t = input.UserInputType
				if input == cardToken or t == Enum.UserInputType.MouseButton1
					or t == Enum.UserInputType.Touch then
					cardDragStop()
				end
			end))
			trackConn(UserInputService.InputChanged:Connect(function(input)
				if not cardDragging then return end
				-- The menu can be hidden, or the whole UI destroyed, mid-drag.
				if destroyed or cardGone or not win.Visible then
					cardDragging = false
					cardToken = nil
					return
				end
				local t = input.UserInputType
				if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then return end
				-- A second finger must never fight the one holding the card.
				if t == Enum.UserInputType.Touch and cardToken and input ~= cardToken then return end
				local p = input.Position
				placeCard(p.X - cardGrabX, p.Y - cardGrabY)
			end))
		end

		-- The card's whole surface. Refresh, the two settings the table itself can
		-- change (which stat orders it, and which stats it shows), its title, a
		-- visibility switch for a caller that wants the frame without the table,
		-- and Destroy.
		local card = { Gui = cardGui }
		function card.Refresh()
			tryRefresh(true)
		end
		-- Snap the panel back onto one of the window's edges. Docking is what
		-- makes the pair read as one unit: the window's drag clamp counts the
		-- overhang again, and the pair is centred as a pair.
		function card.Dock(side)
			dockSide = (side == "right") and "right" or "left"
			docked = true
			applyExtent()
			cardX = dockOffsetX(dockSide, cardW)
			tween(cardGui, { Position = UDim2.fromOffset(cardX, cardY) }, 0.16, Enum.EasingStyle.Quad)
		end
		-- Free-floating placement, in screen pixels -- the same space a mouse
		-- reports. Docking stops being in force, because the caller has said where
		-- the card goes.
		function card.MoveTo(x, y)
			docked = false
			applyExtent()
			pcall(function() placeCard(tonumber(x) or 0, tonumber(y) or 0) end)
		end
		function card.SetSort(col, descending)
			if col == nil then return end
			sort.col = col
			sort.desc = descending ~= false
			lastSig = nil
			tryRefresh(true)
		end
		function card.SetStats(list)
			copts.stats = (type(list) == "table" and #list > 0) and list or nil
			lastSig = nil
			tryRefresh(true)
		end
		function card.SetTitle(text)
			local ok = pcall(function() titleLbl.Text = tostring(text or "") end)
			if not ok then cardWarn("SetTitle failed") end
		end
		function card.SetVisible(v)
			pcall(function() cardGui.Visible = v ~= false end)
		end
		function card.Destroy()
			if cardGone then return end
			cardGone = true
			cardDragging = false
			cardToken = nil
			pcall(function() cardGui:Destroy() end)
			if activeCard == card then activeCard = nil end
			if self.SetDragExtent then
				self.SetDragExtent(0, 0)
			end
		end

		activeCard = card
		tryRefresh(true)
		return card
	end

	-- ================================================================
	-- Theme system
	-- ================================================================

	local function repaintTheme(old)
		-- Support legacy snapshots that used oldTextWhite naming
		if old.oldTextWhite and not old.TextWhite then old.TextWhite = old.oldTextWhite end
		if old.oldTextBright and not old.TextBright then old.TextBright = old.oldTextBright end
		if old.oldTextMid and not old.TextMid then old.TextMid = old.oldTextMid end
		if old.oldTextDim and not old.TextDim then old.TextDim = old.oldTextDim end
		if old.oldInfoText and not old.InfoText then old.InfoText = old.oldInfoText end

		-- Build the colour map from the union of both palettes rather than a hand
		-- list: a role added to a theme -- now or later -- is mapped automatically.
		-- Non-colour fields (Alpha/Blur/Space) drop out by shape inspection, not
		-- by name, so they can never be mistaken for a colour.
		local maps = {}
		local mapped = {}
		local function addMap(k)
			if mapped[k] then return end
			mapped[k] = true
			local o, n = old[k], Theme[k]
			if typeof(o) == "Color3" and typeof(n) == "Color3" and o ~= n then
				maps[#maps + 1] = { o = o, n = n, key = k }
			end
		end
		for k in pairs(old) do addMap(k) end
		for k in pairs(Theme) do addMap(k) end

		local alpha = Theme.Alpha or {}
		local function remap(c)
			for _, m in ipairs(maps) do
				if c == m.o then return m.n, m.key end
			end
			return nil, nil
		end
		-- Re-glass a surface. The pristine transparency is captured once per frame
		-- (VisionAlphaBase), so toggling between an opaque palette and Dark Matter
		-- is always reversible and never compounds across switches.
		local function glass(d, key)
			local base = d:GetAttribute("VisionAlphaBase")
			if base == nil then
				base = d.BackgroundTransparency
				pcall(function() d:SetAttribute("VisionAlphaBase", base) end)
			end
			local a = tonumber(alpha[key]) or 0
			pcall(function() d.BackgroundTransparency = math.clamp((base or 0) + a, 0, 1) end)
		end
		for _, d in ipairs(win:GetDescendants()) do
			local cn = d.ClassName
			-- UIGradient on group headers
			if cn == "UIGradient" and d.Name == "ThemeGradient" then
				d.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Theme.GradientTop),
					ColorSequenceKeypoint.new(0.55, Theme.HeaderMid),
					ColorSequenceKeypoint.new(1, Theme.AccentDark),
				})
			-- Group head frame always follows AccentDark
			elseif d.Name == "Head" and d:IsA("Frame") then
				d.BackgroundColor3 = Theme.AccentDark
				glass(d, "AccentDark")
			-- Info circle always follows InfoBg
			elseif d.Name == "InfoCircle" and d:IsA("Frame") then
				d.BackgroundColor3 = Theme.InfoBg
				glass(d, "InfoBg")
			-- Theme backdrop + scrim are driven by their own fields, never by the
			-- generic colour remap (a scrim and a window background are not the same
			-- surface, even though they share a colour).
			elseif d.Name == "ThemeBackdrop" and d:IsA("ImageLabel") then
				d.Image = Theme.BgImage or ""
				d.ImageTransparency = tonumber(Theme.BgImageTransparency) or 0
				d.Visible = Theme.BgImage ~= nil
			elseif d.Name == "ThemeScrim" and d:IsA("Frame") then
				d.BackgroundColor3 = Theme.WindowBg
				d.BackgroundTransparency = tonumber(Theme.Scrim) or 0
				d.Visible = Theme.BgImage ~= nil
			elseif d:IsA("GuiObject") then
				pcall(function()
					local repl, key = remap(d.BackgroundColor3)
					if repl then d.BackgroundColor3 = repl end
					if key then glass(d, key) end
				end)
			-- Borders are drawn in theme colours too -- a card edge, a hint, an
			-- avatar ring -- and a stroke left behind on the old palette is the
			-- one piece of a repaint a user would notice.
			elseif d:IsA("UIStroke") then
				pcall(function()
					local repl = remap(d.Color)
					if repl then d.Color = repl end
				end)
			end
			-- Header title labels always use HeaderText for contrast on colored gradient
			if (cn == "TextLabel" or cn == "TextBox") and d.Parent and d.Parent.Name == "Head" then
				pcall(function() d.TextColor3 = Theme.HeaderText or Theme.TextWhite end)
			else
				-- Text colors
				if cn == "TextLabel" or cn == "TextBox" or cn == "TextButton" then
					pcall(function()
						local repl = remap(d.TextColor3)
						if repl then d.TextColor3 = repl end
					end)
				end
			end
			-- Image icons (nav, search, globe, check, chevron)
			if cn == "ImageLabel" or cn == "ImageButton" then
				pcall(function()
					local repl = remap(d.ImageColor3)
					if repl then d.ImageColor3 = repl end
				end)
			end
			-- UIStroke borders (ControlBorder + Accent)
			if cn == "UIStroke" then
				pcall(function()
					local repl = remap(d.Color)
					if repl then d.Color = repl end
				end)
			end
			-- Placeholder text
			if cn == "TextBox" then
				pcall(function()
					local repl = remap(d.PlaceholderColor3)
					if repl then d.PlaceholderColor3 = repl end
				end)
			end
			-- Scrollbar
			if cn == "ScrollingFrame" then
				pcall(function()
					local repl = remap(d.ScrollBarImageColor3)
					if repl then d.ScrollBarImageColor3 = repl end
				end)
			end
		end
		-- Window background
		win.BackgroundColor3 = Theme.WindowBg
		pcall(function() win.BackgroundTransparency = tonumber(alpha.WindowBg) or 0 end)
		-- Call any registered per-element repaint functions (toggles, sliders)
		for _, fn in ipairs(themeRepaints) do
			pcall(fn)
		end
	end

	function self.SetTheme(name)
		-- "Dark" was the original default key. It resolves to Dark Matter now, so a
		-- config saved before the rename still lands on a real theme.
		if name == "Dark" then name = "DarkMatter" end
		local t = Themes[name]
		if not t then return false end
		-- Snapshot every current color before overwriting Theme.
		local old = {}
		for k, v in pairs(Theme) do
			old[k] = v
		end
		-- Backfill from the canonical base, then let the theme override. A theme
		-- that omits a key gets the base value -- never the outgoing palette's.
		local base = Themes.DarkMatter
		for _, k in ipairs(THEME_COLOR_KEYS) do
			Theme[k] = (t[k] ~= nil) and t[k] or base[k]
		end
		Theme.HeaderText = t.HeaderText or t.TextWhite or base.HeaderText
		Theme.Alpha = t.Alpha or {}
		Theme.Blur = t.Blur
		Theme.BgImage = t.BgImage
		Theme.BgImageTransparency = t.BgImageTransparency
		Theme.Scrim = t.Scrim
		currentThemeName = name
		-- A theme's suggested blur applies only when the consumer did not pin one.
		if not Blur.explicit then
			pcall(Vision._blurConfig, (t.Blur ~= nil) and t.Blur or Blur.default, true)
		end
		Vision.Flags["theme"] = name; Vision._scheduleSave()
		repaintTheme(old)
		return true
	end

	function self.GetTheme()
		return currentThemeName
	end

	function self.ListThemes()
		local names = {}
		-- Shape-filtered: only real palettes are offered, so a helper or a future
		-- non-theme key can never leak into a consumer's picker.
		for name, t in pairs(Themes) do
			if type(t) == "table" and typeof(t.Accent) == "Color3" then
				names[#names + 1] = name
			end
		end
		table.sort(names)
		return names
	end

	-- Apply the active theme (Dark Matter unless opts.theme overrides). This runs
	-- the full path even for the default, so its glass, blur and space sky take
	-- effect; _suspendSave keeps init from writing a config to disk.
	do
		local want = (opts.theme and Themes[opts.theme]) and opts.theme or "DarkMatter"
		Vision._suspendSave()
		pcall(function() self.SetTheme(want) end)
		Vision._resumeSave()
	end

	trackConn(UserInputService.InputBegan:Connect(function(input, processed)
		if processed or anyListening then return end
		if menuKey and input.KeyCode == menuKey then
			self.ToggleMenu()
		end
	end))

	local function encodeValue(v)
		if typeof(v) == "Color3" then
			return { __color = { v.R, v.G, v.B } }
		end
		if typeof(v) == "EnumItem" then
			local enumTypeName = "KeyCode"
			pcall(function()
				-- tostring(Enum.KeyCode) -> "Enum.KeyCode", keep only "KeyCode"
				local s = tostring(v.EnumType)
				local m = string.match(s, "%.([^%.]+)$")
				if m then enumTypeName = m end
			end)
			return { __enum = { enumTypeName, v.Name } }
		end
		return v
	end

	local function decodeValue(v)
		if type(v) == "table" then
			if v.__color then
				local c = v.__color
				if type(c[1]) == "number" and type(c[2]) == "number" and type(c[3]) == "number" then
					local ok, col = pcall(function()
						return Color3.new(c[1], c[2], c[3])
					end)
					if ok and col then return col end
				end
				return nil
			end
			if v.__enum then
				local ok, e = pcall(function()
					local enumTypeName = tostring(v.__enum[1]):gsub("^Enum%.", "")
					return Enum[enumTypeName][v.__enum[2]]
				end)
				if ok then return e end
				return nil
			end
		end
		return v
	end

	local function applyLoadedTable(data)
		Vision._suspendSave()
		local okAll = pcall(function()
			for flag, v in pairs(data) do
				if type(flag) == "string" and flag:sub(1, 2) ~= "__" then
					local decoded = decodeValue(v)
					local entry = flagBinds[flag]
					if entry and entry.set then
						pcall(entry.set, decoded)
					else
						Vision.Flags[flag] = decoded
					end
				end
			end
			if type(Vision.Flags["theme"]) == "string" and Themes[Vision.Flags["theme"]] then
				pcall(function() self.SetTheme(Vision.Flags["theme"]) end)
			end
			-- Restore saved menu key (footer "Key: ...")
			local savedMenu = Vision.Flags["menu_key"]
			if type(savedMenu) == "string" and savedMenu ~= "" and savedMenu ~= "None" then
				pcall(function()
					local kc = Enum.KeyCode[savedMenu]
					if kc then
						menuKey = kc
						menuKeyLbl.Text = "Key: " .. keyName(menuKey)
					end
				end)
			elseif typeof(savedMenu) == "EnumItem" then
				pcall(function()
					menuKey = savedMenu
					menuKeyLbl.Text = "Key: " .. keyName(menuKey)
				end)
			end
		end)
		Vision._resumeSave()
		return okAll
	end

	function self.SaveConfig(cfgName)
		if not canFile() or not HttpService then return false end
		cfgName = (cfgName == nil or cfgName == "") and "default" or tostring(cfgName)
		ensureFolder()
		local out = {}
		for flag, v in pairs(Vision.Flags) do
			out[flag] = encodeValue(v)
		end
		out.__version = Vision.Version
		local ok, err = pcall(function()
			writefile(CONFIG_FOLDER .. "/configs/" .. cfgName .. ".json", HttpService:JSONEncode(out))
		end)
		return ok
	end

	function self.LoadConfig(cfgName)
		if not canFile() or not HttpService then return false end
		cfgName = (cfgName == nil or cfgName == "") and "default" or tostring(cfgName)
		local ok, data = pcall(function()
			return HttpService:JSONDecode(readfile(CONFIG_FOLDER .. "/configs/" .. cfgName .. ".json"))
		end)
		if not ok or type(data) ~= "table" then return false end
		applyLoadedTable(data)
		return true
	end

	function self.ListConfigs()
		local names = {}
		if type(listfiles) ~= "function" then return names end
		ensureFolder()
		pcall(function()
			for _, f in ipairs(listfiles(CONFIG_FOLDER .. "/configs")) do
				local n = string.match(f, "([^/\\]+)%.json$")
				if n then names[#names + 1] = n end
			end
		end)
		return names
	end

	--- Apply multiple flag values at once, syncing both Vision.Flags
	--- and the bound UI widgets (sliders, toggles, dropdowns, etc.).
	--- Usage: window.ApplyFlags({ aimbot_fov = 90, aimbot_smoothing = 5 })
	function self.ApplyFlags(dict)
		if type(dict) ~= "table" then return end
		Vision._suspendSave()
		pcall(function()
			for flag, val in pairs(dict) do
				Vision.Flags[flag] = val
				local entry = flagBinds[flag]
				if entry and entry.set then
					pcall(entry.set, val)
				end
			end
		end)
		Vision._resumeSave()
		Vision._scheduleSave()
	end

	self.Flags = Vision.Flags
	self.Window = win
	-- ═══════════════════════════════════════════════════════════════
	--  AUTO-SAVE / AUTO-LOAD API
	-- ═══════════════════════════════════════════════════════════════
	local AUTOSAVE_FILE = CONFIG_FOLDER .. "/autosave.json"
	local canAS = canFile() and HttpService ~= nil

	--- Save all flags to disk
	local function doSave()
		if not canAS then return end
		ensureFolder()
		local out = {}
		for flag, v in pairs(Vision.Flags) do
			out[flag] = encodeValue(v)
		end
		out.__version = Vision.Version
		pcall(function() writefile(AUTOSAVE_FILE, HttpService:JSONEncode(out)) end)
	end

	--- Wire the API functions
	_saveFunc = doSave

	function self.SaveNow()
		Vision._forceSave()
		return true
	end

	--- Load flags from disk and apply to widgets
	function self.AutoLoad()
		if not canAS then return false end
		local ok, data = pcall(function()
			return HttpService:JSONDecode(readfile(AUTOSAVE_FILE))
		end)
		if not ok or type(data) ~= "table" then return false end
		applyLoadedTable(data)
		return true
	end

	function self.DeleteAutosave()
		if not canFile() then return false end
		return pcall(function()
			if isfile(AUTOSAVE_FILE) then delfile(AUTOSAVE_FILE) end
		end)
	end

	--- Save on game close
	pcall(function()
		if game and game.BindToClose then
			game:BindToClose(function() pcall(doSave) end)
		end
	end)

	--- Save instantly when local player leaves (fixed: LocalPlayer was undefined)
	pcall(function()
		if Players and Players.PlayerRemoving then
			trackConn(Players.PlayerRemoving:Connect(function(plr)
				local lp = localPlayer()
				if lp and plr == lp then pcall(doSave) end
			end))
			-- Fallback: also save when any player leaves if LocalPlayer unavailable (Studio / tests)
			if localPlayer() == nil and game and game.BindToClose == nil then
				-- no-op, BindToClose above already covers close
			end
		end
	end)

	--- Auto-load on init without spamming saves during widget creation.
	--- Early load populates Vision.Flags so widgets created after Window() pick up saved values.
	Vision._suspendSave()
	pcall(function()
		self.AutoLoad()
	end)
	Vision._resumeSave()
	-- Keep saves suspended briefly while user builds Tabs/Groups (push(true) init should not write disk).
	Vision._suspendSave()
	task.delay(1.5, function()
		Vision._resumeSave()
		-- If settings were restored, notify once widgets likely exist.
		if canAS and type(isfile) == "function" then
			local has = false
			pcall(function() has = isfile(AUTOSAVE_FILE) end)
			if has then
				task.delay(0.5, function()
					pcall(function()
						self.Notify({ title = "Vision", text = "Settings restored.", type = "info", duration = 3 })
					end)
				end)
			end
		end
	end)

	-- Chrome without tabs: exactly what the loader's dot pass plays over. The
	-- window's own logo is deliberately left invisible so the loader's flying
	-- mark can hand off onto it with no overlap, and no tab is activated yet --
	-- that is what keeps the first tab's stagger as the last thing to happen.
	-- Returns the logo's live rect, plus a resolver to re-read it, so the
	-- loader knows exactly where to land.
	local function doChrome(target)
		if not (target and target.Parent) then return nil end
		local rect = nil
		pcall(function()
			local page = pendingTab and pendingTab.Page
			local cache = collectFade(target)
			local chrome = {}
			for _, e in ipairs(cache) do
				local inPage = page and (e.inst == page or e.inst:IsDescendantOf(page))
				local isWindowBg = e.inst == target and e.prop == "BackgroundTransparency"
				local isWindowLogo = logo and e.inst == logo and e.prop == "ImageTransparency"
				if not inPage and not isWindowBg and not isWindowLogo then
					chrome[#chrome + 1] = e
				end
			end
			for _, e in ipairs(chrome) do
				e.inst[e.prop] = 1
			end
			-- With no card left to cross-fade against, the window's own
			-- background docks in with the rest of the chrome instead of
			-- appearing in one hard step.
			target.BackgroundTransparency = 1
			target.Visible = true
			for _, e in ipairs(chrome) do
				tween(e.inst, { [e.prop] = e.value }, 0.22, Enum.EasingStyle.Quad)
			end
			-- Dock to the theme's own window alpha, not to 0: Dark Matter's window
			-- is deliberately translucent, and a hard 0 here would glass it opaque.
			tween(target, { BackgroundTransparency = (Theme.Alpha and tonumber(Theme.Alpha.WindowBg)) or 0 }, 0.22, Enum.EasingStyle.Quad)
			if logo then logo.ImageTransparency = 1 end
			chromeDone = true
		end)
		-- Live absolute rect of the window's own logo. Read on demand rather than
		-- cached, because the mark has to land where the logo actually is at the
		-- instant of the flight -- and the window can be dragged, or the client
		-- resized, during the intro. Both ScreenGuis ignore the top bar inset, so
		-- this is directly comparable to the loader stage's own offsets: plain
		-- screen pixels either way, position AND size.
		--
		-- The formula below is only a fallback for a logo that cannot report its
		-- layout yet; it rebuilds Position/Size by hand from the window rect.
		local function logoRect()
			local r = nil
			pcall(function()
				local ap, as = logo.AbsolutePosition, logo.AbsoluteSize
				if tonumber(as.X) and as.X > 1 and tonumber(as.Y) and as.Y > 1 then
					r = { ap.X, ap.Y, as.X, as.Y }
				end
			end)
			if not r then
				pcall(function()
					local wp = target.AbsolutePosition
					r = { wp.X + MARGIN + 2, wp.Y + TOPBAR_H / 2 - 15, 30, 30 }
				end)
			end
			return r
		end

		rect = logoRect()
		return rect, logoRect
	end

	-- The reveal owns the window's first appearance: fade the chrome in (unless
	-- doChrome already docked it for the loader), hand the logo over, then let
	-- the first tab's stagger play. That is why the first tab selection was
	-- deferred in Tab() rather than run while the window was still hidden.
	local function doReveal(target, mark)
		if not (target and target.Parent) then return end
		pcall(function()
			if not chromeDone then
				local page = pendingTab and pendingTab.Page
				local cache = collectFade(target)
				local chrome = {}
				for _, e in ipairs(cache) do
					local inPage = page and (e.inst == page or e.inst:IsDescendantOf(page))
					local isWindowBg = e.inst == target and e.prop == "BackgroundTransparency"
					if not inPage and not isWindowBg then
						chrome[#chrome + 1] = e
					end
				end
				for _, e in ipairs(chrome) do
					e.inst[e.prop] = 1
				end
				target.BackgroundTransparency = (Theme.Alpha and tonumber(Theme.Alpha.WindowBg)) or 0
				target.Visible = true
				for _, e in ipairs(chrome) do
					tween(e.inst, { [e.prop] = e.value }, 0.26, Enum.EasingStyle.Quad)
				end
				chromeDone = true
			end
			-- Sprite hand-off. The mark has landed on this exact rect by now, so
			-- revealing the logo underneath it is invisible -- unless the window's
			-- own logo never got its image (cold cache, slow or failed fetch), in
			-- which case hiding the mark would blink the logo out of existence.
			-- Adopting the mark's image closes that hole: whatever the mark was
			-- showing is exactly what stays on screen, pixel for pixel.
			pcall(function()
				if logo and not logoHasImage and mark then
					local src = mark.Image
					if src ~= nil and src ~= "" then
						logo.Image = src
						logoHasImage = true
					end
				end
			end)
			if logo then logo.ImageTransparency = 0 end
			target.BackgroundTransparency = (Theme.Alpha and tonumber(Theme.Alpha.WindowBg)) or 0
			target.Visible = true
			revealed = true
			cursorSet(menuVisible and true or false)
			if pendingTab then
				local first = pendingTab
				pendingTab = nil
				setActiveTab(first)
			end
		end)
	end

	-- No viewport re-clamp any more. It existed so the loader's target always
	-- matched where the window would end up, but the landing slot is resolved at
	-- flight time now, and re-centering would yank a window the user dragged.

	-- Build complete. _loaderEnd docks this window's chrome, plays the dot pass
	-- over it, lands the mark on this window's own logo, and only then calls
	-- doReveal above to start the first tab's stagger. Capture liveness first:
	-- _loaderEnd clears it synchronously, before any of that animation runs.
	local loaderWasAlive = Vision._loaderAlive()
	pcall(Vision._loaderEnd, win, doReveal, doChrome)

	-- With the loader up the blur already ramped in alongside the mark. When it
	-- is disabled (or could not start), start it here so it still tracks the menu.
	if not loaderWasAlive then
		pcall(Vision._blurOpen)
	end

	return self
end


-- Register this build globally before handing it over. A consumer script
-- that starts with `getgenv().Vision` therefore uses the copy that was just
-- run, and never an older one fetched from a URL.
if type(getgenv) == "function" then
	pcall(function() getgenv().Vision = Vision end)
end
return Vision
