-- Use of this source code is governed by the GNU AGPL license; see COPYING.

module(...,package.seeall)

local lib = require("core.lib")
local shm = require("core.shm")
local worker = require("core.worker")
local route = require("program.vita.route")
local tunnel = require("program.vita.tunnel")
local nexthop = require("program.vita.nexthop")
local exchange = require("program.vita.exchange")
      schemata = require("program.vita.schemata")
local interlink = require("lib.interlink")
local Receiver = require("apps.interlink.receiver")
local Transmitter = require("apps.interlink.transmitter")
local intel_mp = require("apps.intel_mp.intel_mp")
local numa = require("lib.numa")
local yang = require("lib.yang.yang")
local C = require("ffi").C
local usage = require("program.vita.README_inc")
local confighelp = require("program.vita.README_config_inc")

local confspec = {
   private_interface = {required=true},
   public_interface = {required=true},
   private_ip4 = {required=true},
   public_ip4 = {required=true},
   private_nexthop_ip4 = {required=true},
   public_nexthop_ip4 = {required=true},
   route = {required=true},
   negotiation_ttl = {},
   sa_ttl = {}
}

local esp_keyfile = "group/esp_ephemeral_keys"
local dsp_keyfile = "group/dsp_ephemeral_keys"

function run (args)
   local long_opt = {
      help = "h",
      ["config-help"] = "H",
      ["config-test"] = "t",
      cpu = "c",
      membind = "m"
   }

   local opt, conftest, cpus, memnode = {}, false, {}, nil

   local function exit_usage (status) print(usage) main.exit(status) end

   function opt.h () exit_usage(0) end

   function opt.H () print(confighelp) main.exit(0) end

   function opt.t ()
      conftest = true
   end

   function opt.c (arg)
      for cpu in arg:gmatch('%s*([0-9]+),*') do
         table.insert(cpus, tonumber(cpu) or exit_usage(1))
      end
   end

   function opt.m (arg)
      memnode = tonumber(arg) or exit_usage(1)
   end

   args = lib.dogetopt(args, opt, "hHtc:m:", long_opt)

   if #args < 1 then print(usage) main.exit() end
   local confpath = args[1]

   if conftest then
      local success, error = pcall(
         load_config, schemata['esp-gateway'], confpath
      )
      if success then main.exit(0)
      else print(error) main.exit(1) end
   end

   -- “link” with worker processes
   worker.set_exit_on_worker_death(true)

   -- start crypto processes
   worker.start("ESP", ([[require("program.vita.vita").esp_worker(%s, %s)]])
                   :format(cpus[3], memnode))
   worker.start("DSP", ([[require("program.vita.vita").dsp_worker(%s, %s)]])
                   :format(cpus[4], memnode))

   -- start PublicPort process
   worker.start(
      "PublicPort",
      ([[require("program.vita.vita").public_port_worker(%q, %s, %s)]])
         :format(confpath, cpus[2], memnode)
   )

   -- become PrivatePort process
   private_port_worker(confpath, cpus[1], memnode)
end

function configure_private_router (conf, append)
   conf = lib.parse(conf, confspec)
   local c = append or config.new()

   config.app(c, "PrivateRouter", route.PrivateRouter, {routes=conf.route})
   config.app(c, "PrivateNextHop", nexthop.NextHop4, {
                 node_mac = conf.private_interface.macaddr,
                 node_ip4 = conf.private_ip4,
                 nexthop_ip4 = conf.private_nexthop_ip4
   })
   config.link(c, "PrivateRouter.arp -> PrivateNextHop.arp")

   for _, route in pairs(conf.route) do
      local private_in = "PrivateRouter."..config.link_name(route.net_cidr4)
      local ESP_in = "ESP_"..config.link_name(route.gw_ip4).."_in"
      config.app(c, ESP_in, Transmitter,
                 {name="group/interlink/"..ESP_in, create=true})
      config.link(c, private_in.." -> "..ESP_in..".input")

      local private_out = "PrivateNextHop."..config.link_name(route.net_cidr4)
      local DSP_out = "DSP_"..config.link_name(route.gw_ip4).."_out"
      config.app(c, DSP_out, Receiver,
                 {name="group/interlink/"..DSP_out, create=true})
      config.link(c, DSP_out..".output -> "..private_out)
   end

   local private_links = {
      input = "PrivateRouter.input",
      output = "PrivateNextHop.output"
   }
   return c, private_links
end

function configure_public_router (conf, append)
   conf = lib.parse(conf, confspec)
   local c = append or config.new()

   config.app(c, "PublicRouter", route.PublicRouter, {
                 routes = conf.route,
                 node_ip4 = conf.public_ip4
   })
   config.app(c, "PublicNextHop", nexthop.NextHop4, {
                 node_mac = conf.public_interface.macaddr,
                 node_ip4 = conf.public_ip4,
                 nexthop_ip4 = conf.public_nexthop_ip4
   })
   config.link(c, "PublicRouter.arp -> PublicNextHop.arp")

   config.app(c, "KeyExchange", exchange.KeyManager, {
                 node_ip4 = conf.public_ip4,
                 routes = conf.route,
                 esp_keyfile = esp_keyfile,
                 dsp_keyfile = dsp_keyfile,
                 negotiation_ttl = conf.negotiation_ttl,
                 sa_ttl = conf.sa_ttl
   })
   config.link(c, "PublicRouter.protocol -> KeyExchange.input")
   config.link(c, "KeyExchange.output -> PublicNextHop.protocol")

   for _, route in pairs(conf.route) do
      local public_in = "PublicRouter."..config.link_name(route.gw_ip4)
      local DSP_in = "DSP_"..config.link_name(route.gw_ip4).."_in"
      config.app(c, DSP_in, Transmitter,
                 {name="group/interlink/"..DSP_in, create=true})
      config.link(c, public_in.." -> "..DSP_in..".input")

      local public_out = "PublicNextHop."..config.link_name(route.gw_ip4)
      local ESP_out = "ESP_"..config.link_name(route.gw_ip4).."_out"
      local Tunnel = "Tunnel_"..config.link_name(route.gw_ip4)
      config.app(c, ESP_out, Receiver,
                 {name="group/interlink/"..ESP_out, create=true})
      config.app(c, Tunnel, tunnel.Tunnel4,
                 {src=conf.public_ip4, dst=route.gw_ip4})
      config.link(c, ESP_out..".output -> "..Tunnel..".input")
      config.link(c, Tunnel..".output -> "..public_out)
   end

   local public_links = {
      input = "PublicRouter.input",
      output = "PublicNextHop.output"
   }

   return c, public_links
end

function configure_private_router_with_nic (conf, append)
   conf = lib.parse(conf, confspec)

   numa.check_affinity_for_pci_addresses({conf.private_interface.pciaddr})

   local c, private =
      configure_private_router(conf, append or config.new())

   -- Gracious limit for user defined MTU on private interface to avoid packet
   -- payload overun due to ESP tunnel overhead.
   conf.private_interface.mtu =
      math.min(conf.private_interface.mtu or 8000, 8000)

   conf.private_interface.vmdq = true

   config.app(c, "PrivateNIC", intel_mp.Intel, conf.private_interface)
   config.link(c, "PrivateNIC.output -> "..private.input)
   config.link(c, private.output.." -> PrivateNIC.input")

   return c
end

function configure_public_router_with_nic (conf, append)
   conf = lib.parse(conf, confspec)

   numa.check_affinity_for_pci_addresses({conf.public_interface.pciaddr})

   local c, public =
      configure_public_router(conf, append or config.new())

   conf.public_interface.vmdq = true

   config.app(c, "PublicNIC", intel_mp.Intel, conf.public_interface)
   config.link(c, "PublicNIC.output -> "..public.input)
   config.link(c, public.output.." -> PublicNIC.input")

   return c
end

function private_port_worker (confpath, cpu, memnode)
   cpubind(cpu, memnode)
   engine.log = true
   listen_confpath(
      schemata['esp-gateway'],
      confpath,
      configure_private_router_with_nic
   )
end

function public_port_worker (confpath, cpu, memnode)
   cpubind(cpu, memnode)
   engine.log = true
   listen_confpath(
      schemata['esp-gateway'],
      confpath,
      configure_public_router_with_nic
   )
end

function public_router_loopback_worker (confpath, cpu, memnode)
   local function configure_public_router_loopback (conf)
      local c, public = configure_public_router(conf)
      config.link(c, public.output.." -> "..public.input)
      return c
   end
   cpubind(cpu, memnode)
   engine.log = true
   listen_confpath(
      schemata['esp-gateway'],
      confpath,
      configure_public_router_loopback
   )
end


-- ephemeral_keys := { { gw_ip4=(IPv4), [ sa=(SA) ] }, ... }   (see exchange)

function configure_esp (ephemeral_keys)
   local c = config.new()

   for _, route in pairs(ephemeral_keys.route) do
      -- Configure interlink receiver/transmitter for route
      local ESP_in = "ESP_"..config.link_name(route.gw_ip4).."_in"
      local ESP_out = "ESP_"..config.link_name(route.gw_ip4).."_out"
      config.app(c, ESP_in, Receiver, {name="group/interlink/"..ESP_in})
      config.app(c, ESP_out, Transmitter, {name="group/interlink/"..ESP_out})
      -- Configure SA if present
      if route.sa then
         local ESP = "ESP_"..route.sa.spi
         config.app(c, ESP, tunnel.Encapsulate, route.sa)
         config.link(c, ESP_in..".output -> "..ESP..".input4")
         config.link(c, ESP..".output -> "..ESP_out..".input")
      end
   end

   return c
end

function configure_dsp (ephemeral_keys)
   local c = config.new()

   for _, route in pairs(ephemeral_keys.route) do
      -- Configure interlink receiver/transmitter for route
      local DSP_in = "DSP_"..config.link_name(route.gw_ip4).."_in"
      local DSP_out = "DSP_"..config.link_name(route.gw_ip4).."_out"
      config.app(c, DSP_in, Receiver, {name="group/interlink/"..DSP_in})
      config.app(c, DSP_out, Transmitter, {name="group/interlink/"..DSP_out})
      -- Configure SA if present
      if route.sa then
         local DSP = "DSP_"..route.sa.spi
         config.app(c, DSP, tunnel.Decapsulate, route.sa)
         config.link(c, DSP_in..".output -> "..DSP..".input")
         config.link(c, DSP..".output4 -> "..DSP_out..".input")
      end
   end

   return c
end

function esp_worker (cpu, memnode)
   cpubind(cpu, memnode)
   engine.log = true
   listen_confpath(
      schemata['ephemeral-keys'],
      shm.root.."/"..shm.resolve(esp_keyfile),
      configure_esp
   )
end

function dsp_worker (cpu, memnode)
   cpubind(cpu, memnode)
   engine.log = true
   listen_confpath(
      schemata['ephemeral-keys'],
      shm.root.."/"..shm.resolve(dsp_keyfile),
      configure_dsp
   )
end

function load_config (schema, confpath)
   return yang.load_data_for_schema(
      schema, lib.readfile(confpath, "a*"), confpath
   )
end

function listen_confpath (schema, confpath, loader, interval)
   interval = interval or 1e9

   local mtime = 0
   local needs_reconfigure = true
   timer.activate(timer.new(
      "check-for-reconfigure",
      function () needs_reconfigure = C.stat_mtime(confpath) ~= mtime end,
      interval,
      "repeating"
   ))

   local function run_loader ()
      return loader(load_config(schema, confpath))
   end

   while true do
      needs_reconfigure = false
      local success, c = pcall(run_loader)
      if success then
         print("Reconfigure: loaded "..confpath)
         mtime = C.stat_mtime(confpath)
         engine.configure(c)
      else
         print("Reconfigure: error: "..c)
      end
      engine.main({
         done = function() return needs_reconfigure end,
         no_report = true
      })
   end
end

-- Bind to CPU. If this is a NUMA system we bind to a memory node.
function cpubind (cpu, node)
   if cpu then
      numa.bind_to_cpu(cpu)
   elseif numa.has_numa() then
      numa.bind_to_numa_node(node)
   end
end
