local core, vector = core, vector

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)

local bit32 = dofile(modpath .. "/funcs.lua").bit32

local S = core.get_translator(modname)

local PLAYER = 1
local AI = 2

local ARENA_BOUNDS = {
  pos1 = { x = -6, y = -6, z = 5 },
  pos2 = { x = 5, y = 5, z = -6 }
}
local BUTTON_POS = { x = 4, y = -5, z = -1 }
local DICE_POS = { x = 4, y = -5, z = 0 }
local FACEDIR_TO_PIPS = {
  6, 6, 6, 6, 3, 5, 4, 2, 4, 2, 3, 5, 2, 3, 5, 4, 5, 4, 2, 3, 1, 1, 1, 1
}
local GOAL = 100
local PIG_MOB = "mobs_animal:pumba"
local SCREENS = {
  home = {
    channel = "home",
    pos = { x = 4, y = 0, z = 3 }
  },
  comp = {
    channel = "comp",
    pos = { x = 4, y = 0, z = -3 }
  },
  player_score = {
    channel = "score1",
    pos = { x = 4, y = -3, z = 3 }
  },
  ai_score = {
    channel = "score2",
    pos = { x = 4, y = -3, z = -3 }
  },
}
local SPAWN_CENTER = { x = -0.5, y = -4, z = -0.5 }
local SPAWN_RADIUS = 4

local game = {
  current_player = PLAYER,
  ended = false,
  prior_scores = { [PLAYER] = 0, [AI] = 0 }, -- scores when a turn was started
  scores = { [PLAYER] = 0, [AI] = 0 },
}

local function slurp_file(path)
  local file = io.open(path, "rb")

  if file then
    local contents = file:read("*all")
    file:close()
    return contents
  else
    return nil
  end
end

local ai_tree = slurp_file(modpath .. "/resources/ai.bin")

local function place_sign(pos, msg, dir)
  core.set_node(pos, { name = "default:sign_wall_steel", param2 = dir })
  core.get_meta(pos):set_string("text", msg)
  core.get_meta(pos):set_string("infotext", msg)
end

local function place_led(pos, channel)
  core.set_node(pos, { name = "led_marquee:char_32", param2 = 2 })

  if channel then
    core.get_meta(pos):set_string("channel", channel)
  end
end

local function place_screen(screen)
  place_led(screen.pos, screen.channel)
  place_led({ x = screen.pos.x, y = screen.pos.y, z = screen.pos.z - 1 }, nil)
  place_led({ x = screen.pos.x, y = screen.pos.y - 1, z = screen.pos.z - 1 }, nil)
  place_led({ x = screen.pos.x, y = screen.pos.y - 1, z = screen.pos.z }, nil)
end

local function set_screen_text(screen, text)
  digilines.transmit(screen.pos, screen.channel, text, {})
end

local function display_score(screen, score)
  set_screen_text(screen, "clear")
  set_screen_text(screen, score)
end

local function display_player_score()
  display_score(SCREENS.player_score, game.scores[PLAYER])
end

local function display_ai_score()
  display_score(SCREENS.ai_score, game.scores[AI])
end

local function display_scores()
  display_player_score()
  display_ai_score()
end

local function compare_pos(pos1, pos2)
  return pos1.x == pos2.x and pos1.y == pos2.y and pos1.z == pos2.z
end

local function next_player(player)
  return 3 - player
end

local function random_spawn_pos(center, radius)
  local a = math.random() * 2 * math.pi
  local r = radius * math.sqrt(math.random())

  return vector.new(r * math.cos(a), center.y, r * math.sin(a))
end

local function get_pigs_in_area(area)
  local pigs = {}

  for object in core.objects_in_area(area.pos1, area.pos2) do
    local entity = object:get_luaentity(object)

    if entity and entity.is_mob and entity.name == PIG_MOB then
      table.insert(pigs, entity)
    end
  end

  return pigs
end

local function spawn_pigs()
  local pigs = get_pigs_in_area(ARENA_BOUNDS)
  local max = core.settings:get("mob_active_limit") or 10
  for _ = 1, max - #pigs do
    mobs:add_mob(random_spawn_pos(SPAWN_CENTER, SPAWN_RADIUS), {
      name = PIG_MOB,
      ignore_count = true
    })
  end
end

local function narrate_move(msg)
  core.chat_send_player("singleplayer", S(msg))
end

local function narrate_pass()
  if game.current_player == AI then
    narrate_move("Computer passes their turn!")
  else
    narrate_move("You pass your turn!")
  end
end

local function narrate_roll(pips)
  if game.current_player == AI then
    narrate_move("Computer rolls a " .. pips .. "!")
  else
    narrate_move("You roll a " .. pips .. "!")
  end
end

local function computer_won()
  return game.scores[AI] > game.scores[PLAYER]
end

local function narrate_win()
  if computer_won() then
    narrate_move("The computer wins, you lose! Boo hoo!")
  else
    narrate_move("You win the game! Congrats!")
  end
end

local function celebrate()
  local pigs = get_pigs_in_area(ARENA_BOUNDS)
  local player = core.get_player_by_name("singleplayer")

  if computer_won() then
    for i = 1, #pigs do
      pigs[i]:do_attack(player)
    end
  else
    for i = 1, #pigs do
      pigs[i].runaway_from = {"player"}
      pigs[i]:do_runaway_from()
    end
  end
end

local function check_game_ended()
  if game.ended then
    core.chat_send_player("singleplayer", S("The game has already ended!"))

    return true
  end

  return false
end

local function check_player_turn()
  if game.current_player ~= PLAYER then
    core.chat_send_player("singleplayer", S("It is not your turn right now!"))

    return false
  end

  return true
end

local function watch_button_press(node_name, callback)
  local func = core.registered_nodes[node_name].on_rightclick

  core.registered_nodes[node_name].on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
    if check_game_ended() then return end
    if clicker and clicker:is_player() and not check_player_turn() then
      return
    end

    func(pos, node, clicker, itemstack, pointed_thing)
    callback(pos)
  end
end

local function watch_throw(node_name, callback)
  local dice2_throw = core.registered_nodes[node_name].on_rightclick

  core.registered_nodes[node_name].on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
    if check_game_ended() then return end
    if clicker and clicker:is_player() and not check_player_turn() then
      return
    end

    dice2_throw(pos, node, clicker, itemstack, pointed_thing)

    -- since the above swaps nodes, get a fresh reference
    local new_node = core.get_node(pos)

    callback(pos, FACEDIR_TO_PIPS[new_node.param2 + 1])
  end
end

local function compute_ai_move(i, j, k)
  local pos = (i * 10000 + j * 100 + k) / 8
  local nth_bit

  pos, nth_bit = math.modf(pos)
  nth_bit = nth_bit * 8

  local byte = string.byte(ai_tree, pos + 1, pos + 2)
  local to_roll = bit32.band(bit32.rshift(byte, 7 - nth_bit), 1) == 1

  return to_roll
end

local function simulate_right_click(pos)
  local node = core.get_node(pos)
  local def = core.registered_nodes[node.name]

  if def and def.on_rightclick then
    def.on_rightclick(pos, node, nil, nil, nil)
  end
end

local function random_wait(func)
  core.after(1 + math.random() * 3, func)
end

local function play_ai_moves()
  if game.ended then return end

  local k = game.scores[AI] - game.prior_scores[AI]
  local to_roll = compute_ai_move(game.scores[AI],
                                  game.scores[PLAYER],
                                  k)

  if to_roll then
    random_wait(function()
      simulate_right_click(DICE_POS)
    end)
  else
    random_wait(function()
      simulate_right_click(BUTTON_POS)
    end)
  end
end

local on_button_press = function(pos)
  if not compare_pos(pos, BUTTON_POS) then return end

  game.prior_scores[game.current_player] = game.scores[game.current_player]

  narrate_pass()
  game.current_player = next_player(game.current_player)

  if game.current_player == AI then
    play_ai_moves()
  end
end

local on_dice_throw = function(pos, pips)
  if not compare_pos(pos, DICE_POS) then return end

  narrate_roll(pips)
  if pips == 1 then
    game.scores[game.current_player] = game.prior_scores[game.current_player]
    game.current_player = next_player(game.current_player)
  else
    game.scores[game.current_player] = game.scores[game.current_player] + pips

    if game.scores[game.current_player] >= GOAL then
      game.ended = true

      game.scores[game.current_player] = "WIN!" -- TODO translate or no?
      game.scores[next_player(game.current_player)] = "LOSE"

      display_scores()
      narrate_win()
      celebrate()

      return
    end
  end

  display_scores()

  if game.current_player == AI then
    play_ai_moves()
  end
end

local function reset_screens()
  set_screen_text(SCREENS.home, "HOME")
  set_screen_text(SCREENS.comp, "COMP")
  display_scores()
end

-- TODO better way of placing once, and only once
core.register_on_generated(function(minp, maxp, _)
  minp, maxp = vector.sort(minp, maxp) -- REVIEW necessary?

  if minp.x < -32 or minp.y < -32 or minp.z < -32 or maxp.x > 47 or maxp.y > 47 or maxp.z > 47 then
    return
  end

  core.place_schematic({ x = -6, y = -6, z = -6 }, modpath .. "/schems/dice_room.mts")
  core.set_node(BUTTON_POS, { name = "mesecons_button:button_off", param2 = 1 })
  core.set_node(DICE_POS, { name = "dice2:dice_white" })

  place_sign({ x = 4, y = -4, z = 0 }, "Roll...", 2)
  place_sign({ x = 4, y = -4, z = -1 }, "... or pass?", 2)

  place_screen(SCREENS.player_score)
  place_screen(SCREENS.ai_score)
  place_screen(SCREENS.home)
  place_screen(SCREENS.comp)

  reset_screens()
end)

core.register_on_joinplayer(function(_)
  reset_screens()
end)

math.randomseed(os.time())
watch_throw("dice2:dice_white", on_dice_throw)
watch_button_press("mesecons_button:button_off", on_button_press)

core.after(1, function()
  spawn_pigs()
end)

function core.is_protected(_, _)
  return true
end
