-- QuickLook keybind snippet for Omarchy / Hyprland.
-- Default: SUPER + period (.). Alternate: SUPER+SHIFT+P.
-- First-run collision check: parse hyprctl binds -j objects and require
-- both key=period and SUPER (modmask bit 64) without SHIFT/CTRL/ALT.
--
-- This file is a snippet. Paste the bind line into hyprland.conf (or your
-- Omarchy bindings file). QuickLook does not write compositor config itself.
--
-- Hyprland:
--   bind = SUPER, period, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'
--   bind = SUPER SHIFT, P, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'
-- File manager custom action:
--   omarchy-shell shell summon io.github.chris.quicklook '{"path":"%f"}'

local SUPER, SHIFT, CTRL, ALT = 64, 1, 4, 8

local function binds_json()
  local h = io.popen("hyprctl binds -j 2>/dev/null")
  if not h then
    return ""
  end
  local json = h:read("*a") or ""
  h:close()
  return json
end

local function has_bit(mask, bit)
  return math.floor(mask / bit) % 2 == 1
end

local function key_is_period(key)
  return key == "period" or key == "." or key == "Period"
end

local function super_period_bound(json)
  if not json or json == "" then
    return false
  end
  for obj in json:gmatch("%b{}") do
    local key = obj:match('"key"%s*:%s*"([^"]*)"')
    local mask = tonumber(obj:match('"modmask"%s*:%s*(%-?%d+)'))
    if key and mask and key_is_period(key) and has_bit(mask, SUPER)
        and not has_bit(mask, SHIFT) and not has_bit(mask, CTRL) and not has_bit(mask, ALT) then
      return true
    end
  end
  return false
end

if super_period_bound(binds_json()) then
  io.stderr:write("quicklook: SUPER+. looks already bound; use SUPER+SHIFT+P instead\n")
  io.stderr:write("  bind = SUPER SHIFT, P, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'\n")
else
  io.stderr:write("quicklook: suggested bind\n")
  io.stderr:write("  bind = SUPER, period, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'\n")
end
