/* -*- P4_16 -*- */

#include <core.p4>
#include <tna.p4>

/*************************************************************************
 ************* C O N S T A N T S    A N D   T Y P E S  *******************
**************************************************************************/
typedef bit<48> mac_addr_t;
typedef bit<32> ipv4_addr_t;

enum bit<16> ether_type_t {
    IPV4 = 0x0800,
    ARP  = 0x0806,
    TPID = 0x8100,
    IPV6 = 0x86DD,
    MPLS = 0x8847
}

const PortId_t CPU_PORT = 66;

#ifndef IPV4_LPM_SIZE
#define IPV4_LPM_SIZE 12288
#endif

const int IPV4_LPM_TABLE_SIZE = IPV4_LPM_SIZE;

/*************************************************************************
 ***********************  H E A D E R S  *********************************
*************************************************************************/

header ethernet_h {
    mac_addr_t   dst_addr;
    mac_addr_t   src_addr;
    ether_type_t ether_type;
}

header vlan_tag_h {
    bit<3>       pri;
    bit<1>       dei;
    bit<12>      vid;
    ether_type_t ether_type;
}

header ipv4_h {
    bit<4>       version;
    bit<4>       ihl;
    bit<8>       diffserv;
    bit<16>      total_len;
    bit<16>      identification;
    bit<3>       flags;
    bit<13>      frag_offset;
    bit<8>       ttl;
    bit<8>       protocol;
    bit<16>      hdr_checksum;
    ipv4_addr_t  src_addr;
    ipv4_addr_t  dst_addr;
}

/*************************************************************************
 ***********************  I N G R E S S  *********************************
*************************************************************************/

struct my_ingress_headers_t {
    ethernet_h   ethernet;
    vlan_tag_h   vlan_tag;
    ipv4_h       ipv4;
}

struct my_ingress_metadata_t {
}

parser IngressParser(
    packet_in pkt,
    out my_ingress_headers_t hdr,
    out my_ingress_metadata_t meta,
    out ingress_intrinsic_metadata_t ig_intr_md)
{
    state start {
        pkt.extract(ig_intr_md);
        pkt.advance(PORT_METADATA_SIZE);
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition select(hdr.ethernet.ether_type) {
            ether_type_t.TPID: parse_vlan_tag;
            ether_type_t.IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_vlan_tag {
        pkt.extract(hdr.vlan_tag);
        transition select(hdr.vlan_tag.ether_type) {
            ether_type_t.IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition accept;
    }
}

control Ingress(
    inout my_ingress_headers_t hdr,
    inout my_ingress_metadata_t meta,

    in    ingress_intrinsic_metadata_t ig_intr_md,
    in    ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md)
{

    action set_output(PortId_t port) {
        ig_tm_md.ucast_egress_port = port;
    }

    action drop() {
        ig_dprsr_md.drop_ctl = 1;
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dst_addr : lpm;
        }
        actions = {
            set_output;
            drop;
        }
        default_action = set_output(CPU_PORT);
        size = IPV4_LPM_TABLE_SIZE;
    }

    apply {
        if (hdr.ipv4.isValid()) {

            /* Step 1: forwarding */
            ipv4_lpm.apply();

            /* Step 2: default QoS (normal traffic) */
            ig_tm_md.qid = 0;
            ig_tm_md.ingress_cos = 0;
            ig_tm_md.packet_color = 0;

            /* Step 3: classify realtime traffic */
            bit<6> dscp = hdr.ipv4.diffserv[7:2];

            if (dscp == 46) {   // EF traffic
                ig_tm_md.qid = 7;
                ig_tm_md.ingress_cos = 7;
            }
        }
    }
}

control IngressDeparser(
    packet_out pkt,
    inout my_ingress_headers_t hdr,
    in my_ingress_metadata_t meta,
    in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md)
{
    apply {
        pkt.emit(hdr);
    }
}

/*************************************************************************
 ***********************  E G R E S S  ***********************************
*************************************************************************/

struct my_egress_headers_t {
}

struct my_egress_metadata_t {
}

parser EgressParser(
    packet_in pkt,
    out my_egress_headers_t hdr,
    out my_egress_metadata_t meta,
    out egress_intrinsic_metadata_t eg_intr_md)
{
    state start {
        pkt.extract(eg_intr_md);
        transition accept;
    }
}

control Egress(
    inout my_egress_headers_t hdr,
    inout my_egress_metadata_t meta,

    in    egress_intrinsic_metadata_t eg_intr_md,
    in    egress_intrinsic_metadata_from_parser_t eg_prsr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md,
    inout egress_intrinsic_metadata_for_output_port_t eg_oport_md)
{
    apply { }
}

control EgressDeparser(
    packet_out pkt,
    inout my_egress_headers_t hdr,
    in my_egress_metadata_t meta,
    in egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    apply {
        pkt.emit(hdr);
    }
}

/*************************************************************************
 ************************  P I P E L I N E  ******************************
*************************************************************************/

Pipeline(
    IngressParser(),
    Ingress(),
    IngressDeparser(),
    EgressParser(),
    Egress(),
    EgressDeparser()
) pipe;

Switch(pipe) main;