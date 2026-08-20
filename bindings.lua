-- QuickLook keybind snippet for Omarchy / Hyprland.
-- Default: SUPER + period (.). Alternate: SUPER+SHIFT+P.
-- First-run collision check: do not overwrite an existing bind.
--
-- This file is a snippet. Paste the bind line into hyprland.conf (or your
-- Omarchy bindings file). QuickLook does not write compositor config itself.
--
-- Hyprland:
--   bind = SUPER, period, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'
--   bind = SUPER SHIFT, P, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'
-- File manager custom action:
--   omarchy-shell shell summon io.github.chris.quicklook '{"path":"%f"}'

local function binds_json()
  local h = io.popen("hyprctl binds -j 2>/dev/null")
  if not h then
    return ""
  end
  local json = h:read("*a") or ""
  h:close()
  return json
end

local function already_bound(key_needle, mod_needle)
  local json = binds_json()
  if json == "" then
    return false
  end
  -- Conservative string search: avoid JSON parsers that may not be present.
  if not json:find(key_needle, 1, true) then
    return false
  end
  if mod_needle and not json:find(mod_needle, 1, true) then
    return false
  end
  return true
end

local colliding = already_bound('"key": "period"', "SUPER")
  or already_bound('"key": "."', "SUPER")

if colliding then
  io.stderr:write("quicklook: SUPER+. looks already bound; use SUPER+SHIFT+P instead\n")
  io.stderr:write("  bind = SUPER SHIFT, P, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'\n")
else
  io.stderr:write("quicklook: suggested bind\n")
  io.stderr:write("  bind = SUPER, period, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'\n")
end
