-- Sends DEPTH requests in one write, for the plaintext test of wrk:
--   wrk -s pipeline.lua URL -- DEPTH
-- SPDX-License-Identifier: BSD-2-Clause
init = function(args)
  local depth = tonumber(args[1]) or 16
  local r = {}
  for i = 1, depth do r[i] = wrk.format() end
  req = table.concat(r)
end
request = function() return req end
