# Layer-2 VPN  (`program.l2vpn.l2vpn`)

## <a name="overview">Overview</a>

### General Architecture

The program `program.l2vpn.l2vpn` implements a virtual multi-port
Ethernet switch on top of a plain IPv6 packet-switched network based
on the architecture laid out in RFC 4664.  From a customer
perspective, the service consists of a set of physical ports attached
to the provider's network at arbitrary locations with the semantics of
a simple Ethernet switch, a.k.a. _learning bridge_.  Each such port is
called an _attachment circuit_ (AC).

<a name="overview_MAC_learning"></a>Conceptually, the processing of an
Ethernet frame entering the virtual switch through any of the ACs
proceeds as follows.  First, the switch extracts the MAC source
address and adds it to the list of addresses reachable through the
ingress AC port.  This list is called the _MAC destination address
table_, or _MAC table_ for short.  Next, the switch extracts the MAC
destination address and forwards the frame according to the following
rules unless the address is a multicast address:

   * If the destination address is not found in any of the MAC tables,
     the frame is forwarded to all ACs except the one on which it was
     received

   * If the destination address is found in in one of the MAC tables,
     it is forwarded out of the corresponding port only

If the destination address is a multicast address, the frame is
forwarded to all egress ports except the one on which it was received.

Because the virtual switch is composed of distinct physical devices,
only the MAC tables of local ACs are directly accessible.  Therefore,
a mechanism is needed that provides discovery of the remote device to
which the destination is connected and a method to transfer the
Ethernet frame to that device.

The service is implemented by connecting the set of _provider edge_
devices (PE) that host the attachment circuits by tunnels which
transport the Ethernet frames within IPv6 packets using an appropriate
encapsulation mechanism called the _tunneling protocol_.  Each such
tunnel is called a _pseudowire_ (PW) and contains exactly two
endpoints.  Conceptually, each PE implements its own learning bridge
to which all local attachment circuits and pseudowires are connected.
The bridge maintains MAC tables for all of those ports.  In general,
the resulting topology contains loops and a mechanism is needed that
prevents packets from entering any such loop, such as the _spanning
tree protocol_ (SPT).  This implementation uses a full mesh of PWs
together with _split horizon_ forwarding to avoid loops without the
need for SPT.  In this model, each PE maintains a PW to every other PE
with the rule that a frame received on any PW is never forwarded to
any other PW.  The trade-off with respect to SPT is that the number of
PWs in the system scales quadratically with the number of PE devices.

The following figure illustrates the model with a setup that contains
four PEs, six ACs and six PWs.

![L2VPN_ARCH](.images/L2VPN_ARCH.png)
With the nomenclature from RFC 4664, a setup with exactly two ACs is
called a _virtual private wire service_ (VPWS).  It is essentially a
virtual Ethernet cable.  This is also referred to as a point-to-point
L2 VPN.

A setup with more than two ACs (and, in general, more than two PEs) is
called _virtual private LAN service_ (VPLS).  This is also referred to
as a multi-point L2 VPN.  A VPWS is a degenerate case of a VPLS.
            
The current implementation ignores everything but the source and
destination MAC addresses of frames entering the system through any of
the ACs.  Hence, it is completely transparent for any kind of payload
(i.e. Ethertype).  In particular, VLAN tags according to IEEE 802.1q
are ignored (passed on like untagged frames).  Such a system is
sometimes referred to as a _port-based_ VPLS, because all frames
entering a port are mapped to the same VPLS. A _VLAN-based_ VPLS, in
which the outermost VLAN tag is used to map the frame to one of a set
of VPLS instances attached to the same AC, is not yet supported.

### VPN Termination Point

In the present implementation, the role of the PE is played by one or
more instances of the `program.l2vpn.l2vpn` module.  Each instance is
called a _VPN termination point_ (VPNTP), which connects any number of
ACs with exactly one physical port which is connected to the
provider's network, called the _upstream_ port.  A VPNTP can contain
any number of VPLS instances, each of which is comprised of the
following elements

   * A set of pseudowire endpoints, one for each remote PE which is
     part of the same VPLS

   * The set of attachment circuits which belong to the VPLS (there
     can be more than one local AC per VPLS, but the customer is
     responsible for loop-prevention if these ACs are connected to a
     another switch)

   * A learning bridge which connects all PWs and ACs of the VPLS
     instance.  The bridge implements MAC learning and split-horizon
     forwarding for the group of PWs

Each VPLS is uniquely identified by the IPv6 address shared by all its
local PW endpoints.  Ethernet frames entering the VPNTP through an AC
are switched to one of the PWs by the bridge of the respective VPLS
instance according to the rules laid out above.  The PW encapsulates
the frame in an IPv6 packet, where the source IPv6 address is the
local VPLS identifier and the destination address is the identifier of
the VPLS instance on the remote PE, which is part of the static PW
configuration.  The IPv6 header is responsible for delivering the
packet to the appropriate egress PE, while an additional header
specific to the tunnel protocol is used to identify the payload as an
Ethernet frame.

The tunnel protocol is a property of a PW (and, consequently, each end
of a PW must be configured to use the same protocol).  However, it is
possible to mix PWs with different tunnel protocols in the same VPLS.
The supported tunnel protocols are listed in the next section.

The final packet, containing the IPv6 header, tunnel header and
original Ethernet frame is injected into the provider's network
through the uplink interface.

Each PW is uniquely identified by the source and destination addresses
of its IPv6 header.  When an IPv6 packet enters the VPNTP through the
uplink, those addresses are used to forward the packet to the
appropriate pseudowire module by a component called the _dispatcher_.
The PW module strips the IPv6 header from the packet, performs any
protocol-specific processing (apart from stripping the tunnel header
itself) and hands the original Ethernet frame to the bridge module for
forwarding to the appropriate AC.

The entire architecture is shown in the following figure.

![VPN-TP](.images/VPN-TP.png)

### <a name="tunnel_protos">Tunneling protocols</a>

The following tunneling protocols are supported.

#### GRE

The GRE protocol version 0 is supported according to RFCs 1701, 2784
and 2890 with the restriction that only the `checksum` and `key`
extensions are available.  The 2-byte protocol identifier carried in
every GRE header is set to the value `0x6558` assigned to "Transparent
Ethernet Bridging" (see the [IEEE Ethertype
assignments](http://standards-oui.ieee.org/ethertype/eth.txt))

If the `key` extension is enabled, the 32-bit value is set to the _VC
label_ assigned to the VPLS to which the PW belongs (TODO: discuss VC
label).

If the `checksum` extension is enabled, the checksum over the GRE
header and original Ethernet frame is included in the tunnel header
for integrity checking at the tunnel egress.  Note: this will impact
performance (TODO: add estimate of overhead).

#### <a name="tunnel_keyed_ipv6">Keyed IPv6 Tunnel</a>

The keyed IPv6 tunnel is a stripped down version of the L2TPv3
protocol as specified by the Internet Draft
[`draft-ietf-l2tpext-keyed-ipv6-tunnel`](https://tools.ietf.org/html/draft-ietf-l2tpext-keyed-ipv6-tunnel)

The protocol is only defined for transport over IPv6 and does not make
use of the regular L2TPv3 control channel.  The header contains only
two fields:

   * A 32-bit _session ID_

   * A 64-bit _cookie_

Since the pseudowire associated with a tunnel is already uniquely
identified by the IPv6 addresses of the endpoints, the session ID is
not actually needed to assign a packet to a particular VPLS instance.
The draft recommends setting the session ID to the value `0xffffffff`.
It can still be set to an arbitrary value (except for `0x0`, which is
reserved for the control channel in the generic L2TPv3 protocol) to
inter-operate with implementations that do make use of the value.  The
session ID is unidirectional, i.e. each endpoint may chose a value
independently.

The cookie is used to protect against spoofing and brute-force blind
insertion attacks.  Each endpoint is configured with a _remote
cookie_, which is put into outgoing packets and a _local cookie_ which
is compared to the cookie received in incoming packets.  A cookie
should be chosen at random and the local and remote cookies should be
chosen independently.

Note that the specification implies that the payload must consist of
an Ethernet frame, since the tunnel header does not contain any
information about the payload (like the protocol field of GRE).

### Uplink Interface

#### Addressing

According to the architecture laid out above, the uplink interface is
connected to a regular IPv6-enabled interface on an adjacent router.
Even though the Snabb Switch system does currently not have a notion
of a traditional IP interface, the VPNTP emulates one through the use
of the `apps.ipv6.nd_light` module, which implements just enough
functionality to make IPv6 neighbor discovery work in both directions
with an implied subnet mask of /64.  The VPNTP must be configured with
the local IPv6 address as well as the MAC address to which it needs to
be resolved.

#### Routing

Only static routing is supported on the uplink interface by
configuring the next-hop address used for all outgoing packets.  This
address must be resolvable to a MAC address through regular IPv6
neighbor discovery by the adjacent router.  There currently is no
concept of a routing table in the Snabb architecture, but this
mechanism is essentially equivalent to a static default route.

For the tunnels to work, all local IPv6 endpoint addresses need to be
reachable by the remote sides of the pseudowires.  How this is
achieved is outside the scope of the Snabb system.  There are
basically two methods.

   * The adjacent router configures static routes for each IPv6
     address that terminates a VPLS and re-distributes the routes
     within the routing domains in which the remote endpoints are
     located.

   * The host running the VPNTP announces the local endpoint addresses
     with the next-hop address of the local uplink interface address
     to the provider's routing system with BGP, from where it needs to
     be re-distributed in such a manner that the addresses are
     reachable by the remote endpoints.

The second method requires IP connectivity between the host and a
suitable BGP-speaking router in the network over a regular (non-Snabb
controlled) interface.  Two typical scenarios for this method are the
following.

   * The VPNTP host is configured with a private AS number and
     maintains a BGP session to one or more routers in its vicinity
     (e.g. the adjacent router itself).  These routers must
     re-distribute the advertised prefixes as appropriate.

   * If the provider uses an internal BGP (iBGP) setup with
     route-reflectors, the VPNTP host can be configured directly as
     route-reflector client within the provider's autonomous system.

### Signalling and Monitoring

#### <a name="control-channel">Pseudowire Control-Channel</a>

The pseudowire module (`program.l2vpn.pseudowire`) implements an
in-band _control channel_ (CC), which provides two types of services:

   1. Parameter advertisement. One end of the PW can advertise local
   parameters to its peer, either for informational purposes or to
   detect misconfigurations.

   2. Connection verification. Unidirectional connectivity is
   verified by sending periodic heartbeat messages.  A monitoring
   station that polls both endpoints can determine the full
   connectivity status of the PW (see below for details).

This proprietary protocol performs a subset of functions that are
provided by distinct protocols in standardised PW implementations
based on MPLS or L2TPv3.  Both of these provide a
"maintenance/signalling protocol" used to signal and set up a PW.
For MPLS, this role is played by LDP (in "targeted" mode).  For
L2TPv3, it is provided by a control-channel which is part of L2TPv3
itself (unless static configuration is used).

The connection verification is provided by another separate protocol
called VCCV (RFC5085).  VCCV requires a signalling protocol to be used
in order to negotiate the "CC" (control channel) and "CV" (connection
verification) modes to be used by the peers.  Currently, VCCV is only
specified for MPLS/LDP and L2TPv3, i.e. it is not possible to
implement it for any of the currently available tunneling protocols
(it is not specified for GRE and the keyed IPv6 tunnel does not make
use of the L2TPv3 control channel).

The simple control-channel protocol provided here uses a TLV encoding
to transmit information from one peer to the other.  The data is
carried in-band, i.e. in packets that use the same encapsulation as
the data traffic, which has the advantage of _fate sharing_: if the
data-plane breaks, the control-channel is disrupted as well and the
failure is detected automatically.

A protocol-dependent mechanism must be used to differentiate control
traffic from data traffic.  This implementation reserves the value
`0xFFFFFFFE` for the GRE `key` and L2TPv3 session ID for this purpose.

The following items are supported by the control-channel.

   * `heartbeat`: an unsigned 16-bit number that specifies the
     interval in seconds at which the sender emits control frames.  It
     is used by the receiver to determine whether it is reachable by
     the peer.

   * `mtu`: The MTU of the attachment circuit (or virtual bridge port
     in case of a multi-point VPN) of the sender.  The receiver
     verifies that it matches its own MTU and marks the PW as
     non-functional if this is not the case.  The MTU is carried as an
     unsigned 16-bit number in the TLV.

   * `if_description`: Interface description (TODO)

   * `vc_id`:

The dead-peer detection proceeds as follows.  The local endpoint
records the heartbeat interval advertised by the remote end over the
control channel.  The peer is declared dead if no control message is
received for a locally configured multiple of that interval.  This
multiplication factor is called the _dead factor_.

For example, if the remote peer advertises a heartbeat of 20 seconds
and the local peer uses a value of 3 for its dead factor, the
pseudowire is declared to be down 3x20 = 60 seconds after the last
control message has been received.  This notion of unreachability is
obviously unidirectional (i.e. packets from the remote end do not
reach the local end of the pseudowire).  To determine the
bi-directional status of the PW, the reachability status of both
endpoints must be obtained by the operator.

#### Monitoring via SNMP

The L2VPN framework supports various SNMP MIBs for monitoring:

   * `interfaces` (.1.3.6.1.2.1.2)
   * `ifMIB` (.1.3.6.1.2.1.31)
      * `ifXTable` (.1.3.6.1.2.1.31.1.1)
   * `cpwVcMIB` (.1.3.6.1.4.1.9.10.106)
      * `cpwVcObjects` (.1.3.6.1.4.1.9.10.106.1)
         * `cpwVcTable` (.1.3.6.1.4.1.9.10.106.1.2)
   * `pwStdMIB` (.1.3.6.1.2.1.10.246): partial support
      * `pwObjects` (.1.3.6.1.2.1.10.246.1)
         * `pwTable` (.1.3.6.1.2.1.10.246.1.2)
   * `cpwVcEnetMIB` (.1.3.6.1.4.1.9.10.108)
     * `cpwVcEnetObjects` (.1.3.6.1.4.1.9.10.108.1)
        * `cpwVcEnetTable` (.1.3.6.1.4.1.9.10.108.1.1)
   * `pwEnetStdMIB` (1.3.6.1.2.1.180)
      * `pwEnetObjects` (1.3.6.1.2.1.180.1)
         * `pwEnetTable` (1.3.6.1.2.1.180.1.1)

The `pw*` MIBs are part of the IETF reference architecture known as
_Pseudo Wire Emulation Edge-to-Edge_ (PWE3, [RFC
3985](https://www.ietf.org/rfc/rfc3985.txt "RFC 3985")).  As usual,
vendors have implemented various pre-standard (draft) versions of
these MIBs during the lengthy standardisation process.  Some of them
still use those versions and didn't even bother to support the
standardised version at all, like Cisco.  The `cpw*` MIBs are used on
most Cisco devices and are almost but not quite identical to their
`pw*` counterparts.

The L2VPN program does not provide an actual SNMP engine itself.
Instead, it stores the raw objects in a shared memory segment and
relies on an external program to make them available with SNMP.  A
[perl-based
program](https://github.com/alexandergall/snabb-snmp-subagent.git) is
available, which parses this data and can hook into any SNMP agent
that supports the AgentX protocol, like
[Net-SNMP](http://www.net-snmp.org/).

## Configuration

The `program.l2vpn.l2vpn` expects a configuration file containing a
Lua expression which returns a table that contains the complete
configuration of the VPNTP that is to be instantiated.  The generic
form of this expression is as follows:

```
return {
  uplink = <uplink_config>,
  vpls = {
    <vpls1> = <vpls_config>,
    <vpls2> = <vpls_config>,
    .
    .
    .
}
```

Here, `<uplink_config>` and `<vpls_config>` are Lua tables as
described below and the keys of the `vpls` table (`<vpls1>`,
`<vpls2>`, etc.) represent the names of the VPLS instances contained
in the VPNTP.

### <a name="uplink_configuration">Uplink configuration</a>

The uplink of the VPNTP is specified as a Lua table with the following
contents.

```
uplink = {
  driver = <driver>,
  config = {
    pciaddr = <pci_address>,
    mtu = <mtu>,
    -- Optional
    snmp = {
      directory = <shmem_directory>
    }
  },
  address = <ipv6_address>,
  mac = <mac_address>,
  neighbor_mac = <neighbor_mac>, -- Optional
  neighbor_nd = <true | false>,  -- Optional
  next_hop = <ipv6_address>
}
```

`<driver>` is a Lua module that provides a driver for the device
associated with the PCI address `uplink.config.pciaddr`, for example

```
driver = require("apps.intel.intel_app").Intel82599
```

The table `config` represents the configuration for the driver with
the following keys

   * `pciaddr`: a string that contains the complete PCI address of the
     network device which is to be used as upstream interface of the
     VPNTP, for example `"0000:04:00.1"`.

   * `mtu`: <a name="uplink_MTU"></a> the MTU in bytes of the device
     including the Ethernet header (but neither the CRC, SOF nor
     preamble).  For example, to support 1500-byte IP packets without
     VLAN tags, the MTU needs to be set to 1514 to account for the 14
     bytes used by the Ethernet header.  If tagging according to
     802.1q is used, an additional 4 bytes need to be added for every
     level of tagging.

   * `snmp`: a table with a single key `directory`, which specifies
     the directory through which the shared memory segments containing
     the SNMP objects of all supported MIBs can be accessed.  The
     `snmp` key is optional.  If it is absent, SNMP will be disabled
     in the VPNTP. TODO: refer to description of SNMP subagents.

The remaining keys of the `uplink` table are as follows.

   * `address`: the IPv6 address of the uplink interface in any of the
     standard notations for IPv6 addresses.  A netmask of /64 is
     implied.  For example `address = "2001:db8:0:1::2"` would assign
     the subnet `2001:db8:0:1::/64` to the interface and set the local
     address to `2001:db8:0:1::2`.  If `neighbor_mac` is not
     specified, the VPNTP instantiates the Snabb app
     `apps.ipv6.nd_light` to provide minimalistic IPv6 neighbor
     discovery.  This module will respond to incoming neighbor
     solicitations for `address` with a neighbor advertisement
     including the MAC address `mac`.  It will also perform address
     resolution for `next_hop` by sending out neighbor solicitations
     for that address.

   * `mac`: the MAC address assigned to the interface in the standard
     notation, for example `mac = "01:23:45:67:89:ab"`.  Note that
     this address must correspond to the native MAC address of the
     interface.  It cannot be used to set the MAC address to an
     arbitrary value.  As such, it should actually be determined
     automatically from the device itself, but the current Snabb
     drivers do not make this available.

   * `neighbor_mac`: optional MAC address of the router connected to
     the uplink.  If this key is present, the VPNTP will not perform
     dynamic neighbor discovery for `next_hop`.

   * `neighbor_nd`: this key is ignored unless `neighbor_mac` is set.
     In that case, it can be set to either `true` or `false` (defaults
     to `false`).  If set to `true`, the VPNTP will respond to IPv6
     neighbor solicitations for the address configured with `address`,
     thus enabling dynamic address resolution for the adjacent router
     through the app `apps.ipv6.ns_responder`.  If set to `false`, the
     VPNTP will not respond to any kind of neighbor discovery.  In
     that case, the adjacent router must use a statically configured
     neighbor cache entry for `address`.

   * `next_hop`: the IPv6 address of the remote end of the uplink
     interface. It is effectively used as a static default route to
     send out encapsulated Ethernet frames received on local ACs.  It
     must be possible to resolve this address to a MAC address through
     IPv6 neighbor discovery unless `neighbor_mac` is set, in which
     case the MAC destination address of all outgoing Ethernet frames
     will be set to that value.

### VPLS instance configuration

The `vpls` table in the VPNTP configuration table contains one entry
for each VPLS that will be part of the VPNTP.  The keys of the table
provide the names of those VPLS instances, hence the fragment

```
return {
  upink = { ... },
  vpls = {
    foo = <vpls_config>,
    bar = <vpls_config>,
  }
}
```

will create two VPLS instances named `foo` and `bar`.  Each VPLS
configuration `<vpls_config>` is a table of the following form.

```
<vpls_name> = {
  description = <description>,
  mtu = <mtu>,
  vc_id = <vc_id>,
  bridge = <bridge_config>,
  ac = {
    <ac_1> = <ac_config>,
    <ac_2> = <ac_config>,
    .
    .
    .
  },
  address = <VPLS_address>,
  tunnel = <tunnel_config>,
  cc = <cc_config>,
  shmem_dir = <shmem_dir>,
  pw = {
    <pw_1> = <pw_config>,
    <pw_2> = <pw_config>,
    .
    .
    .
  }
}
```

The keys define the properties of the VPLS instance.

   * `description` (TODO)

   * `mtu`: the MTU in bytes of all ACs connected to the VPLS instance
     including the Ethernet header (but neither the CRC, SOF nor
     preamble, also see [the definition of the uplink
     MTU](#uplink_MTU)).  As with any Ethernet bridge (and IP subnet),
     it is mandatory that all interfaces connected to it use the same
     MTU, i.e. it is a property of the VPLS.  To avoid
     misconfigurations, it is configured once and propagated to the
     configurations of the AC interfaces automatically.  It is also
     communicated to the remote endpoints of all pseudowires through
     the control channel to make the MTU coherent across the entire
     virtual switch.

   *  `vc_id`: (TODO)

   * `bridge`: if the VPLS contains more than one pseudowire or
     connects more than one AC at any location, a bridge is needed to
     perform forwarding of Ethernet frames.  The `bridge` key selects
     the type of switch and its properties.  Its value is a Lua table:

 ```
  bridge = {
    type = "learning" | "flooding",
    -- learning configuration
    config = {
      mac_table = {
        timeout = <MAC_timeout>
      }
    }
  }
 ```
 If omitted, the default configuration
 ```
 bridge = { type = "flooding" }
 ```
 is used.
        
  If `type` is set to `"flooding"`, the bridge will send copies of all
  Ethernet frames received on any port to all other ports, i.e. every
  frame will be flooded across the entire VPLS.  Any other key in the
  table is ignored.

  If `type` is set to `"learning"`, the bridge performs MAC learning
  as described in the [overview](#overview_MAC_learning).  The table
  `config` sets the properties of the bridge. It contains a single key
  `mac_table`, whose value is another table that represents the
  configuration of the underlying MAC address table as implemented by
  the `apps.bridge.mac_table` module.  Please refer to the
  documentation of that module for a complete description of
  configuration options.  The most important one is the `timeout`
  parameter, which specifies the time in seconds, after which a MAC
  address that has been learned on a port is removed from the table if
  no frame that carries the address in its source address field has
  been seen during that interval.  The default is 60 seconds.

  If the VPLS is a VPWS (i.e. a point-to-point VPN with a single AC at
  each end), an actual bridge is not necessary.  In this case, the
  bridge module is not instantiated and the local end of the
  pseudowire is "short-circuited" to the AC and a message to this
  effect is logged.

   * `ac`: this table contains the configurations of the physical
      ports that represent the attachment circuits connected to the
      VPLS instance.  The keys in this table define the names of the
      attachment circuits within the VPLS instance.  For example,

 ```
  ac = {
    primary_AC = <ac_config>,
    backup_AC = <ac_config>,
  }
 ```
 
 would define two ACs named `primary_AC` and `backup_AC`,
 respectively.  The `<ac_config>` tables are of the form

 ```
  <ac_config> = {
    driver = <driver>,
    config = {
      pciaddr = <pci_address>
      -- Optional
      snmp = {
        directory = <shmem_directory>
      }
    }
  }
 ```
 Please refer to the description of the [uplink interface
 configuration](#uplink_configuration) for details.  Note that the
 `mtu` key of the `config` table is not present here, because it is
 automatically derived from the `mtu` of the top-level VPLS
 configuration (any `mtu` key as part of an AC configuration is
 overwritten by that value).

   * `address`: the IPv6 address that uniquely identifies the VPLS
     instance.  It is used as endpoint for all attached pseudowires.

   * `tunnel`: a table that specifies the default tunnel configuration
     for all pseudowires that do not contain a tunnel configuration
     themselves.  It is optional.  If it is omitted, all pseudowires
     must have an explicit tunnel configuration.  The table is of the
     form

 ```
  <tunnel_config> = {
    type = "gre" | "l2tpv3",
    -- Type-specific configuration
  }
 ```

 The `type` selects either the [GRE or L2TPv3
 encapsulation](#tunnel_protos).  The type-specific configurations are
 as follows

     * GRE

    ```
     {
       type = "gre",
       key = <key>,            -- optional
       checksum = true | false -- optional
     }
    ```

    The optional key `key` is a 32-bit value (for example `key =
    0x12345678`) that will be placed in the GRE key header field for
    packets transmitted on the pseudowire.  Packets arriving on the
    pseudowire are expected to contain the same key, otherwise they
    are discarded and an error message is logged. Hence, both sides of
    the pseudowire must be configured with the same key (or none).

    The value of `0xFFFFFFFE` is reserved for the control channel.
    Note that while the control channel always uses a key, it is
    permitted to configure the tunnel itself without a key.

    If `checksum = true`, outgoing GRE packets will contain a checksum
    that covers the encapsulated Ethernet frame.  When a pseudowire
    receives a packet that contains a checksum, it is always
    validated, irrespective of the setting of the `checksum`
    configuration key.  If validation fails, the packet is dropped and
    an error is logged.

     * L2TPv3

    ```
     {
       type = "l2tpv3",
       local_session = <local_session>,   -- optional
       remote_session = <remote_session>, -- optional
       local_cookie = <local_cookie>,
       remote_cookie = <remote_cookie>,
     }
    ```

    The optional `local_session` and `remote_session` keys specify
    32-bit numbers that can be used as session identifiers.  As
    [discussed above](#tunnel_keyed_ipv6), they are only needed to
    ensure interoperability in certain cases.  If omitted, they will
    default to the value `0xFFFFFFFF`.  The value `<remote_session>`
    is placed in outgoing packets, while the the session ID of
    incoming packets is compared to `<local_session>`.  If the values
    don't match, the packet is discarded and an error is logged.
    Hence, the psuedowire endpoints must be configured with one's
    local session ID identical to that of the other's remote session
    ID.

    The mandatory `<local_cookie>` and `<remote_cookie>` keys must
    specify 64-bit numbers for the purpose [explained
    above](#tunnel_keyed_ipv6).  Like the session ID, the cookies are
    unidirectional, i.e. one's local cookie must be equal to the
    other's remote cookie.  The value must consist of a sequence of 8
    bytes, e.g. a Lua string of length 8 like
    `'\x00\x11\x22\x33\x44\x55\x66\x77'`.

   * `cc`: a table that specifies the default control channel
     configuration for all pseudowires that do not contain such a
     configuration themselves.  It is optional.  If omitted, the
     pseudowires that don't specify a control-channel will not make
     use of the control channel (but note that it is an error if one
     end of the pseudowire uses the control-channel and the other
     doesn't).  The table is of the form

 ```
  <cc_config> = {
    heartbeat = <heartbeat>,
    dead_factor = <dead_factor>
  }
 ```

 `<heartbeat>` is the interval in seconds at which the pseudowire
 sends control messages to its peer.  This number itself is
 transmitted within the control message as the `heartbeat` parameter.
 The value of the `dead_factor`, which must be an integer, is used to
 detect when the remote endpoint can no longer reach the local
 endpoint in the following manner, see the [description of the
 control-channel](#control_channel) for details.

   * `shmem_dir`: the path to a directory in the local file system
     where the shared memory segments used to store raw SNMP objects
     are located.  It is used as a rendez-vous point with the external
     program which is used to provide access to these objects via an
     actual SNMP agent.

   * `pw`: this table contains one key per pseudowire which is part of
     the VPLS instance.  The keys represent the (arbitrary) names of
     these pseudowires, e.g.

 ```
  pw = {
    pw_1 = <pw_config>,
    pw_2 = <pw_config>,
  }
 ```

 defines two pseudowires named `pw_1` and `pw_2`.  Each configuration
 is a Lua table of the form

 ```
  <pw_config> = {
    address = <remote_address>,
    tunnel = <tunnel_config>, -- optional
    cc = <cc_config>          -- optional
  }
 ```

 The mandatory key `address` specifies the IPv6 address of the remote
 end of the pseudowire.  The `tunnel` and `cc` keys specify the
 configurations of the tunnel and control-channel of the pseudowire,
 respectively, as described above.

 The tunnel configuration is mandatory for a pseudowire, either
 through the default at the VPLS top-level configuration or the
 specific configuration here.

 If neither a local nor a default control-channel configuration
 exists, the pseudowire will not transmit any control messages and
 expects to receive none either.  The reception of a control message
 from the remote end is considered an error.  In that case, a message
 will be logged and the pseudowire will be marked as down, i.e. no
 packets will be forwarded in either direction.

### Examples

#### Point-to-Point VPN

This VPN consists of two endpoints called `A` and `B` with local
addresses `2001:db8:0:1:0:0:0:1` and `2001:db8:0:1:0:0:0:2`,
respectively.  The IPv6 subnet and address on the uplink of endpoint
`A` is `2001:db8:0:C101:0:0:0:2/64` and the default route points to
`2001:db8:0:C101:0:0:0:1`.  For endpoint `B`, the corresponding addresses are
`2001:db8:0:C102:0:0:0:2/64` and `2001:db8:0:C102:0:0:0:2`.

The encapsulation on the (single) pseudowire is L2TPv3 with different
cookies in both directions.

The MTU on the ACs allows for untagged 1500-byte IP packets while the
uplinks have a much larger MTU. 

There is no explicit bridge configuration and the default
flooding-bridge is optimized away.

Endpoint `A`:

```
local Intel82599 = require("apps.intel.intel_app").Intel82599
local shmem_dir = '/tmp/snabb-shmem'
local snmp = {
  directory = shmem_dir
}

return {
   uplink = {
      driver = Intel82599,
      config = {
        pciaddr = "0000:04:00.1",
        mtu = 9206,
        snmp = snmp,
      },
      address = "2001:db8:0:C101:0:0:0:2",
      mac = "90:e2:ba:62:86:e5",
      next_hop = "2001:db8:0:C101:0:0:0:1" },
   vpls = {
      myvpn = {
         description = "Endpoint A of a point-to-point L2 VPN",
         mtu = 1514,
         vc_id = 1,
         ac = {
           ac_A = {
             driver = Intel82599,
             config = {
               pciaddr = "0000:04:00.0",
              snmp = snmp
             },
             interface = "0000:04:00.0"
           }
         },
         address = "2001:db8:0:1:0:0:0:1",
         tunnel = {
           type = 'l2tpv3',
           local_cookie  = '\x00\x11\x22\x33\x44\x55\x66\x77',
           remote_cookie = '\x77\x66\x55\x44\x33\x33\x11\x00'
         },
         cc = {
           heartbeat = 2,
           dead_factor = 4
         },
         shmem_dir = shmem_dir,
         pw = {
            pw_B = { address = "2001:db8:0:1:0:0:0:2" },
         }
      }
   }
}
```

Endpoint `B`:

```
local Intel82599 = require("apps.intel.intel_app").Intel82599
local shmem_dir = '/tmp/snabb-shmem'
local snmp = {
  directory = shmem_dir
}

return {
   uplink = {
      driver = Intel82599,
      config = {
        pciaddr = "0000:04:00.1",
        mtu = 9206,
        snmp = snmp,
      },
      address = "2001:db8:0:C102:0:0:0:2",
      mac = "90:e2:ba:62:86:e6",
      next_hop = "2001:db8:0:C102:0:0:0:1" },
   vpls = {
      myvpn = {
         description = "Endpoint B of a point-to-point L2 VPN",
         mtu = 1514,
         vc_id = 1,
         ac = {
           ac_B = {
             driver = Intel82599,
             config = {
               pciaddr = "0000:04:00.0",
               snmp = snmp
             },
             interface = "0000:04:00.0"
           }
         },
         address = "2001:db8:0:1:0:0:0:2",
         tunnel = {
           type = 'l2tpv3',
           local_cookie  = '\x77\x66\x55\x44\x33\x33\x11\x00',
           remote_cookie = '\x00\x11\x22\x33\x44\x55\x66\x77'
         },
         cc = {
           heartbeat = 2,
           dead_factor = 4
         },
         shmem_dir = shmem_dir,
         pw = {
            pw_A = { address = "2001:db8:0:1:0:0:0:1" },
         }
      }
   }
}
```
