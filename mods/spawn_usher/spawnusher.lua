--[[
Copyright (c) 2015, Robert 'Bobby' Zenz
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--]]


--- Spawn usher is a system that allows to correct the spawn position of players
-- without knowing anything about the mapgen.
--
-- The system will register callbacks for newplayer and respawnplayer and will
-- try to find an air bubble, either upwards or downwards, which the player can
-- fit into. If an air bubble is found, the player will be moved there. If
-- the block is not loaded, it will be tried again after a certain amount of
-- time.
--
-- The only function that should be called from clients is activate.
spawnusher = {
	--- The list of callbacks that are invoked after the player has been placed.
	after_spawn_callbacks = List:new(),
	
	--- The physics override that is set to make the player inmovable.
	physics_override = {
		speed = 0,
		jump = 0,
		gravity = 0,
		sneak = false,
		sneak_glitch = false
	},
	
	--- The original physics of the payers.
	player_physics = {},
	
	--- The list of players that need to be placed.
	players = List:new(),
	
	--- The random object that is used to get random values.
	random = nil,
	
	--- The placement radius around the spawn.
	random_placement_radius = settings.get_number("spawnusher_placement_radius", 40),
	
	--- The required air bubble size.
	required_bubble_size = settings.get_number("spawnusher_bubble_size", 2),
	
	--- The retry time.
	retry_time = settings.get_number("spawnusher_retry_time", 0.5),
	
	--- If the system is currently scheduled for execution.
	scheduled = false,
	
	--- The spawnpoint that is configured.
	spawnpoint = settings.get_pos("static_spawnpoint", {
		x = 0,
		y = 0,
		z = 0
	}),
	
	--- The registered spawnpoint providers.
	spawnpoint_providers = List:new()
}


--- Activates the spawn usher system, if it has not been deactivated by
-- a seeting in the configuration.
function spawnusher.activate()
	if settings.get_bool("spawnusher_activate", true) then
		-- Initialize the PcgRandom with the current time. Given that placement
		-- of the player is not critical or needs to be reproducable in any way,
		-- it really does not matter here.
		spawnusher.random = PcgRandom(os.time())
		
		minetest.register_on_newplayer(spawnusher.on_spawn_player)
		minetest.register_on_respawnplayer(spawnusher.on_spawn_player)
	end
end

--- Tests if the given position is an air bubble big enough.
--
-- @param start_pos The position at which to check.
-- @return true if at the given position is an air bubble big enough.
function spawnusher.is_air_bubble(start_pos)
	local pos = {
		x = start_pos.x,
		y = start_pos.y,
		z = start_pos.z
	}
	
	for counter = 1, spawnusher.required_bubble_size, 1 do
		pos.y = pos.y + 1
		
		if minetest.get_node(pos).name ~= "air" then
			return false
		end
	end
	
	return true
end

--- Schedules the player to be moved later. Also moves the player to the given
-- position.
--
-- @param player The player object.
-- @param current_pos The current position to which the player will be moved.
function spawnusher.move_later(player, current_pos)
	player:setpos(current_pos)
	
	spawnusher.players:add(player)
	
	if not spawnusher.scheduled then
		spawnusher.scheduled = true
		
		minetest.after(spawnusher.retry_time, spawnusher.move_players)
	end
end

--- Moves the player randomly on the x and z plane.
--
-- @param player The Player object to move.
function spawnusher.move_random(player)
	local move_x = spawnusher.random:next(-spawnusher.random_placement_radius, spawnusher.random_placement_radius)
	local move_z = spawnusher.random:next(-spawnusher.random_placement_radius, spawnusher.random_placement_radius)
	
	local pos = player:getpos()
	
	pos.x = pos.x + move_x
	pos.z = pos.z + move_z
	
	player:setpos(pos)
end

--- Moves the player to a safe location.
--
-- @param player The player object.
function spawnusher.move_player(player)
	local pos = player:getpos()
	
	-- Could be while true, but at least this is halfway sane.
	while mathutil.in_range(pos.y, -31000, 31000) do
		local current = minetest.get_node(pos).name
		
		if current ~= "air" and current ~= "ignore" then
			-- The current node is neither air nor ignore, that means it
			-- is "solid", so we walk upwards looking for air.
			pos.y = pos.y + 1
		elseif current == "air" then
			-- The current node is air, now we will check if the node below it
			-- is also air, if yes we will move downwards, if not we will check
			-- if here is an air bubble.
			local beneath_pos = {
				x = pos.x,
				y = pos.y - 1,
				z = pos.z
			}
			
			local beneath_node = minetest.get_node(beneath_pos).name
			
			if beneath_node == "air" then
				-- The node below is air, move two downwards looking for
				-- a "solid" node.
				pos.y = pos.y - 2
			elseif beneath_node == "ignore" then
				-- The node below is ignore, means we will have to try again
				-- later.
				spawnusher.move_later(player, pos)
				return
			elseif spawnusher.is_air_bubble(pos) then
				-- Awesome! Place the user here.
				player:setpos(pos)
				
				-- Randomize the direction in which the player looks.
				player:set_look_yaw(math.rad(spawnusher.random:next(0, 360)))
				
				-- Reset the physics override.
				player:set_physics_override(spawnusher.player_physics[player:get_player_name()])
				-- Remove the saved one.
				spawnusher.player_physics[player:get_player_name()] = nil
				
				-- Invoke the callbacks.
				spawnusher.after_spawn_callbacks:invoke(player, pos)
				
				return
			else
				-- The node beneath is neither air nor ignore and there is no
				-- air bubble big enough, lets go upwards and see if that
				-- helps.
				while mathutil.in_range(pos.y, -31000, 31000) do
					pos.y = pos.y + 1
					
					local upward_node = minetest.get_node(pos).name
					
					if upward_node == "ignore" then
						spawnusher.move_later(player, pos)
						return
					elseif upward_node ~= "air" then
						break
					end
				end
			end
		elseif current == "ignore" then
			-- The current node is ignore, which means we need to retry later.
			spawnusher.move_later(player, pos)
			return
		end
	end
end

--- Move all players that could not be placed so far.
function spawnusher.move_players()
	-- Copy the list to make sure that no one adds a player while we iterate
	-- over it. Though, I'm not sure if that is actually possible, but the Java
	-- programmer does not stop to scream "race condition" without this.
	local to_move_players = spawnusher.players
	spawnusher.players = List:new()
	
	to_move_players:foreach(function(player, index)
		spawnusher.move_player(player)
	end)
	
	-- If there are still players that could not be placed, schedule it again.
	if spawnusher.players:size() > 0 then
		minetest.after(spawnusher.retry_time, spawnusher.move_players)
	else
		spawnusher.scheduled = false
	end
end

--- Callback for if a player spawns.
--
-- @param player The Player that spawned.
-- @return true, to disable default placement.
function spawnusher.on_spawn_player(player)
	-- Override the physics of the player to make sure that the player does
	-- not fall while we wait and also does not move around.
	spawnusher.player_physics[player:get_player_name()] = player:get_physics_override()
	player:set_physics_override(spawnusher.physics_override)
	
	-- Move the player to the set/default spawn point.
	player:setpos(spawnusher.spawnpoint)
	
	-- Move the player randomly afterwards.
	spawnusher.move_random(player)
	
	local exact_pos = false
	local spawn_pos = player:getpos()
	
	-- Run the position through the providers.
	spawnusher.spawnpoint_providers:foreach(function(provider, index)
		local provided_pos, provided_exact_pos = provider(player, spawn_pos)
		
		if provided_pos ~= nil then
			spawn_pos = provided_pos
		end
		if provided_exact_pos ~= nil then
			exact_pos = provided_exact_pos
		end
	end)
	
	player:setpos(spawn_pos)
	
	if not exact_pos then
		-- Now find a nice spawn place for the player.
		spawnusher.move_player(player)
	end
	
	return true
end

--- Allows to register callbacks after a player has been spawned by spawn usher.
--
-- @param callback The callback to invoke, a function that accepts the player
--                 object as first parameter and the spawn point as second.
function spawnusher.register_after_spawn_callback(callback)
	spawnusher.after_spawn_callbacks:add(callback)
end

--- Allows to register providers that are called after the final position of
-- the player has been determined. The provider can return a different position,
-- or nil if it is happy with the given position, and if it is is the exact
-- position or not.
--
-- @param provider The provider. A function that accepts two parameters,
--                 the Player object and the spawn position that the system
--                 calculated. It can return a new position, a table with
--                 x y z values, or nil if the position should not be changed.
--                 The second return value can be true to make the system use
--                 the provided position without looking for an air bubble.
function spawnusher.register_spawnpoint_provider(provider)
	spawnusher.spawnpoint_providers:add(provider)
end

