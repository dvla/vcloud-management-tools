require 'awesome_print'
require 'vcloud-rest/connection'
require 'yaml'
require 'trollop'
require 'fog'

#refactor all this spaghetti at some point

#
#ENV['VCLOUD_REST_DEBUG_LEVEL'] = "DEBUG"
cmdline_args = Trollop::options do
  opt :vapp_template, "VAPP template to use", :type => :string
  opt :vapp_name, "name for the new vapp", :type => :string
  opt :vapp_description, "description of the new vapp", :type => :string
  opt :org_network, "name of the organization network", :type => :string
  opt :domain, "name of the DNS domain", :type => :string
  opt :subdomain, "name of the DNS subdomain",
    :type => :string, :required => false, :default => ''
end

cmdline_args.each do |key, value|
  Trollop::die key, "is required"  if value.nil?
end

# load up the credentials from ~/.vcloud-credentials.yaml
credentials = YAML.load_file("#{ENV['HOME']}/.credentials.yaml")
vcloud_credentials = credentials['vcloud']
dnsimple_credentials = credentials['dnsimple']
# Example yaml contents for the credentials ~/.credentials.yaml file
# ---
#vcloud:
#  host: 'https://api.vcd.portal.cloud.com'
#  user: '999.88.AA00d2'
#  password: 'whateveryoufancy,really'
#  org_name: '99-88-0-ffffff'
#  vdc_name: 'ffffffff-ffff-ffff-ffff-ffffffffffff'
#  catalog_name: 'VappCatalog'
#  api_version: '6.1'
#dnsimple:
#  username: adskjfdsaf@asdf.pt
#  password: ksadfkjsadfkj
#


#login and get your session token
vcloud = VCloudClient::Connection.new(vcloud_credentials['host'],
                                      vcloud_credentials['user'],
                                      vcloud_credentials['password'],
                                      vcloud_credentials['org_name'],
                                      vcloud_credentials['api_version'])

vcloud.login

# retrieve the list of vcloud organizations this user has access
sleep 5
orgs = vcloud.get_organizations

# retrieve all the objects within this specific organization
sleep 5
org = vcloud.get_organization(orgs[vcloud_credentials['org_name']])

# retrieve the list of networks within the organization
networks = org[:networks]

# retrieve the list of vdcs within the organization
vdcs = org[:vdcs]
ap vdcs

# retrieve catalog uuid and then the list of all vapps inside that catalog
sleep 5
catalog_uuid = vcloud.get_catalog_id_by_name(org,
                                             vcloud_credentials['catalog_name'])

# get the catalog item uuid for my VAPP template
# this is not pretty!
# the reason is that the VAPP template uuid required to deploy from template
# is not the the uuid for that catalog item.
# the item object in the catalog contains a set of children items inside it
# and we require the first :id contained in it.
#
sleep 5
vapp_template_uuid = vcloud.get_catalog_item_by_name(
  catalog_uuid,
  cmdline_args[:vapp_template],
  )[:items][0][:id]

# create a new VAPP called 'vappname1'
sleep 5
vapp = vcloud.create_vapp_from_template(
  vcloud_credentials['vdc_name'],
  cmdline_args[:vapp_name],
  cmdline_args[:vapp_description],
  vapp_template_uuid,
  false)

ap vapp

# wait until the VAPP is deployed
#vapp_info = vcloud.get_vapp(vapp[:vapp_id])
#ap vapp_info
sleep 5
vcloud.wait_task_completion(vapp[:task_id])

config =  {
  :name => cmdline_args[:org_network],
  :fence_mode => "bridged",
  :parent_network =>  {
    :id => networks[cmdline_args[:org_network]] },
  :ip_allocation_mode => "DHCP" }

network_uuid = networks[cmdline_args[:org_network]]

sleep 5
network = vcloud.get_network(network_uuid)

#reconfigure the networks for the vapp
sleep 5
vcloud.add_org_network_to_vapp(vapp[:vapp_id], network, config)


# poweron the vapp
sleep 5
poweron_taskid = vcloud.poweron_vapp(vapp[:vapp_id])
ap poweron_taskid
sleep 5
vcloud.wait_task_completion(poweron_taskid)

# find out the ip address of my new vapp
# this can take a while, so lets loop around it for a bit
sleep 5
until ip_address = vcloud.get_vapp(vapp[:vapp_id])[:ip] do
  puts "waiting for ip address information..."
  sleep 15
end
ap ip_address

# register new vapp into DNS
dnsimple = Fog::DNS.new({
  :provider     => 'DNSimple',
  :dnsimple_email => dnsimple_credentials['username'],
  :dnsimple_password => dnsimple_credentials['password']
})

sleep 1
zone = dnsimple.zones.get(cmdline_args[:domain])
ap zone

sleep 1
record = zone.records.create(
:value => ip_address,
:name => cmdline_args[:vapp_name] + '.' + cmdline_args[:subdomain],
:type => 'A'
)
ap record
