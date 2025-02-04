extends Node

# General structure overview:

# Game calls start_traversal, initializing variables (starting session if hosting).
# if host client is registered after receiving ok from server in _process, otherwise it's done immediately
# _process later receives peer info, when peer max reached, or when ended early through finalize_peers
# start_peer_contact is called, server connection is closed
# _ping_peer loop is started, in which peers share port and readiness information
# eventually, peers agree to connect, sending connection info back to game through 'hole_punched' signal
# if connection cannot be made for any reason, 'return unsuccessful' signal is sent so game can reset UI

#Signal is emitted when holepunch is complete. Connect this signal to your network manager
#Once your network manager received the signal they can host or join a game on the host port
signal hole_punched(my_port, hosts_port, hosts_address)

#This signal is emitted when the server has acknowledged your client registration, but before the
#address and port of the other client have arrived.
signal session_registered

#Sends names of players as they join/leave
signal update_lobby(nicknames,max_players)

#Relay that connection was unsuccessful.
#The reason for failure will be stored in message.
#Setup your game to return to initial connection UI, and report fail reason for user feedback.
signal return_unsuccessful(message)

var server_udp = PacketPeerUDP.new()
var peer_udp = PacketPeerUDP.new()

#Set the rendevouz address to the IP address of your third party server
@export var rendevouz_address: String = ""
#Set the rendevouz port to the port of your third party server
@export var rendevouz_port: int = 43000
#This is the range of ports you will search if you hear no response from the first port tried
@export var port_cascade_range: int = 10
#The amount of messages of the same type you will send before cascading or giving up
@export var response_window: int = 150
#max session size
@export var MAX_PLAYER_COUNT: int = 2
#dev testing mode! this will override your peers ip with 'localhost' to test on your own machine.
@export var local_testing: bool = false

var found_server = false
var recieved_peer_info = false
var recieved_peer_greets = false
var recieved_peer_confirms = false

var is_host = false

var own_address
var own_port
var peers = {}
var peer_stages = {}
# [peer.address] = 0,1,2
	# 0 = no contact
	# 1 = received greet
	# 2 = received confirm
var host_address = ""
var host_port = 0
var client_name = ""
var nickname #appearance only
var p_timer #ping timer, for communicating with peers
var session_id

var ping_cycles = 0 #how many times peers have pinged eachother

const REGISTER_SESSION = "rs:"
const REGISTER_CLIENT = "rc:"
const CLOSE_SESSION = "cs:" #message from host client to preemptively end session
const EXCHANGE_PEERS = "ep:" #client message to exchange peer info early
const CHECKOUT_CLIENT = "cc:"
const PEER_GREET = "greet:"
const PEER_CONFIRM = "confirm:"
const HOST_GO = "go:"
const SERVER_OK = "ok:"
const SERVER_LOBBY = "lobby:" #lobby info, sends list of playernames
const SERVER_INFO = "peers:"
const SERVER_CLOSE = "close:" #message from server that you failed to connect, or got disconnected. like host closed lobby or lobby full

# get local address as ipv4
func get_local_address() -> String:
	var ip_address :String

	if OS.has_feature("windows"):
		if OS.has_environment("COMPUTERNAME"):
			ip_address =  IP.resolve_hostname(str(OS.get_environment("COMPUTERNAME")),1)
	elif OS.has_feature("x11"):
		if OS.has_environment("HOSTNAME"):
			ip_address =  IP.resolve_hostname(str(OS.get_environment("HOSTNAME")),1)
	elif OS.has_feature("OSX"):
		if OS.has_environment("HOSTNAME"):
			ip_address =  IP.resolve_hostname(str(OS.get_environment("HOSTNAME")),1)

	return ip_address

# get local addresses as ipv4 seperated by ,
func get_local_addresses() -> String:
	var ip_addresses : PackedStringArray

	if OS.has_feature("windows"):
		if OS.has_environment("COMPUTERNAME"):
			ip_addresses =  IP.resolve_hostname_addresses(str(OS.get_environment("COMPUTERNAME")),IP.Type.TYPE_IPV4)
	elif OS.has_feature("x11"):
		if OS.has_environment("HOSTNAME"):
			ip_addresses =  IP.resolve_hostname_addresses(str(OS.get_environment("HOSTNAME")),IP.Type.TYPE_IPV4)
	elif OS.has_feature("OSX"):
		if OS.has_environment("HOSTNAME"):
			ip_addresses =  IP.resolve_hostname_addresses(str(OS.get_environment("HOSTNAME")),IP.Type.TYPE_IPV4)

	return "/".join(ip_addresses)

func get_local_port():
	if peer_udp.is_bound():
		return peer_udp.get_local_port()
	return server_udp.get_local_port()

#handle incoming messages
func _process(delta):
	#handle peer messages
	if peer_udp.get_available_packet_count() > 0:
		var array_bytes = peer_udp.get_packet()
		var packet_string = array_bytes.get_string_from_ascii()
		if packet_string.begins_with(PEER_GREET):
			print("< peer greet!")
			var m = packet_string.split(":")
			_handle_greet_message(m[1], int(m[2]), m[3])
		elif packet_string.begins_with(PEER_CONFIRM):
			print("< peer confirm!")
			var m = packet_string.split(":")
			_handle_confirm_message(m[1], int(m[2]), m[3])
		elif packet_string.begins_with(HOST_GO):
			print("< host go!")
			var m = packet_string.split(":")
			_handle_go_message(m[1], int(m[2]), m[3])
		else:
			print("< unrecognized peer message!")

	#handle server messages
	if server_udp.get_available_packet_count() > 0:
		var array_bytes = server_udp.get_packet()
		var packet_string = array_bytes.get_string_from_ascii()
		print("received ",packet_string)
		if packet_string.begins_with(SERVER_LOBBY):
			var m = packet_string.split(":")
			emit_signal('update_lobby',m[1].split(","),m[2])
		if packet_string.begins_with(SERVER_CLOSE):
			var m = packet_string.split(":")
			handle_failure("Disconnected: "+m[1])
			return
		if packet_string.begins_with(SERVER_OK):
			var m = packet_string.split(":")
			own_address = m[2]
			own_port = int( m[1] )
			print("Listening on port: ",own_port)
			print("Listening on adress: ",own_address)
			emit_signal('session_registered')
			if is_host:
				if !found_server:
					_send_client_to_server() #register host to session (other peers are done in start_traversal)
			found_server=true

		if not recieved_peer_info:
			if packet_string.begins_with(SERVER_INFO):
				server_udp.close()
				packet_string = packet_string.right(-6) #after 'peers:'
				if packet_string.length() > 2:
					var clientdata = packet_string.split(",") #this is formatted client:ip:port,client2:ip:port:local_ip:local_port
					for c in clientdata:
						var m = c.split(":")
						peers[m[0]] = {"port":m[2], "address":("localhost" if local_testing else m[1]),"hosting":(m[3]=="True"),"name":m[0],"local_address":m[4],"local_port":m[5]}
					recieved_peer_info = true
					start_peer_contact()
				else:
					#apparently no peers were sent, host probably began without others.
					handle_failure("No peers found.") #report to game to handle accordingly

#receive peer info, reset their port if you had it wrong
func _handle_greet_message(peer_name, peer_port, peer_address):
	if not peer_name in peer_stages:
		peer_stages[peer_name] = 0
	if peer_stages[peer_name] == 0: peer_stages[peer_name] = 1
	peers[peer_name].port = peer_port
	# address used to reach us
	peers[peer_name].address_used = peer_address
	if peers[peer_name].hosting:
		host_port=peer_port
		host_address=peer_address

#message that a peer has received all other peer's info
func _handle_confirm_message(peer_name,peer_port, peer_address):
	_handle_greet_message(peer_name,peer_port, peer_address)
	peer_stages[peer_name] = 2

#message from host to start connection
func _handle_go_message(peer_name,peer_port, peer_address):
	peer_stages[peer_name] = 2
	if peers[peer_name].hosting:
		var peer = peers[peer_name]

		emit_signal("hole_punched", int(own_port), int(peer_port), peer_address, peers.size())
		peer_udp.close()
		p_timer.stop()
		set_process(false)

#search for working ports, send greetings accordingly
func _cascade_peer(peer_address, peer_port):
	for i in range(int(peer_port) - port_cascade_range, int(peer_port) + port_cascade_range):
		peer_udp.set_dest_address(peer_address, i)
		var buffer = PackedByteArray()
		buffer.append_array((PEER_GREET+client_name+":"+str(own_port)).to_utf8_buffer()) #tell peer about your new port
		peer_udp.put_packet(buffer)

#contact other peers, repeatedly called by p_timer, started in start_peer_contact

#structure:
#greet: telling peers what port you are listening on, making them reconfigure if they had it wrong
#confirm: telling peers that you've received *all other peer's* info, and are waiting for other peers to do the same
#go: initiated by host when all peers have confirmed, tells peers to start peer to peer connection
func _ping_peer():
	var all_info = true
	var all_confirm = true
	for p in peers.keys():
		var peer = peers[p]

		var peer_address = peer.address
		var peer_addresses = [peer_address]
		var peer_port = peer.port
		var str_own_port = str(own_port)

		# under same NAT we need to go local (maybe multiple local address)
		if peer_address == own_address:
			peer_addresses = peer.local_address.split("/")
			peer_port = peer.local_port
			str_own_port = str(get_local_port())

		if not peer.name in peer_stages:
			peer_stages[peer.name] = 0
		var stage = peer_stages[peer.name]
		if stage < 1: all_info = false
		if stage < 2: all_confirm = false
		for address in peer_addresses:
			if stage == 0: #received no contact, send greet
				if ping_cycles >= response_window:
					_cascade_peer(address,peer_port)
				else:
					print("> send greet! ",address, ":",peer_port," ",str_own_port)
					peer_udp.set_dest_address(address, int(peer_port))
					var buffer = PackedByteArray()
					buffer.append_array((PEER_GREET+client_name+":"+str_own_port+":"+address).to_utf8_buffer())
					peer_udp.put_packet(buffer)
			if stage >= 1 and recieved_peer_greets:
				print("> send confirm!",address, ":",peer_port," ",str_own_port)
				peer_udp.set_dest_address(address, int(peer_port))
				var buffer = PackedByteArray()
				buffer.append_array((PEER_CONFIRM+client_name+":"+str_own_port+":"+address).to_utf8_buffer())
				peer_udp.put_packet(buffer)
		#initiate fail if peer can't connect to you (stage 0), or hasn't connected to all other peers (stage 1)
		#in this case, all peers should have atleast one unsuccessful connection, and we will throw an error to the game
		if stage < 2 and ping_cycles >= (response_window*2):
			handle_failure("Not all peers were able to connect through peer-to-peer! If this continues, consider port-forwarding as a fallback option.")
	if all_info:
		recieved_peer_greets = true
	if all_confirm:
		recieved_peer_confirms = true
		if is_host:
			for p in peers.keys():
				var peer = peers[p]

				var peer_address = peer.address
				var peer_addresses = [peer_address]
				var peer_port = peer.port
				var str_own_port = str(own_port)

				# under same NAT we need to go local (maybe multiple local address)
				if peer_address == own_address:
					peer_addresses = peer.local_address.split("/")
					peer_port = peer.local_port
					str_own_port = str(get_local_port())

				for address in peer_addresses:
					print("> send go!")
					peer_udp.set_dest_address(address, int(peer_port))
					var buffer = PackedByteArray()
					# send address used to reach us when sending go
					buffer.append_array((HOST_GO+client_name+":"+str_own_port+":"+peer.address_used).to_utf8_buffer())
					peer_udp.put_packet(buffer)

			emit_signal("hole_punched", int(own_port), host_port, host_address, peers.size())
			peer_udp.close()
			p_timer.stop()
			set_process(false)
	ping_cycles+=1

#initiate _ping_peer loop, disconnect from server
func start_peer_contact():
	print("starting peer contact")
	server_udp.put_packet("goodbye".to_utf8_buffer()) #this might not always get called because the server_udp is already closed before this. seems to be true from testing.
	server_udp.close()
	if peer_udp.is_bound():
		peer_udp.close()
	var err = peer_udp.bind(own_port, "*")
	if err != OK:
		handle_failure("Error listening on port: " + str(own_port) +", " + str(err))
		return
	p_timer.start() #repeatedly calls _ping_peer

#this function can be called to the server if you want to end the holepunch before the server closes the session
func finalize_peers():
	var buffer = PackedByteArray()
	buffer.append_array((EXCHANGE_PEERS+str(session_id)).to_utf8_buffer())
	server_udp.set_dest_address(rendevouz_address, rendevouz_port)
	server_udp.put_packet(buffer)

#removes a client from the server
func checkout():
	var buffer = PackedByteArray()
	buffer.append_array((CHECKOUT_CLIENT+client_name).to_utf8_buffer())
	server_udp.set_dest_address(rendevouz_address, rendevouz_port)
	server_udp.put_packet(buffer)

#call this function when you want to start the holepunch process
func start_traversal(id, is_player_host, player_name, player_nickname):
	if server_udp.is_bound ():
		server_udp.close()

	var err = server_udp.bind(rendevouz_port, "*")
	if err != OK:
		handle_failure("Error listening on port: " + str(rendevouz_port) + " to server: " + rendevouz_address)
		return

	set_process(true)

	is_host = is_player_host
	client_name = player_name
	nickname = player_nickname
	found_server = false
	recieved_peer_info = false
	recieved_peer_greets = false
	recieved_peer_confirms = false
	peers = {}
	peer_stages = {}

	ping_cycles = 0
	session_id = id

	if (is_host):
		var buffer = PackedByteArray()
		buffer.append_array((REGISTER_SESSION+session_id+":"+str(MAX_PLAYER_COUNT)).to_utf8_buffer())
		server_udp.set_dest_address(rendevouz_address, rendevouz_port)
		server_udp.put_packet(buffer)
		#host gets added to session after an ok, in _process
	else:
		_send_client_to_server()

#register a client with the server
func _send_client_to_server():
	await get_tree().create_timer(2.0).timeout #resume upon timeout of 2 second timer; aka wait 2s
	var buffer = PackedByteArray()
	buffer.append_array((REGISTER_CLIENT+client_name+":"+session_id+":"+nickname+":"+get_local_addresses()+":"+str(get_local_port())).to_utf8_buffer())
	server_udp.close()
	server_udp.set_dest_address(rendevouz_address, rendevouz_port)
	server_udp.put_packet(buffer)

#close server connection on deletion
func _exit_tree():
	server_udp.close()

#reports connection failure, and stops all connections
func handle_failure(message):
	print("Holepunch unsuccessful, stopping processes! ",message)
	if is_host and server_udp.is_bound() and found_server: #shutdown session if possible
		var buffer = PackedByteArray()
		buffer.append_array((CLOSE_SESSION+str(session_id)+":"+message).to_utf8_buffer())
		server_udp.put_packet(buffer)
	else:
		checkout() #remove client from session if not
	p_timer.stop()
	server_udp.close()
	peer_udp.close()
	emit_signal("return_unsuccessful",message)

#call this from non-host client to disconnect from a session
func client_disconnect():
	handle_failure("Client disconnected.")

#call this from host client to forcefully close a session
func close_session():
	handle_failure("Host preemptively closed session!")

#initialize timer
func _ready():
	p_timer = Timer.new()
	get_node("/root/").call_deferred("add_child", p_timer)
	p_timer.connect("timeout", Callable(self, "_ping_peer"))
	p_timer.wait_time = 0.1
