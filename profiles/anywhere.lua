-- anywhere profile

api_version = 4


local default_speed = 15

function setup()

  local default_speed = 15
  local walking_speed = 4

  return {
    default_speed = default_speed,
    properties = {
      
    },
  }
end

function process_way(profile, way, result)
    result.forward_speed = profile.default_speed
    result.backward_speed = profile.default_speed
    result.forward_rate = profile.default_speed / 3.6
    result.backward_rate = profile.default_speed / 3.6
    result.forward_mode = mode.cycling
    result.backward_mode = mode.cycling

end

function process_node(profile, node, result)
  result.barrier = false
end


return {
  setup = setup,
  process_way = process_way,
  process_node = process_node
}
