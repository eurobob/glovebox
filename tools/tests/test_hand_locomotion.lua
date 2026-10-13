local events, pending, commands = {}, {}, {}
local preference = "3"
local world = {}
function ListenToGameEvent(name, callback) events[name] = callback end
function world:SetThink(callback, name, delay)
  assert(name == "klepton_hand_locomotion" and delay > 0)
  pending[#pending + 1] = callback
end
Entities = { First = function() return world end }
Convars = { GetStr = function(_, name)
  assert(name == "hlvr_movetype_default")
  return preference
end }
function SendToServerConsole(command) commands[#commands + 1] = command end
function Msg(_) end

assert(loadfile(arg[1]))()
assert(baseline_runs == 1, "Existing gameinit still executes")
assert(#commands == 0, "No movement command before a live player exists")
for load = 1, 3 do
  events.player_activate()
  assert(#pending == load, "Each spawn/load schedules an override")
  assert(pending[load]() == nil, "The override is one shot")
  assert(commands[load] == "vr_movetype_set 2", "Live movement must use head orientation")
  assert(preference == "3", "The saved Sense movement preference is unchanged")
end
Entities.First = function() return nil end
events.player_activate()
assert(#pending == 3, "An absent world must not fail startup")
print("Hand locomotion Lua: existing script, deferred/repeated activation and preference preservation passed")
