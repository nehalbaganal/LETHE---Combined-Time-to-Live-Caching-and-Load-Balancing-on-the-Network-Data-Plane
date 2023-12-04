/* Memcached Lethe Mk1 Load Balancer - Parser */

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {
    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType){
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol){
            TYPE_TCP: parse_tcp;
            TYPE_UDP: parse_udp;
            default: accept;
        }
    }

    state parse_tcp {
        packet.extract(hdr.tcp);
        transition accept;
    }

    state parse_udp {
        packet.extract(hdr.udp);
        /* parse Memcached if either destination port or source port is MEMCACHED_UDP_PORT */
        transition select(hdr.udp.dstPort, hdr.udp.srcPort){
            (MEMCACHED_UDP_PORT, _): parse_memcached_udp_cs;
            (_, MEMCACHED_UDP_PORT): parse_memcached_udp_sc;
            default: accept;
        }
    }

    /* Parse Memcachd commands Client->Server */
    state parse_memcached_udp_cs {
        packet.extract(hdr.mcdframe);
        packet.extract(hdr.mcommand);
        transition select(((bit<8>)(hdr.mcommand.command >> 16)) & 0b11011111) {
            0x44: parse_memcached_delete;    // command starts with 'D'=0x44 (ignore uppercase/lowercase)
            default: parse_memcached_universal;
        }
    }

    /* Parse Memcachd commands Server->Client */
    state parse_memcached_udp_sc {
        packet.extract(hdr.mcdframe);
        packet.extract(hdr.mcommand);
        transition select(((bit<8>)(hdr.mcommand.command >> 16)) & 0b11011111) {
            0x45: parse_memcached_universal;  // 'E'=0x45 (END)
            0x56: parse_memcached_response;   // 'V'=0x56 (VALUE)
            default: accept;
        }
    }

    /* parse Memcached packet with 3 byte command, e.g. 'get', 'set', 'end' */
    state parse_memcached_universal {
        packet.extract(hdr.memcache);
        transition accept;
    }

    /* parse Memcached packet with 5 byte command, 'value' */
    state parse_memcached_response {
        packet.extract(hdr.mcdvalue);
        transition accept;
    }

    /* parse Memcached packet with 6 byte command, 'delete' */
    state parse_memcached_delete {
        packet.extract(hdr.mcdelete);
        transition accept;
    }
}

/* Memcached Smart Load Balancer - Deparser */

control MyDeparser(packet_out packet,
                   in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);

        packet.emit(hdr.udp);
        packet.emit(hdr.tcp);

        packet.emit(hdr.mcdframe);
        packet.emit(hdr.mcommand);
        packet.emit(hdr.memcache);
        packet.emit(hdr.mcdvalue);
        packet.emit(hdr.mcdset);
        packet.emit(hdr.mcdelete);
        packet.emit(hdr.mcdgat);

    }
}
