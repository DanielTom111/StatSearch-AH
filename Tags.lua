-- StatSearch / Tags.lua
-- The stat/effect dictionary. Tags are matched against item TOOLTIP LINES,
-- not item names, so "intellect" finds "+12 Intellect" and
-- "Equip: Increases healing done by up to 22".
--
-- Add your own tags at the bottom. Fields:
--   id        unique key (saved in your settings)
--   label     shown in the UI
--   short     compact label for result rows
--   aliases   extra words you can type to find it
--   patterns  Lua patterns run against the lowercased tooltip line
--             (colour codes and a trailing "." are already stripped).
--             The last capture is the value; no capture = flag (value 1).
--   fn        optional custom matcher: function(line) return value or nil end
--   unit      "%" or "dps" for display
--   flag      true = effect without a number
--   hidden    true = don't list it in result rows' stat summary
--   primary   true = counts toward the "stat total" used for sorting
--   hides     tag ids to leave out of a result's stat line when this tag is
--             one you're searching for (e.g. Healing Power hides Spell Power)
--
-- Editing patterns changes the tag signature; the addon re-reads stats
-- for the saved scan automatically next time you open the AH.

local _, ns = ...
local T = {}
ns.Tags = T

local list = {}
T.list = list

local function add(def)
    def.aliases = def.aliases or {}
    def.patterns = def.patterns or {}
    list[#list + 1] = def
end

local function plus(word)
    return "^%+(%d+) " .. word .. "$"
end

---------------------------------------------------------------------------
-- Primary stats (these make up the "stat total")
---------------------------------------------------------------------------
add { id = "str", label = "Strength",  short = "Str", aliases = { "str" },        patterns = { plus("strength") },  primary = true }
add { id = "agi", label = "Agility",   short = "Agi", aliases = { "agi" },        patterns = { plus("agility") },   primary = true }
add { id = "sta", label = "Stamina",   short = "Sta", aliases = { "sta", "stam" }, patterns = { plus("stamina") },  primary = true }
add { id = "int", label = "Intellect", short = "Int", aliases = { "int", "intel" }, patterns = { plus("intellect") }, primary = true }
add { id = "spi", label = "Spirit",    short = "Spi", aliases = { "spi", "spirit" }, patterns = { plus("spirit") },  primary = true }

---------------------------------------------------------------------------
-- Caster
---------------------------------------------------------------------------
add {
    id = "heal", label = "Healing Power", short = "Heal", hides = { "sp" },
    aliases = { "heal", "heal power", "healing", "+healing", "bonus healing", "healing done" },
    patterns = {
        "increases healing done by up to (%d+)",
        "increases healing done by spells and effects by up to (%d+)",
        "damage and healing done by magical spells and effects by up to (%d+)",
        "^%+(%d+) healing spells$",
        "^%+(%d+) healing$",
        "^%+(%d+) damage and healing spells$",
        "^%+(%d+) spell power$",
    },
}
add {
    id = "sp", label = "Spell Power", short = "SP", hides = { "heal" },
    aliases = { "sp", "spell damage", "spelldamage", "spell dmg", "damage and healing" },
    patterns = {
        "damage and healing done by magical spells and effects by up to (%d+)",
        "and damage done by up to (%d+) for all magical spells",
        "^%+(%d+) damage and healing spells$",
        "^%+(%d+) spell power$",
        "^%+(%d+) spell damage$",
    },
}
for _, school in ipairs({ "fire", "frost", "nature", "shadow", "arcane", "holy" }) do
    local cap = school:sub(1, 1):upper() .. school:sub(2)
    add {
        id = school .. "dmg", label = cap .. " Spell Damage", short = cap .. " SP",
        aliases = { school .. " damage", school .. " power", school .. " sp", school .. " spell" },
        patterns = {
            "damage done by " .. school .. " spells and effects by up to (%d+)",
            "^%+(%d+) " .. school .. " spell damage$",
            "^%+(%d+) " .. school .. " damage$",
        },
    }
end
add { id = "spellcrit", label = "Spell Critical Strike", short = "Spell Crit", unit = "%",
      aliases = { "spell crit", "sc" },
      patterns = { "critical strike with spells by (%d+)", "spell critical strike by (%d+)" } }
add { id = "spellhit", label = "Spell Hit", short = "Spell Hit", unit = "%",
      aliases = { "spell hit" },
      patterns = { "chance to hit with spells by (%d+)", "spell hit rating by (%d+)" } }
add { id = "mp5", label = "Mana Regen (MP5)", short = "MP5",
      aliases = { "mp5", "mana regen", "mana per 5", "mana regeneration" },
      patterns = { "(%d+) mana per 5", "(%d+) mana every 5" } }
add { id = "spellpen", label = "Spell Penetration", short = "Pen",
      aliases = { "pen", "spell pen", "penetration" },
      patterns = { "magical resistances of your spell targets by (%d+)", plus("spell penetration") } }

---------------------------------------------------------------------------
-- Physical
---------------------------------------------------------------------------
add { id = "ap", label = "Attack Power", short = "AP", aliases = { "ap" },
      patterns = { "%+(%d+) attack power", "increases attack power by (%d+)" } }
add { id = "rap", label = "Ranged Attack Power", short = "RAP", aliases = { "rap", "ranged ap" },
      patterns = { "%+(%d+) ranged attack power", "ranged attack power by (%d+)" } }
add { id = "crit", label = "Critical Strike", short = "Crit", unit = "%",
      aliases = { "crit", "critical", "crit chance" },
      patterns = { "chance to get a critical strike by (%d+)", plus("critical strike"), "critical strike rating by (%d+)" } }
add { id = "hit", label = "Hit Chance", short = "Hit", unit = "%",
      aliases = { "hit", "to hit" },
      patterns = { "improves your chance to hit by (%d+)", plus("hit"), "^%+(%d+) hit rating$", "increases your hit rating by (%d+)" } }
add { id = "haste", label = "Haste / Attack Speed", short = "Haste",
      aliases = { "haste", "attack speed", "casting speed" },
      patterns = { "increases your attack speed by (%d+)", "attack and casting speed by (%d+)", plus("haste"), "haste rating by (%d+)" } }

local WEAPON_SKILLS = {
    ["daggers"] = true, ["swords"] = true, ["two-handed swords"] = true,
    ["axes"] = true, ["two-handed axes"] = true, ["maces"] = true,
    ["two-handed maces"] = true, ["bows"] = true, ["guns"] = true,
    ["crossbows"] = true, ["staves"] = true, ["polearms"] = true,
    ["fist weapons"] = true, ["unarmed"] = true, ["thrown"] = true,
}
add { id = "wskill", label = "Weapon Skill", short = "Skill",
      aliases = { "weapon skill", "skill" },
      fn = function(line)
          local skill, v = line:match("increased ([%a%- ]-) %+(%d+)$")
          if skill and WEAPON_SKILLS[skill] then return tonumber(v) end
      end,
      ver = 1 }
add { id = "dps", label = "Weapon DPS", short = "DPS", unit = "dps",
      aliases = { "dps", "damage per second" },
      patterns = { "^%(([%d%.]+) damage per second%)$" } }

---------------------------------------------------------------------------
-- Defensive
---------------------------------------------------------------------------
add { id = "armor", label = "Armor", short = "Armor", aliases = { "armour" },
      patterns = { "^(%d+) armor$", plus("armor"), "increases armor by (%d+)" } }
add { id = "def", label = "Defense", short = "Def", aliases = { "def", "defence" },
      patterns = { "increased defense %+(%d+)", plus("defense"), "defense rating by (%d+)" } }
add { id = "dodge", label = "Dodge", short = "Dodge", unit = "%",
      patterns = { "chance to dodge an attack by (%d+)", plus("dodge"), "dodge rating by (%d+)" } }
add { id = "parry", label = "Parry", short = "Parry", unit = "%",
      patterns = { "chance to parry an attack by (%d+)", plus("parry"), "parry rating by (%d+)" } }
add { id = "blockchance", label = "Block Chance", short = "Block%", unit = "%",
      aliases = { "block chance" },
      patterns = { "chance to block attacks with a shield by (%d+)", "block rating by (%d+)" } }
add { id = "blockvalue", label = "Block Value", short = "Block",
      aliases = { "block", "block value" },
      patterns = { "^(%d+) block$", "block value of your shield by (%d+)", plus("block value") } }
add { id = "hp5", label = "Health Regen (HP5)", short = "HP5",
      aliases = { "hp5", "health regen" },
      patterns = { "(%d+) health per 5", "(%d+) health every 5" } }

for _, school in ipairs({ "fire", "frost", "nature", "shadow", "arcane" }) do
    local cap = school:sub(1, 1):upper() .. school:sub(2)
    add {
        id = school .. "res", label = cap .. " Resistance", short = cap .. " Res",
        aliases = { school .. " res", school .. " resist", school:sub(1, 1) .. "r" },
        patterns = { plus(school .. " resistance"), plus("all resistances") },
    }
end
add { id = "allres", label = "All Resistances", short = "All Res",
      aliases = { "all res", "resist all", "resistances" },
      patterns = { plus("all resistances") } }

---------------------------------------------------------------------------
-- Modern rating stats (in case Forever items use them)
---------------------------------------------------------------------------
add { id = "mastery", label = "Mastery", short = "Mast", patterns = { plus("mastery") } }
add { id = "vers", label = "Versatility", short = "Vers", aliases = { "vers" }, patterns = { plus("versatility") } }
add { id = "leech", label = "Leech", short = "Leech", patterns = { plus("leech") } }
add { id = "avoid", label = "Avoidance", short = "Avoid", patterns = { plus("avoidance") } }

---------------------------------------------------------------------------
-- Effects
---------------------------------------------------------------------------
add { id = "proc", label = "Chance on Hit (proc)", short = "Proc", flag = true,
      aliases = { "proc", "on hit", "chance on hit" }, patterns = { "^chance on hit:" } }
add { id = "use", label = "Use Effect", short = "Use", flag = true,
      aliases = { "use", "on use", "active" }, patterns = { "^use:" } }
add { id = "equip", label = "Any Equip Effect", short = "Equip", flag = true, hidden = true,
      aliases = { "equip", "equip effect" }, patterns = { "^equip:" } }
add { id = "runspeed", label = "Run Speed", short = "Speed", unit = "%",
      aliases = { "run speed", "movement speed", "speed" },
      patterns = { "run speed by (%d+)", "movement speed by (%d+)", "minor speed increase" } }
add { id = "stealth", label = "Stealth Bonus", short = "Stealth", flag = true,
      aliases = { "stealth" }, patterns = { "effective stealth level" } }
add { id = "set", label = "Set Piece", short = "Set", flag = true,
      aliases = { "set", "tier", "set bonus" }, patterns = { "^%(%d+%) set:", "%(%d+/%d+%)$" } }

---------------------------------------------------------------------------
-- Add your own tags below, e.g.
-- add { id = "beast", label = "Beast Slaying", short = "Beast", aliases = { "beast" },
--       patterns = { "attack power when fighting beasts by up to (%d+)" } }
---------------------------------------------------------------------------


---------------------------------------------------------------------------
-- Lookup tables, signature, search, extraction
---------------------------------------------------------------------------
T.byId = {}
local sigParts = {}
for _, tag in ipairs(list) do
    assert(not T.byId[tag.id], "StatSearch: duplicate tag id " .. tag.id)
    T.byId[tag.id] = tag
    tag.names = { tag.label:lower(), tag.id }
    for _, a in ipairs(tag.aliases) do tag.names[#tag.names + 1] = a:lower() end
    sigParts[#sigParts + 1] = tag.id .. "=" .. table.concat(tag.patterns, "\1") .. (tag.fn and ("fn" .. (tag.ver or 0)) or "")
end
do
    local s, h = table.concat(sigParts, "\2"), 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    T.signature = h
end

function T.Normalize(s)
    if not s then return "" end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")
    s = s:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%.$", "")
    return s
end

local function MatchTag(tag, line)
    if tag.fn then return tag.fn(line) end
    for _, p in ipairs(tag.patterns) do
        local a, b = line:match(p)
        if a then
            return tonumber(b or a) or 1
        end
    end
end

local SKIP_PREFIX = { "requires ", "durability ", "binds ", "classes:", "races:", "unique", "sell price" }

-- lines: raw tooltip left-text lines (line 1 = item name, skipped)
function T.Extract(lines)
    local out = {}
    for i = 2, #lines do
        local line = T.Normalize(lines[i])
        local skip = (line == "") or (line:sub(1, 1) == '"')
        if not skip then
            for _, pre in ipairs(SKIP_PREFIX) do
                if line:sub(1, #pre) == pre then skip = true break end
            end
        end
        if not skip then
            for _, tag in ipairs(list) do
                local v = MatchTag(tag, line)
                if v then out[tag.id] = (out[tag.id] or 0) + v end
            end
        end
    end
    return out
end

-- Sum of primary stats (Str/Agi/Sta/Int/Spi)
function T.PrimaryTotal(tags)
    if not tags then return 0 end
    local n = 0
    for _, tag in ipairs(list) do
        if tag.primary then n = n + (tags[tag.id] or 0) end
    end
    return n
end

-- Fuzzy tag lookup for the input box. Returns { {tag=, score=, via=}, ... }
function T.Search(text)
    text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local out = {}
    if text == "" then return out end
    for _, tag in ipairs(list) do
        local best, via = nil, nil
        for idx, name in ipairs(tag.names) do
            local score
            if name == text then score = 3
            elseif name:sub(1, #text) == text then score = 2
            elseif name:find(text, 1, true) then score = 1 end
            if score and (not best or score > best) then
                best = score
                via = (idx > 1) and name or nil
            end
        end
        if best then out[#out + 1] = { tag = tag, score = best, via = via } end
    end
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return #a.tag.label < #b.tag.label
    end)
    return out
end

-- "crit 1", "int>=10", "heal: 20" -> name, minValue
function T.ParseInput(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local name, num = text:match("^(.-)%s*[>=:]*%s*(%d+%.?%d*)$")
    if name and name ~= "" then return name, tonumber(num) end
    return text, nil
end

function T.FormatValue(tag, v)
    if tag.flag then return "" end
    if tag.unit == "%" then return v .. "%" end
    if tag.unit == "dps" then return string.format("%.1f", v) end
    return "+" .. v
end

-- Parse a price: "1.5" = 1.5 gold, "1g 50s", "75s", "20c", "1g50s20c".
-- Returns copper, or nil for empty/invalid.
function T.ParseMoney(text)
    text = (text or ""):lower():gsub("%s+", "")
    if text == "" then return nil end
    local plain = tonumber(text)
    if plain then return math.floor(plain * 10000 + 0.5) end
    local total, matched = 0, false
    for num, unit in text:gmatch("([%d%.]+)([gsc])") do
        local n = tonumber(num)
        if not n then return nil end
        matched = true
        total = total + n * ((unit == "g" and 10000) or (unit == "s" and 100) or 1)
    end
    if not matched or text:gsub("[%d%.]+[gsc]", "") ~= "" then return nil end
    return math.floor(total + 0.5)
end
