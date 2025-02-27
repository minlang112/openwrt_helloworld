local api = require "luci.passwall.api"
local appname = "passwall"
local uci = api.uci
local datatypes = api.datatypes
local has_singbox = api.finded_com("singbox")
local has_xray = api.finded_com("xray")
local has_gfwlist = api.fs.access("/usr/share/passwall/rules/gfwlist")
local has_chnlist = api.fs.access("/usr/share/passwall/rules/chnlist")
local has_chnroute = api.fs.access("/usr/share/passwall/rules/chnroute")

m = Map(appname)

local nodes_table = {}
for k, e in ipairs(api.get_valid_nodes()) do
	nodes_table[#nodes_table + 1] = e
end

local normal_list = {}
local balancing_list = {}
local shunt_list = {}
local iface_list = {}
for k, v in pairs(nodes_table) do
	if v.node_type == "normal" then
		normal_list[#normal_list + 1] = v
	end
	if v.protocol and v.protocol == "_balancing" then
		balancing_list[#balancing_list + 1] = v
	end
	if v.protocol and v.protocol == "_shunt" then
		shunt_list[#shunt_list + 1] = v
	end
	if v.protocol and v.protocol == "_iface" then
		iface_list[#iface_list + 1] = v
	end
end

local socks_list = {}

local tcp_socks_server = "127.0.0.1" .. ":" .. (uci:get(appname, "@global[0]", "tcp_node_socks_port") or "1070")
local socks_table = {}
socks_table[#socks_table + 1] = {
	id = tcp_socks_server,
	remark = tcp_socks_server .. " - " .. translate("TCP Node")
}
uci:foreach(appname, "socks", function(s)
	if s.enabled == "1" and s.node then
		local id, remark
		for k, n in pairs(nodes_table) do
			if (s.node == n.id) then
				remark = n["remark"]; break
			end
		end
		id = "127.0.0.1" .. ":" .. s.port
		socks_table[#socks_table + 1] = {
			id = id,
			remark = id .. " - " .. (remark or translate("Misconfigured"))
		}
		socks_list[#socks_list + 1] = {
			id = "Socks_" .. s[".name"],
			remark = translate("Socks Config") .. " " .. string.format("[%s %s]", s.port, translate("Port"))
		}
	end
end)

local doh_validate = function(self, value, t)
	if value ~= "" then
		value = api.trim(value)
		local flag = 0
		local util = require "luci.util"
		local val = util.split(value, ",")
		local url = val[1]
		val[1] = nil
		for i = 1, #val do
			local v = val[i]
			if v then
				if not datatypes.ipmask4(v) and not datatypes.ipmask6(v) then
					flag = 1
				end
			end
		end
		if flag == 0 then
			return value
		end
	end
	return nil, translate("DoH request address") .. " " .. translate("Format must be:") .. " URL,IP"
end

m:append(Template(appname .. "/global/status"))

s = m:section(TypedSection, "global")
s.anonymous = true
s.addremove = false

s:tab("Main", translate("Main"))

-- [[ Global Settings ]]--
o = s:taboption("Main", Flag, "enabled", translate("Main switch"))
o.rmempty = false

---- TCP Node
tcp_node = s:taboption("Main", ListValue, "tcp_node", "<a style='color: red'>" .. translate("TCP Node") .. "</a>")
tcp_node:value("nil", translate("Close"))

---- UDP Node
udp_node = s:taboption("Main", ListValue, "udp_node", "<a style='color: red'>" .. translate("UDP Node") .. "</a>")
udp_node:value("nil", translate("Close"))
udp_node:value("tcp", translate("Same as the tcp node"))

-- 分流
if (has_singbox or has_xray) and #nodes_table > 0 then
	local function get_cfgvalue(shunt_node_id, option)
		return function(self, section)
			return m:get(shunt_node_id, option) or "nil"
		end
	end
	local function get_write(shunt_node_id, option)
		return function(self, section, value)
			m:set(shunt_node_id, option, value)
		end
	end
	if #normal_list > 0 then
		for k, v in pairs(shunt_list) do
			local vid = v.id
			-- shunt node type, Sing-Box or Xray
			local type = s:taboption("Main", ListValue, vid .. "-type", translate("Type"))
			if has_singbox then
				type:value("sing-box", "Sing-Box")
			end
			if has_xray then
				type:value("Xray", translate("Xray"))
			end
			type.cfgvalue = get_cfgvalue(v.id, "type")
			type.write = get_write(v.id, "type")

			-- pre-proxy
			o = s:taboption("Main", Flag, vid .. "-preproxy_enabled", translate("Preproxy"))
			o:depends("tcp_node", v.id)
			o.rmempty = false
			o.cfgvalue = get_cfgvalue(v.id, "preproxy_enabled")
			o.write = get_write(v.id, "preproxy_enabled")

			o = s:taboption("Main", ListValue, vid .. "-main_node", string.format('<a style="color:red">%s</a>', translate("Preproxy Node")), translate("Set the node to be used as a pre-proxy. Each rule (including <code>Default</code>) has a separate switch that controls whether this rule uses the pre-proxy or not."))
			o:depends(vid .. "-preproxy_enabled", "1")
			for k1, v1 in pairs(socks_list) do
				o:value(v1.id, v1.remark)
			end
			for k1, v1 in pairs(balancing_list) do
				o:value(v1.id, v1.remark)
			end
			for k1, v1 in pairs(iface_list) do
				o:value(v1.id, v1.remark)
			end
			for k1, v1 in pairs(normal_list) do
				o:value(v1.id, v1.remark)
			end
			o.cfgvalue = get_cfgvalue(v.id, "main_node")
			o.write = get_write(v.id, "main_node")

			if (has_singbox and has_xray) or (v.type == "sing-box" and not has_singbox) or (v.type == "Xray" and not has_xray) then
				type:depends("tcp_node", v.id)
			else
				type:depends("tcp_node", "hide") --不存在的依赖，即始终隐藏
			end

			uci:foreach(appname, "shunt_rules", function(e)
				local id = e[".name"]
				local node_option = vid .. "-" .. id .. "_node"
				if id and e.remarks then
					o = s:taboption("Main", ListValue, node_option, string.format('* <a href="%s" target="_blank">%s</a>', api.url("shunt_rules", id), e.remarks))
					o.cfgvalue = get_cfgvalue(v.id, id)
					o.write = get_write(v.id, id)
					o:depends("tcp_node", v.id)
					o:value("nil", translate("Close"))
					o:value("_default", translate("Default"))
					o:value("_direct", translate("Direct Connection"))
					o:value("_blackhole", translate("Blackhole"))

					local pt = s:taboption("Main", ListValue, vid .. "-".. id .. "_proxy_tag", string.format('* <a style="color:red">%s</a>', e.remarks .. " " .. translate("Preproxy")))
					pt.cfgvalue = get_cfgvalue(v.id, id .. "_proxy_tag")
					pt.write = get_write(v.id, id .. "_proxy_tag")
					pt:value("nil", translate("Close"))
					pt:value("main", translate("Preproxy Node"))
					pt.default = "nil"
					for k1, v1 in pairs(socks_list) do
						o:value(v1.id, v1.remark)
					end
					for k1, v1 in pairs(balancing_list) do
						o:value(v1.id, v1.remark)
					end
					for k1, v1 in pairs(iface_list) do
						o:value(v1.id, v1.remark)
					end
					for k1, v1 in pairs(normal_list) do
						o:value(v1.id, v1.remark)
						pt:depends({ [node_option] = v1.id, [vid .. "-preproxy_enabled"] = "1" })
					end
				end
			end)

			local id = "default_node"
			o = s:taboption("Main", ListValue, vid .. "-" .. id, string.format('* <a style="color:red">%s</a>', translate("Default")))
			o.cfgvalue = get_cfgvalue(v.id, id)
			o.write = get_write(v.id, id)
			o:depends("tcp_node", v.id)
			o:value("_direct", translate("Direct Connection"))
			o:value("_blackhole", translate("Blackhole"))
			for k1, v1 in pairs(socks_list) do
				o:value(v1.id, v1.remark)
			end
			for k1, v1 in pairs(balancing_list) do
				o:value(v1.id, v1.remark)
			end
			for k1, v1 in pairs(iface_list) do
				o:value(v1.id, v1.remark)
			end
			for k1, v1 in pairs(normal_list) do
				o:value(v1.id, v1.remark)
			end

			local id = "default_proxy_tag"
			o = s:taboption("Main", ListValue, vid .. "-" .. id, string.format('* <a style="color:red">%s</a>', translate("Default Preproxy")), translate("When using, localhost will connect this node first and then use this node to connect the default node."))
			o.cfgvalue = get_cfgvalue(v.id, id)
			o.write = get_write(v.id, id)
			o:value("nil", translate("Close"))
			o:value("main", translate("Preproxy Node"))
			for k1, v1 in pairs(normal_list) do
				if v1.protocol ~= "_balancing" then
					o:depends({ [vid .. "-default_node"] = v1.id, [vid .. "-preproxy_enabled"] = "1" })
				end
			end
		end
	else
		local tips = s:taboption("Main", DummyValue, "tips", " ")
		tips.rawhtml = true
		tips.cfgvalue = function(t, n)
			return string.format('<a style="color: red">%s</a>', translate("There are no available nodes, please add or subscribe nodes first."))
		end
		tips:depends({ tcp_node = "nil", ["!reverse"] = true })
		for k, v in pairs(shunt_list) do
			tips:depends("udp_node", v.id)
		end
		for k, v in pairs(balancing_list) do
			tips:depends("udp_node", v.id)
		end
	end
end

tcp_node_socks_port = s:taboption("Main", Value, "tcp_node_socks_port", translate("TCP Node") .. " Socks " .. translate("Listen Port"))
tcp_node_socks_port.default = 1070
tcp_node_socks_port.datatype = "port"
tcp_node_socks_port:depends({ tcp_node = "nil", ["!reverse"] = true })
--[[
if has_singbox or has_xray then
	tcp_node_http_port = s:taboption("Main", Value, "tcp_node_http_port", translate("TCP Node") .. " HTTP " .. translate("Listen Port") .. " " .. translate("0 is not use"))
	tcp_node_http_port.default = 0
	tcp_node_http_port.datatype = "port"
end
]]--
tcp_node_socks_bind_local = s:taboption("Main", Flag, "tcp_node_socks_bind_local", translate("TCP Node") .. " Socks " .. translate("Bind Local"), translate("When selected, it can only be accessed localhost."))
tcp_node_socks_bind_local.default = "1"
tcp_node_socks_bind_local:depends({ tcp_node = "nil", ["!reverse"] = true })

s:tab("DNS", translate("DNS"))

dns_shunt = s:taboption("DNS", ListValue, "dns_shunt", "DNS " .. translate("Shunt"))
dns_shunt:value("dnsmasq", "Dnsmasq")
dns_shunt:value("chinadns-ng", "Dnsmasq + ChinaDNS-NG")

o = s:taboption("DNS", Flag, "filter_proxy_ipv6", translate("Filter Proxy Host IPv6"), translate("Experimental feature."))
o.default = "0"

---- DNS Forward Mode
dns_mode = s:taboption("DNS", ListValue, "dns_mode", translate("Filter Mode"))
dns_mode:value("udp", translatef("Requery DNS By %s", "UDP"))
dns_mode:value("tcp", translatef("Requery DNS By %s", "TCP"))
if api.is_finded("dns2socks") then
	dns_mode:value("dns2socks", "dns2socks")
end
if has_singbox then
	dns_mode:value("sing-box", "Sing-Box")
end
if has_xray then
	dns_mode:value("xray", "Xray")
end

o = s:taboption("DNS", ListValue, "xray_dns_mode", translate("Request protocol"))
o:value("tcp", "TCP")
o:value("tcp+doh", "TCP + DoH (" .. translate("A/AAAA type") .. ")")
o:depends("dns_mode", "xray")
o.cfgvalue = function(self, section)
	return m:get(section, "v2ray_dns_mode")
end
o.write = function(self, section, value)
	if dns_mode:formvalue(section) == "xray" then
		return m:set(section, "v2ray_dns_mode", value)
	end
end

o = s:taboption("DNS", ListValue, "singbox_dns_mode", translate("Request protocol"))
o:value("tcp", "TCP")
o:value("doh", "DoH")
o:depends("dns_mode", "sing-box")
o.cfgvalue = function(self, section)
	return m:get(section, "v2ray_dns_mode")
end
o.write = function(self, section, value)
	if dns_mode:formvalue(section) == "sing-box" then
		return m:set(section, "v2ray_dns_mode", value)
	end
end

o = s:taboption("DNS", Value, "socks_server", translate("Socks Server"), translate("Make sure socks service is available on this address."))
for k, v in pairs(socks_table) do o:value(v.id, v.remark) end
o.default = socks_table[1].id
o.validate = function(self, value, t)
	if not datatypes.ipaddrport(value) then
		return nil, translate("Socks Server") .. " " .. translate("Not valid IP format, please re-enter!")
	end
	return value
end
o:depends({dns_mode = "dns2socks"})

---- DNS Forward
o = s:taboption("DNS", Value, "remote_dns", translate("Remote DNS"))
o.datatype = "or(ipaddr,ipaddrport)"
o.default = "1.1.1.1"
o:value("1.1.1.1", "1.1.1.1 (CloudFlare)")
o:value("1.1.1.2", "1.1.1.2 (CloudFlare-Security)")
o:value("8.8.4.4", "8.8.4.4 (Google)")
o:value("8.8.8.8", "8.8.8.8 (Google)")
o:value("9.9.9.9", "9.9.9.9 (Quad9-Recommended)")
o:value("149.112.112.112", "149.112.112.112 (Quad9-Recommended)")
o:value("208.67.220.220", "208.67.220.220 (OpenDNS)")
o:value("208.67.222.222", "208.67.222.222 (OpenDNS)")
if nixio.fs.access("/usr/share/mosdns/mosdns.sh") then
	local mosdns_port = string.gsub(luci.sys.exec("uci -q get mosdns.config.listen_port"), "\n", "")
	if mosdns_port ~= nil and result ~= "" then
		o:value("127.0.0.1:" .. mosdns_port, "127.0.0.1:" .. mosdns_port .. " (MosDNS)")
	end
end
o:depends({dns_mode = "dns2socks"})
o:depends({dns_mode = "tcp"})
o:depends({dns_mode = "udp"})
o:depends({xray_dns_mode = "tcp"})
o:depends({xray_dns_mode = "tcp+doh"})
o:depends({singbox_dns_mode = "tcp"})

---- DoH
o = s:taboption("DNS", Value, "remote_dns_doh", translate("Remote DNS DoH"))
o.default = "https://1.1.1.1/dns-query"
o:value("https://1.1.1.1/dns-query", "CloudFlare")
o:value("https://1.1.1.2/dns-query", "CloudFlare-Security")
o:value("https://8.8.4.4/dns-query", "Google 8844")
o:value("https://8.8.8.8/dns-query", "Google 8888")
o:value("https://9.9.9.9/dns-query", "Quad9-Recommended 9.9.9.9")
o:value("https://149.112.112.112/dns-query", "Quad9-Recommended 149.112.112.112")
o:value("https://208.67.222.222/dns-query", "OpenDNS")
o:value("https://dns.adguard.com/dns-query,176.103.130.130", "AdGuard")
o:value("https://doh.libredns.gr/dns-query,116.202.176.26", "LibreDNS")
o:value("https://doh.libredns.gr/ads,116.202.176.26", "LibreDNS (No Ads)")
o.validate = doh_validate
o:depends({xray_dns_mode = "tcp+doh"})
o:depends({singbox_dns_mode = "doh"})

o = s:taboption("DNS", Value, "dns_client_ip", translate("EDNS Client Subnet"))
o.description = translate("Notify the DNS server when the DNS query is notified, the location of the client (cannot be a private IP address).") .. "<br />" ..
				translate("This feature requires the DNS server to support the Edns Client Subnet (RFC7871).")
o.datatype = "ipaddr"
o:depends({dns_mode = "xray"})

o = s:taboption("DNS", Flag, "remote_fakedns", "FakeDNS", translate("Use FakeDNS work in the shunt domain that proxy."))
o.default = "0"
o:depends({dns_mode = "sing-box", dns_shunt = "dnsmasq"})
o.validate = function(self, value, t)
	if value and value == "1" then
		local _dns_mode = dns_mode:formvalue(t)
		local _tcp_node = tcp_node:formvalue(t)
		if _dns_mode and _tcp_node and _tcp_node ~= "nil" then
			if m:get(_tcp_node, "type"):lower() ~= _dns_mode then
				return nil, translatef("TCP node must be '%s' type to use FakeDNS.", _dns_mode)
			end
		end
	end
	return value
end

o = s:taboption("DNS", ListValue, "chinadns_ng_default_tag", translate("Default DNS"))
o.default = "none"
o:value("gfw", translate("Remote DNS"))
o:value("chn", translate("Direct DNS"))
o:value("none", translate("Smart, Do not accept no-ip reply from Direct DNS"))
o:value("none_noip", translate("Smart, Accept no-ip reply from Direct DNS"))
local desc = "<ul>"
		.. "<li>" .. translate("When not matching any domain name list:") .. "</li>"
		.. "<li>" .. translate("Remote DNS: Can avoid more DNS leaks, but some domestic domain names maybe to proxy!") .. "</li>"
		.. "<li>" .. translate("Direct DNS: Internet experience may be better, but DNS will be leaked!") .. "</li>"
o.description = desc
		.. "<li>" .. translate("Smart: Forward to both direct and remote DNS, if the direct DNS resolution result is a mainland China IP, then use the direct result, otherwise use the remote result.") .. "</li>"
		.. "<li>" .. translate("In smart mode, no-ip reply from Direct DNS:") .. "</li>"
		.. "<li>" .. translate("Do not accept: Wait and use Remote DNS Reply.") .. "</li>"
		.. "<li>" .. translate("Accept: Trust the Reply, using this option can improve DNS resolution speeds for some mainland IPv4-only sites.") .. "</li>"
		.. "</ul>"
o:depends({dns_shunt = "chinadns-ng", tcp_proxy_mode = "proxy", chn_list = "direct"})

o = s:taboption("DNS", ListValue, "use_default_dns", translate("Default DNS"))
o.default = "direct"
o:value("remote", translate("Remote DNS"))
o:value("direct", translate("Direct DNS"))
o.description = desc .. "</ul>"
o:depends({dns_shunt = "dnsmasq", tcp_proxy_mode = "proxy", chn_list = "direct"})

o = s:taboption("DNS", Flag, "dns_redirect", "DNS " .. translate("Redirect"), translate("Force Router DNS server to all local devices."))
o.default = "0"

if (uci:get(appname, "@global_forwarding[0]", "use_nft") or "0") == "1" then
	o = s:taboption("DNS", Button, "clear_ipset", translate("Clear NFTSET"), translate("Try this feature if the rule modification does not take effect."))
else
	o = s:taboption("DNS", Button, "clear_ipset", translate("Clear IPSET"), translate("Try this feature if the rule modification does not take effect."))
end
o.inputstyle = "remove"
function o.write(e, e)
	luci.sys.call('[ -n "$(nft list sets 2>/dev/null | grep \"passwall_\")" ] && sh /usr/share/passwall/nftables.sh flush_nftset_reload || sh /usr/share/passwall/iptables.sh flush_ipset_reload > /dev/null 2>&1 &')
	luci.http.redirect(api.url("log"))
end

s:tab("Proxy", translate("Mode"))

o = s:taboption("Proxy", Flag, "use_direct_list", translatef("Use %s", translate("Direct List")))
o.default = "1"

o = s:taboption("Proxy", Flag, "use_proxy_list", translatef("Use %s", translate("Proxy List")))
o.default = "1"

o = s:taboption("Proxy", Flag, "use_block_list", translatef("Use %s", translate("Block List")))
o.default = "1"

if has_gfwlist then
	o = s:taboption("Proxy", Flag, "use_gfw_list", translatef("Use %s", translate("GFW List")))
	o.default = "1"
end

if has_chnlist or has_chnroute then
	o = s:taboption("Proxy", ListValue, "chn_list", translate("China List"))
	o:value("0", translate("Close(Not use)"))
	o:value("direct", translate("Direct Connection"))
	o:value("proxy", translate("Proxy"))
	o.default = "direct"
end

---- TCP Default Proxy Mode
tcp_proxy_mode = s:taboption("Proxy", ListValue, "tcp_proxy_mode", "TCP " .. translate("Default Proxy Mode"))
tcp_proxy_mode:value("disable", translate("No Proxy"))
tcp_proxy_mode:value("proxy", translate("Proxy"))
tcp_proxy_mode.default = "proxy"

---- UDP Default Proxy Mode
udp_proxy_mode = s:taboption("Proxy", ListValue, "udp_proxy_mode", "UDP " .. translate("Default Proxy Mode"))
udp_proxy_mode:value("disable", translate("No Proxy"))
udp_proxy_mode:value("proxy", translate("Proxy"))
udp_proxy_mode.default = "proxy"

o = s:taboption("Proxy", DummyValue, "switch_mode", " ")
o.template = appname .. "/global/proxy"

o = s:taboption("Proxy", Flag, "localhost_proxy", translate("Localhost Proxy"), translate("When selected, localhost can transparent proxy."))
o.default = "1"
o.rmempty = false

o = s:taboption("Proxy", Flag, "client_proxy", translate("Client Proxy"), translate("When selected, devices in LAN can transparent proxy. Otherwise, it will not be proxy. But you can still use access control to allow the designated device to proxy."))
o.default = "1"
o.rmempty = false

o = s:taboption("Proxy", DummyValue, "_proxy_tips", " ")
o.rawhtml = true
o.cfgvalue = function(t, n)
	return string.format('<a style="color: red" href="%s">%s</a>', api.url("acl"), translate("Want different devices to use different proxy modes/ports/nodes? Please use access control."))
end

s:tab("log", translate("Log"))
o = s:taboption("log", Flag, "log_tcp", translate("Enable") .. " " .. translatef("%s Node Log", "TCP"))
o.default = "1"
o.rmempty = false

o = s:taboption("log", Flag, "log_udp", translate("Enable") .. " " .. translatef("%s Node Log", "UDP"))
o.default = "1"
o.rmempty = false

loglevel = s:taboption("log", ListValue, "loglevel", "Sing-Box/Xray " .. translate("Log Level"))
loglevel.default = "warning"
loglevel:value("debug")
loglevel:value("info")
loglevel:value("warning")
loglevel:value("error")

trojan_loglevel = s:taboption("log", ListValue, "trojan_loglevel", "Trojan " ..  translate("Log Level"))
trojan_loglevel.default = "2"
trojan_loglevel:value("0", "all")
trojan_loglevel:value("1", "info")
trojan_loglevel:value("2", "warn")
trojan_loglevel:value("3", "error")
trojan_loglevel:value("4", "fatal")

o = s:taboption("log", Flag, "advanced_log_feature", translate("Advanced log feature"), translate("For professionals only."))
o.default = "0"
o = s:taboption("log", Flag, "sys_log", translate("Logging to system log"), translate("Logging to the system log for more advanced functions. For example, send logs to a dedicated log server."))
o:depends("advanced_log_feature", "1")
o.default = "0"
o = s:taboption("log", Value, "persist_log_path", translate("Persist log file directory"), translate("The path to the directory used to store persist log files, the \"/\" at the end can be omitted. Leave it blank to disable this feature."))
o:depends({ ["advanced_log_feature"] = 1, ["sys_log"] = 0 })
o = s:taboption("log", Value, "log_event_filter", translate("Log Event Filter"), translate("Support regular expression."))
o:depends("advanced_log_feature", "1")
o = s:taboption("log", Value, "log_event_cmd", translate("Shell Command"), translate("Shell command to execute, replace log content with %s."))
o:depends("advanced_log_feature", "1")

s:tab("faq", "FAQ")

o = s:taboption("faq", DummyValue, "")
o.template = appname .. "/global/faq"

-- [[ Socks Server ]]--
o = s:taboption("Main", Flag, "socks_enabled", "Socks " .. translate("Main switch"))
o.rmempty = false

s = m:section(TypedSection, "socks", translate("Socks Config"))
s.template = "cbi/tblsection"
s.anonymous = true
s.addremove = true
s.extedit = api.url("socks_config", "%s")
function s.create(e, t)
	local uuid = api.gen_short_uuid()
	t = uuid
	TypedSection.create(e, t)
	luci.http.redirect(e.extedit:format(t))
end

o = s:option(DummyValue, "status", translate("Status"))
o.rawhtml = true
o.cfgvalue = function(t, n)
	return string.format('<div class="_status" socks_id="%s"></div>', n)
end

---- Enable
o = s:option(Flag, "enabled", translate("Enable"))
o.default = 1
o.rmempty = false

socks_node = s:option(ListValue, "node", translate("Socks Node"))

local n = 1
uci:foreach(appname, "socks", function(s)
	if s[".name"] == section then
		return false
	end
	n = n + 1
end)

o = s:option(Value, "port", "Socks " .. translate("Listen Port"))
o.default = n + 1080
o.datatype = "port"
o.rmempty = false

if has_singbox or has_xray then
	o = s:option(Value, "http_port", "HTTP " .. translate("Listen Port") .. " " .. translate("0 is not use"))
	o.default = 0
	o.datatype = "port"
end

for k, v in pairs(nodes_table) do
	tcp_node:value(v.id, v["remark"])
	udp_node:value(v.id, v["remark"])
	if v.type == "Socks" then
		if has_singbox or has_xray then
			socks_node:value(v.id, v["remark"])
		end
	else
		socks_node:value(v.id, v["remark"])
	end
end

m:append(Template(appname .. "/global/footer"))

return m
