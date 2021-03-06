#
# Copyright 2011-2013, Dell
# Copyright 2013-2014, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "ipaddr"

class NeutronService < PacemakerServiceObject
  def initialize(thelogger)
    super(thelogger)
    @bc_name = "neutron"
  end

# Turn off multi proposal support till it really works and people ask for it.
  def self.allow_multiple_proposals?
    false
  end

  def self.networking_plugins_valid
    ["ml2", "vmware"]
  end

  def self.networking_ml2_type_drivers_valid
    ["vlan", "gre", "vxlan"]
  end

  def self.networking_ml2_mechanism_drivers_valid
    ["linuxbridge", "openvswitch", "cisco_nexus"]
  end

  class << self
    def role_constraints
      {
        "neutron-server" => {
          "unique" => false,
          "count" => 1,
          "exclude_platform" => {
            "windows" => "/.*/"
          },
          "cluster" => true
        },
        "neutron-network" => {
          "unique" => false,
          "count" => 1,
          "admin" => false,
          "exclude_platform" => {
            "windows" => "/.*/"
          },
          "cluster" => true
        }
      }
    end
  end

  def proposal_dependencies(role)
    answer = []
    answer << { "barclamp" => "database", "inst" => role.default_attributes["neutron"]["database_instance"] }
    answer << { "barclamp" => "rabbitmq", "inst" => role.default_attributes["neutron"]["rabbitmq_instance"] }
    answer << { "barclamp" => "keystone", "inst" => role.default_attributes["neutron"]["keystone_instance"] }
    answer
  end

  def create_proposal
    base = super

    nodes = NodeObject.all
    nodes.delete_if { |n| n.nil? or n.admin? }

    base["attributes"][@bc_name]["database_instance"] = find_dep_proposal("database")
    base["attributes"][@bc_name]["rabbitmq_instance"] = find_dep_proposal("rabbitmq")
    base["attributes"][@bc_name]["keystone_instance"] = find_dep_proposal("keystone")

    controller_nodes = nodes.select { |n| n.intended_role == "controller" }
    controller_node = controller_nodes.first
    controller_node ||= nodes.first

    network_nodes = nodes.select { |n| n.intended_role == "network" }
    network_nodes = [controller_node] if network_nodes.empty?

    base["deployment"]["neutron"]["elements"] = {
        "neutron-server" => [controller_node[:fqdn]],
        "neutron-network" => network_nodes.map { |x| x[:fqdn] }
    } unless nodes.nil? or nodes.length ==0

    base["attributes"]["neutron"]["service_password"] = random_password
    base["attributes"][@bc_name][:db][:password] = random_password

    base
  end

  def validate_gre gre_settings
    if gre_settings["tunnel_id_start"] < 1 || gre_settings["tunnel_id_start"] > 2147483647
      validation_error("Start of GRE tunnel ID range must be between 0 and 2147483647")
    end
    if gre_settings["tunnel_id_end"]  < 1 || gre_settings["tunnel_id_end"] > 2147483647
      validation_error("End of GRE tunnel ID range must be between 0 and 2147483647")
    end
    if gre_settings["tunnel_id_start"] > gre_settings["tunnel_id_end"]
      validation_error("End of GRE tunnel ID range must be higher than start of GRE tunnel ID range")
    elsif gre_settings["tunnel_id_start"] == gre_settings["tunnel_id_end"]
      validation_error("GRE tunnel ID range is too small")
    elsif gre_settings["tunnel_id_end"] + 1 - gre_settings["tunnel_id_start"] > 1000000
      # test being done in neutron for unreasonable ranges
      validation_error("GRE tunnel ID range is unreasonable for neutron")
    end
  end

  def validate_vxlan vxlan_settings
    if vxlan_settings["vni_start"] < 0 || vxlan_settings["vni_start"] > 16777215
      validation_error("Start of VXLAN VNI range must be between 0 and 16777215")
    end
    if vxlan_settings["vni_end"]  < 0 || vxlan_settings["vni_end"] > 16777215
      validation_error("End of VXLAN VNI range must be between 0 and 16777215")
    end
    if vxlan_settings["vni_start"] > vxlan_settings["vni_end"]
      validation_error("End of VXLAN VNI range must be higher than start of VXLAN VNI range")
    elsif vxlan_settings["vni_start"] == vxlan_settings["vni_end"]
      validation_error("VXLAN VNI range is too small")
    end

    mcast_group = vxlan_settings["multicast_group"]
    unless mcast_group.empty?
      begin
        IPAddr.new(mcast_group)
      rescue ArgumentError
        validation_error("Multicast group for VXLAN broadcast emulation #{mcast_group} is not a valid IP address")
      end
      mcast_first = mcast_group.split(".")[0].to_i
      if mcast_first < 224 || mcast_first > 239
        validation_error("Multicast group for VXLAN broadcast emulation #{mcast_group} is not a valid multicast IP address")
      end
    end
  end

  def validate_external_networks external_networks
    net_svc = NetworkService.new @logger
    network_proposal = Proposal.where(barclamp: net_svc.bc_name, name: "default").first
    blacklist = ["bmc", "bmc_admin", "admin", "nova_fixed", "nova_floating",
                 "os_sdn", "public", "storage"]

    external_networks.each do |ext_net|
      # Exclude a few default networks from network.json from being used as
      # additional external networks in neutron
      if blacklist.include? ext_net
        validation_error("Network '#{ext_net}' cannot be used as an additional external network")
      end
      if network_proposal["attributes"]["network"]["networks"][ext_net].nil?
        validation_error("External Network '#{ext_net}' is not defined in the configuration of the network barclamp")
      end
    end
  end

  def validate_proposal_after_save proposal
    validate_one_for_role proposal, "neutron-server"
    validate_at_least_n_for_role proposal, "neutron-network", 1

    plugin = proposal["attributes"]["neutron"]["networking_plugin"]
    ml2_mechanism_drivers = proposal["attributes"]["neutron"]["ml2_mechanism_drivers"]
    ml2_type_drivers = proposal["attributes"]["neutron"]["ml2_type_drivers"]
    ml2_type_drivers_default_provider_network = proposal["attributes"]["neutron"]["ml2_type_drivers_default_provider_network"]
    ml2_type_drivers_default_tenant_network = proposal["attributes"]["neutron"]["ml2_type_drivers_default_tenant_network"]

    ml2_type_drivers_valid = NeutronService.networking_ml2_type_drivers_valid
    ml2_mechanism_drivers_valid = NeutronService.networking_ml2_mechanism_drivers_valid

    # at least one ml2 type driver must be selected for ml2 as core plugin
    if plugin == "ml2" && ml2_type_drivers.length == 0
      validation_error("At least one ml2 type driver must be selected")
    end

    # at least one ml2 mech driver must be selected for ml2 as core plugin
    if plugin == "ml2" && ml2_mechanism_drivers.length == 0
      validation_error("At least one ml2 mechanism driver must be selected")
    end

    # only allow valid ml2 type drivers
    ml2_type_drivers.each do |drv|
      unless ml2_type_drivers_valid.include? drv
        validation_error("Selected ml2 type driver \"#{drv}\" is not a valid option. Valid drivers are #{ml2_type_drivers_valid.join(',')}")
      end
    end

    # only allow valid ml2 mechanism drivers
    ml2_mechanism_drivers.each do |drv|
      unless ml2_mechanism_drivers_valid.include? drv
        validation_error("Selected ml2 mechansim driver \"#{drv}\" is not a valid option. Valid drivers are #{ml2_mechanism_drivers_valid.join(',')}")
      end
    end

    # default provider network ml2 type driver must be a driver from the selected ml2 type drivers
    # TODO(toabctl): select the ml2_type_driver automatically if used as default? Or directly check in the ui via js?
    unless ml2_type_drivers.include?(ml2_type_drivers_default_provider_network)
      validation_error("The default provider network type driver \"#{ml2_type_drivers_default_provider_network}\" is not a selected ml2 type driver")
    end

    # default tenant network ml2 type driver must be a driver from the selected ml2 type drivers
    # TODO(toabctl): select the ml2_type_driver automatically if used as default? Or directly check in the ui via js?
    unless ml2_type_drivers.include?(ml2_type_drivers_default_tenant_network)
      validation_error("The default tenant network type driver \"#{ml2_type_drivers_default_tenant_network}\" is not a selected ml2 type driver")
    end

    if ml2_type_drivers.include? "gre"
      validate_gre proposal["attributes"]["neutron"]["gre"]
    end

    if ml2_type_drivers.include? "vxlan"
      validate_vxlan proposal["attributes"]["neutron"]["vxlan"]
    end

    # linuxbridge and cisco_nexus mech drivers need vlan type driver
    # TODO(toabctl): select vlan type driver automatically if linuxbridge or cisco were selected!?
    %w(linuxbridge cisco_nexus).each do |drv|
      if ml2_mechanism_drivers.include? drv and not ml2_type_drivers.include? "vlan"
        validation_error("The mechanism driver \"#{drv}\" needs the type driver \"vlan\"")
      end
    end

    # cisco_nexus mech driver needs also openvswitch mech driver
    if ml2_mechanism_drivers.include? "cisco_nexus" and not ml2_mechanism_drivers.include? "openvswitch"
      validation_error("The 'cisco_nexus' mechanism driver needs also the 'openvswitch' mechanism driver")
    end

    # for now, openvswitch and linuxbrige can't be used in parallel
    if ml2_mechanism_drivers.include? "openvswitch" and ml2_mechanism_drivers.include? "linuxbridge"
      validation_error("The 'openvswitch' and 'linuxbridge' mechanism drivers can't be used in parallel. Only select one of them")
    end

    if proposal["attributes"]["neutron"]["use_l2pop"]
      unless ml2_type_drivers.include?("gre") || ml2_type_drivers.include?("vxlan")
        validation_error("L2 population requires GRE and/or VXLAN")
      end
    end

    if proposal["attributes"]["neutron"]["use_dvr"]
      if !ml2_mechanism_drivers.include?("openvswitch") ||
         (!ml2_type_drivers.include?("gre") && !ml2_type_drivers.include?("vxlan"))
        validation_error("DVR can only be used with openvswitch and gre/vxlan")
      end

      if !proposal["attributes"]["neutron"]["use_l2pop"]
        validation_error("DVR requires L2 population")
      end

      unless proposal["deployment"]["neutron"]["elements"].fetch("neutron-network", []).empty?
        network_node = proposal["deployment"]["neutron"]["elements"]["neutron-network"][0]
        if is_cluster? network_node
          validation_error("DVR is not compatible with High Availability for neutron-network")
        end
      end
    end

    unless proposal["attributes"]["neutron"]["additional_external_networks"].empty?
      validate_external_networks proposal["attributes"]["neutron"]["additional_external_networks"]
    end

    super
  end

  def update_ovs_bridge_attributes(attributes, node)
    needs_save = false
    ovs_bridge_networks = []
    if attributes["networking_plugin"] == "ml2"
      ml2_type_drivers = attributes["ml2_type_drivers"]
      if attributes["ml2_mechanism_drivers"].include?("openvswitch")
        # We need to create ovs bridges for floating and (when vlan type driver
        # is enabled) nova_fixed.  Adjust the network attribute accordingly.
        # We only do that on the node attributes and not the proposal itself as
        # the requirement to have the bridge setup is really node-specifc. (E.g.
        # a tempest node that might get an IP allocated in "nova_floating" won't
        # need the bridges)
        ovs_bridge_networks = ["nova_floating"]
        ovs_bridge_networks.concat attributes["additional_external_networks"]
        if ml2_type_drivers.include?("vlan")
          ovs_bridge_networks << "nova_fixed"
        end
        ovs_bridge_networks.each do |net|
          if node.crowbar["crowbar"]["network"][net]
            unless node.crowbar["crowbar"]["network"][net]["add_ovs_bridge"]
              @logger.info("Forcing add_ovs_bridge to true for the #{net} network on node #{node.name}")
              node.crowbar["crowbar"]["network"][net]["add_ovs_bridge"] = true
              needs_save = true
            end
          end
        end
      end
    end
    # Cleanup the add_ovs_bridge bridge flag on all other networks.
    node.crowbar["crowbar"]["network"].keys.each do |net|
      unless ovs_bridge_networks.include?(net)
        if node.crowbar["crowbar"]["network"][net]["add_ovs_bridge"]
          @logger.info("Forcing add_ovs_bridge to false for the #{net} network on node #{node.name}")
          node.crowbar["crowbar"]["network"][net]["add_ovs_bridge"] = false
          needs_save = true
        end
      end
    end
    node.save if needs_save
  end

  def enable_neutron_networks(attributes, nodename, net_svc, needs_external = true)
    if needs_external
      net_svc.enable_interface "default", "nova_floating", nodename
      attributes["additional_external_networks"].each do |extnet|
        net_svc.enable_interface "default", extnet, nodename
      end
    end

    if attributes["networking_plugin"] == "ml2"
      ml2_type_drivers = attributes["ml2_type_drivers"]
      if ml2_type_drivers.include?("gre") || ml2_type_drivers.include?("vxlan")
        net_svc.allocate_ip "default", "os_sdn", "host", nodename
      end
      if ml2_type_drivers.include?("vlan")
        net_svc.enable_interface "default", "nova_fixed", nodename
        # reload node as the above enable_interface call might have changed it
        node = NodeObject.find_node_by_name nodename
        # Force "use_vlan" to false in VLAN mode (linuxbridge and ovs). We
        # need to make sure that the network recipe does NOT create the
        # VLAN interfaces (ethX.VLAN)
        if node.crowbar["crowbar"]["network"]["nova_fixed"]["use_vlan"]
          @logger.info("Forcing use_vlan to false for the nova_fixed network on node #{nodename}")
          node.crowbar["crowbar"]["network"]["nova_fixed"]["use_vlan"] = false
          node.save
        end
      end
    elsif attributes["networking_plugin"] == "vmware"
      net_svc.allocate_ip "default", "os_sdn", "host", node
    end
    node = NodeObject.find_node_by_name nodename
    update_ovs_bridge_attributes(attributes, node)
  end

  def apply_role_pre_chef_call(old_role, role, all_nodes)
    @logger.debug("Neutron apply_role_pre_chef_call: entering #{all_nodes.inspect}")
    return if all_nodes.empty?

    net_svc = NetworkService.new @logger
    network_proposal = Proposal.where(barclamp: net_svc.bc_name, name: "default").first
    if network_proposal["attributes"]["network"]["networks"]["os_sdn"].nil?
      raise I18n.t("barclamp.neutron.deploy.missing_os_sdn_network")
    end

    server_elements, server_nodes, server_ha_enabled = role_expand_elements(role, "neutron-server")
    network_elements, network_nodes, network_ha_enabled = role_expand_elements(role, "neutron-network")

    vip_networks = ["admin", "public"]

    dirty = false
    dirty = prepare_role_for_ha_with_haproxy(role, ["neutron", "ha", "server", "enabled"], server_ha_enabled, server_elements, vip_networks)
    dirty = prepare_role_for_ha(role, ["neutron", "ha", "network", "enabled"], network_ha_enabled) || dirty
    role.save if dirty

    # All nodes must have a public IP, even if part of a cluster; otherwise
    # the VIP can't be moved to the nodes
    server_nodes.each do |n|
      net_svc.allocate_ip "default", "public", "host", n
    end

    allocate_virtual_ips_for_any_cluster_in_networks_and_sync_dns(server_elements, vip_networks)

    network_nodes.each do |n|
      enable_neutron_networks(role.default_attributes["neutron"], n, net_svc)
    end
    @logger.debug("Neutron apply_role_pre_chef_call: leaving")
  end
end
